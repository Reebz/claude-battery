using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using ClaudeBatteryWin.Icons;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using ClaudeBatteryWin.ViewModels;
using ClaudeBatteryWin.Views;
using H.NotifyIcon;
using Microsoft.Win32;
using Velopack;

namespace ClaudeBatteryWin;

/// <summary>
/// Windowless tray application entry point (R1) and the full startup/DI composition root. There is
/// no <c>StartupUri</c>; the only persistent surface is the <see cref="H.NotifyIcon.TaskbarIcon"/>
/// declared in App.xaml.
///
/// Responsibilities owned here:
/// <list type="bullet">
///   <item>Velopack's <c>VelopackApp.Build().Run()</c> as the FIRST line (U12) so install/update
///   hooks execute and exit before any UI spins up.</item>
///   <item>Single-instance enforcement via a named per-user <see cref="Mutex"/>; a second launch
///   signals the first (named <see cref="EventWaitHandle"/>) to show the flyout, then exits. The
///   mutex is released LAST on exit so an update relaunch (U12) can re-acquire it.</item>
///   <item>The object graph: the shared <see cref="CookieContainer"/> -> <see cref="ClaudeApi"/>
///   (<see cref="IClaudeApi"/>) -> <see cref="UsageService"/>; <see cref="SecretStore"/> +
///   <see cref="AccountStore"/> (sharing the container); <see cref="ThemeWatcher"/>; the
///   <see cref="DualHorizontalRenderer"/> feeding the tray icon; <see cref="Notifier"/>;
///   <see cref="UpdateService"/>; <see cref="WebView2Runtime"/> gating login.</item>
///   <item>System event subscriptions (<see cref="SystemEvents.PowerModeChanged"/> for wake-repoll
///   R6, <see cref="SystemEvents.UserPreferenceChanged"/> for theme R3).</item>
///   <item>Tray-icon click -> <see cref="FlyoutWindow"/>; the flyout's update row -> the
///   <see cref="UpdateService"/>.</item>
///   <item>The crash log (<c>%LocalAppData%\ClaudeBatteryWin\crash.log</c>): the process is
///   windowless, so an unhandled exception would otherwise die with nothing a tester can attach.
///   The CI smoke job and testers read this file.</item>
/// </list>
/// </summary>
public partial class App : Application
{
    // Per-user names: the suffix keeps two different Windows users from colliding on a machine
    // with fast-user-switching. The GUID-ish base keeps the names from clashing with other apps.
    private const string ShowFlyoutEventName = @"Local\ClaudeBatteryWin.ShowFlyout.7E2C1B44";

    // Single-instance gate via an exclusive lock FILE rather than a Mutex. A Mutex is thread-affine
    // (ReleaseMutex must run on the acquiring thread, else it throws ApplicationException and leaves
    // the mutex HELD) - that is the update-relaunch double-instance bounce in #10. A FileStream held
    // with FileShare.None is process-scoped: disposing it frees the lock from ANY thread, and the OS
    // frees it on process exit even after a crash, so the relaunched instance always becomes primary.
    private FileStream? _singleInstanceLock;
    private EventWaitHandle? _showFlyoutEvent;
    private RegisteredWaitHandle? _showFlyoutWaitRegistration;
    private TaskbarIcon? _trayIcon;

    // --- Object graph (constructed in OnStartup once we are the primary instance) --------------
    private CookieContainer? _cookieJar;
    private SecretStore? _secretStore;
    private AccountStore? _accountStore;
    private SwappableClaudeApi? _api;
    private SystemNetworkAvailability? _network;
    private SystemSchedulerClock? _clock;
    private UsageService? _usageService;
    private ThemeWatcher? _themeWatcher;
    private DualHorizontalRenderer? _renderer;
    private AppSettings? _settings;
    private IToastSink? _toastSink;
    private Notifier? _notifier;
    private WebView2Runtime? _runtime;
    private AuthManager? _authManager;
    private LoginWebViewFactory? _loginWebViewFactory;
    private GitHubVelopackUpdater? _velopackUpdater;
    private UpdateService? _updateService;
    private AutostartService? _autostart;
    private ManualSignIn? _manualSignIn;

    private FlyoutWindow? _flyout;
    private FlyoutViewModel? _flyoutViewModel;
    private SettingsWindow? _settingsWindow;

    // Per-minute countdown re-render timer and the stale-check timer (mirror the Mac MenuBarController).
    private DispatcherTimer? _countdownTimer;

    // The single reusable theme-debounce timer (U11) and the latest coalesced re-read action.
    private DispatcherTimer? _themeDebounceTimer;
    private Action? _themeReevaluate;

    // Guards against re-entrant tray clicks while the runtime-missing window is up.
    private bool _runtimeWindowOpen;

    // The LastSuccessfulFetch timestamp the Notifier was last evaluated against, so the weekly-low
    // toast is evaluated only on a genuine poll success (when the fetch advances), not on every
    // StateChanged tick incl. hard-failure/auth-failure ticks (issue #19).
    private DateTimeOffset? _lastNotifiedFetch;

    // Latched once at startup: at least one account was dropped at load because its DPAPI blob would
    // not decrypt (profile copy / SID change). AccountStore.DroppedAccountIds is cleared on each Load,
    // so the fact is captured here and fed into the flyout's distinct re-auth surface (U6/R4).
    private bool _securityDataUnreadable;

    // Mirrors "the polling transport currently runs the frozen DefaultUserAgent" (no persisted
    // per-account UA). Read live by the UsageService CF-block escalation (review F1); written only
    // at the initial seed and in RebuildApiWithUserAgent. UI-thread writes, poll-thread reads - a
    // stale read is benign (one extra backoff round before escalation).
    private bool _transportUaIsFallback;

    protected override void OnStartup(StartupEventArgs e)
    {
        // --- Velopack MUST run first (U12) ----------------------------------------------------
        // Install/uninstall/update hooks run synchronously here and exit the process for hook
        // invocations; if this is not first, a freshly applied update can re-run the old binary's
        // UI on the hook launch. No tray icon, no window, no service may precede it.
        VelopackApp.Build().Run();

        // --- Crash log ------------------------------------------------------------------------
        // The app is windowless: an unhandled exception kills the process with nothing a tester
        // can attach. Record it first, before anything else here can throw. The dispatcher hook
        // does NOT set Handled: the process still terminates, it just leaves a trace behind. The
        // CI smoke job and testers read %LocalAppData%\ClaudeBatteryWin\crash.log.
        DispatcherUnhandledException += (_, args) => WriteCrashLog("dispatcher", args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => WriteCrashLog("appdomain", args.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            WriteCrashLog("unobserved-task", args.Exception);
            args.SetObserved();
        };

        // --- Single-instance gate -------------------------------------------------------------
        // A null lock means another instance already holds the file lock.
        _singleInstanceLock = TryAcquireSingleInstanceLock();

        // The named auto-reset event the running instance waits on; a second launch sets it.
        _showFlyoutEvent = new EventWaitHandle(
            initialState: false,
            mode: EventResetMode.AutoReset,
            name: ShowFlyoutEventName);

        if (_singleInstanceLock is null)
        {
            // Another instance is already running. Signal it to surface the flyout, then exit
            // WITHOUT showing a tray icon (so a double-launch never yields two icons).
            _showFlyoutEvent.Set();
            // Release our (non-owning) handles before bailing; we never acquired the lock.
            _showFlyoutEvent.Dispose();
            _showFlyoutEvent = null;
            Shutdown();
            return;
        }

        // We are the primary instance. Wait (off the UI thread) for any later launch to signal,
        // and marshal the show-flyout request back onto the dispatcher.
        _showFlyoutWaitRegistration = ThreadPool.RegisterWaitForSingleObject(
            _showFlyoutEvent,
            (_, _) => Dispatcher.BeginInvoke(new Action(() => ShowFlyout())),
            state: null,
            timeout: Timeout.InfiniteTimeSpan,
            executeOnlyOnce: false);

        base.OnStartup(e);

        // --- Startup stale-UDF sweep (U6 security) -------------------------------------------
        // Before showing the tray icon, delete leftover login WebView2 user-data folders from a
        // crashed prior session: a crash mid-login can otherwise leave an unencrypted session
        // cookie on disk readable by any same-user process.
        LoginWindow.SweepStaleLoginProfiles();

        // --- Toast identity (U11) -------------------------------------------------------------
        // Register the process AUMID so toasts resolve to the installed Start-menu shortcut's
        // identity. Best-effort; a failure leaves the sink reporting not-delivered (no latch).
#if WINDOWS10_0_19041_0_OR_GREATER
        WinRtToastSink.EnsureRegistered();
#endif

        BuildObjectGraph();
        if (!AcquireTrayIcon())
        {
            return; // Shutdown() already requested; OnExit runs the ordered teardown.
        }
        SubscribeSystemEvents();
        StartTimers();

        // Start theme watching and paint the initial icon for the resolved (signed-out / loading)
        // state, then kick off polling if an account was restored from disk.
        _themeWatcher!.Start();
        RefreshIcon();

        if (_accountStore!.ActiveAccount is { } active)
        {
            _usageService!.StartPolling(active.OrganizationId);
        }

        // Latch whether the startup signed-out state is due to a DPAPI drop (a saved account's blob
        // would not decrypt: profile copy / SID change) rather than a plain sign-out. DroppedAccountIds
        // is cleared on each Load, so capture it now; SyncViewModelFromServices feeds it into the
        // flyout's distinct re-auth surface (U6/R4) and retires it once an authenticated state appears.
        _securityDataUnreadable = ShouldFlagSecurityDataUnreadable(_accountStore);

        // Surface a DPAPI-drop as the distinct re-auth surface, or an ordinary signed-out/auth state,
        // by refreshing the flyout view-model.
        SyncViewModelFromServices();

        // Fire the first update check in the background; the flyout/Settings rows read the result.
        _ = CheckForUpdatesAsync();
    }

    // ============================================================================================
    // Single-instance lock (U12)
    // ============================================================================================

    /// <summary>
    /// Acquire the process-scoped single-instance lock, or return null when another instance already
    /// holds it. Uses an exclusive (<c>FileShare.None</c>) handle on a per-user lock file: unlike a
    /// Mutex it is NOT thread-affine, so it can be released from any thread, and the OS frees it on
    /// process exit even after a crash - eliminating the thread-affine-release double-instance bounce.
    /// </summary>
    private static FileStream? TryAcquireSingleInstanceLock()
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ClaudeBatteryWin");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "singleinstance.lock");
            return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException)
        {
            return null; // already held by another running instance
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    /// Free the single-instance lock immediately (from any thread). Idempotent. Called LAST in the
    /// shutdown/relaunch teardown so a relaunch (incl. an update restart, U12) can acquire it without
    /// bouncing off our predecessor; also the direct fallback when the dispatcher is unreachable.
    /// </summary>
    internal void ReleaseSingleInstanceLock()
    {
        _singleInstanceLock?.Dispose();
        _singleInstanceLock = null;
    }

    // ============================================================================================
    // Object graph
    // ============================================================================================

    private void BuildObjectGraph()
    {
        // Shared cookie jar: the SAME instance the AccountStore primes and the ClaudeApi transport
        // reads from, so cookie rotation (__cf_bm) and account switches are reflected in both.
        // Built by the store so the per-domain capacity suits the claude.ai capture (the .NET
        // default of 20 per domain silently drops cookies).
        _cookieJar = AccountStore.CreateCookieJar();

        _secretStore = new SecretStore();
        _accountStore = new AccountStore(_cookieJar, _secretStore);

        // The outbound UA must equal the WebView2 session UA verbatim (necessary, not sufficient,
        // for Cloudflare). It is captured after the first login NavigationCompleted (U6) and swapped
        // in via RebuildApiWithUserAgent. The transport is wrapped in a SwappableClaudeApi so the
        // UsageService/ManualSignIn can hold ONE reference while the inner transport is replaced on
        // login (without modifying those units). Until a login happens this session, the inner is a
        // ClaudeApi seeded with a plausible fallback Chromium-Edge UA so a restored-account first
        // poll works (the U2 spike resolves whether this clears Cloudflare; if not, an in-WebView2
        // IClaudeApi is substituted via Swap).
        // Seed the inner transport with the RESTORED account's captured UA (U2) so a cold-start poll
        // carries the same UA the login session used (a Cloudflare necessity), not the frozen
        // DefaultUserAgent. The SwappableClaudeApi wrapper is unchanged - a live login still swaps the
        // freshest UA in via OnAuthSuccess; this only fixes the no-login-this-session restore path.
        var seedUserAgent = ResolveSeedUserAgent(_accountStore.ActiveAccount);
        _transportUaIsFallback = seedUserAgent == DefaultUserAgent;
        _api = new SwappableClaudeApi(new ClaudeApi(_cookieJar, seedUserAgent));

        _network = new SystemNetworkAvailability();
        _clock = new SystemSchedulerClock();
        // The poller reads the AccountStore's request generation live so a poll superseded by an
        // account switch/re-auth discards its result instead of writing onto the new account (U2).
        _usageService = new UsageService(_api, _network, _clock,
            () => _accountStore?.CurrentGeneration ?? 0,
            // Live fallback-UA signal for the CF-block escalation (review F1): true only while the
            // transport runs the frozen DefaultUserAgent. Updated on every re-seed in
            // RebuildApiWithUserAgent, so a login swap or activation re-seed retires it.
            () => _transportUaIsFallback);
        _usageService.StateChanged += OnUsageStateChanged;
        _usageService.AuthFailureDetected += OnAuthFailureDetected;

        // The AccountStore drives the activation boundary; when the active account changes, restart
        // (or stop) polling against the new org.
        _accountStore.ActiveAccountChanged += OnActiveAccountChanged;

        _renderer = new DualHorizontalRenderer();

        // ThemeWatcher debounce: coalesce a burst of General broadcasts onto one re-read after a
        // short window on the UI thread. A real light/dark flip of EITHER bucket (taskbar or app
        // windows: the two are independent settings) re-renders the icon for the taskbar bucket and
        // re-themes the open flyout for the app bucket; an unrelated broadcast that lands on the
        // same pair is suppressed (U9).
        _themeWatcher = new ThemeWatcher(ScheduleThemeDebounced);
        _themeWatcher.BucketsChanged += OnThemeBucketsChanged;

        _settings = new AppSettings();
        _settings.Changed += (_, _) => RefreshIcon(); // countdown toggle re-composes the tooltip

        // Notifier: weekly-low toasts, gated on the global enable flag (read live), latch on the
        // AccountStore, delivery through the WinRT sink (or a no-op sink off-Windows / in author build).
        // The sink is kept so Settings can fire a test toast through the same path.
        _toastSink = CreateToastSink();
        _notifier = new Notifier(
            notificationsEnabled: () => _settings.NotificationsEnabled,
            latch: new AccountStoreNotifyLatch(_accountStore),
            toastSink: _toastSink);

        _runtime = new WebView2Runtime();

        // Login: a production factory builds a real ephemeral WebView2-hosting LoginWindow per
        // attempt; the AuthManager state machine consumes it. The org picker hosts OrgPickerView
        // over the open login window.
        _loginWebViewFactory = new LoginWebViewFactory(WireLoginWindow);
        var orgPicker = new OrgPicker(() => _loginWebViewFactory.CurrentWindow);
        _authManager = new AuthManager(_api, _accountStore, _loginWebViewFactory, orgPicker);
        _authManager.OnAuthSuccess = OnAuthSuccess;
        _authManager.OnManualSignInRequested = OpenSettingsAtManualSignIn;
        _authManager.LoginStateChanged += OnLoginStateChanged;

        _velopackUpdater = new GitHubVelopackUpdater();
        _updateService = new UpdateService(_velopackUpdater, new AppUpdateTeardown(this));

        _autostart = new AutostartService();
        _manualSignIn = new ManualSignIn(_api, _accountStore);

        // The flyout view-model is the single state machine the borderless window binds against.
        _flyoutViewModel = new FlyoutViewModel();
        // Tapping a flyout account row switches to it (U15); the VM raises the id, the store switches.
        _flyoutViewModel.SwitchAccountRequested += id => _accountStore?.SwitchTo(id);
    }

    /// <summary>
    /// Swap the wrapped transport onto a freshly-captured WebView2 UA so the outbound poll UA equals
    /// the login session UA verbatim. The <see cref="SwappableClaudeApi"/> replaces its inner
    /// transport in place and disposes the prior one, so the <see cref="UsageService"/>,
    /// <see cref="ManualSignIn"/>, and <see cref="AuthManager"/> keep their single reference. Called
    /// from <see cref="OnAuthSuccess"/> after capture, when the AuthManager has a non-null UA.
    /// </summary>
    private void RebuildApiWithUserAgent(string userAgent)
    {
        if (_cookieJar is null || _api is null)
        {
            return;
        }

        _api.Swap(new ClaudeApi(_cookieJar, userAgent));
        // Single invariant for the CF-block escalation: the flag mirrors "the transport UA is the
        // frozen fallback" and is maintained ONLY here and at the initial seed - every re-seed
        // (login swap with a captured UA, activation re-seed from a persisted UA) passes through.
        _transportUaIsFallback = userAgent == DefaultUserAgent;
    }

    /// <summary>
    /// The User-Agent to seed the cold-start polling transport with: the restored account's captured
    /// session UA when present (U1/U2), else the frozen <see cref="DefaultUserAgent"/>. Coalesces a
    /// null/empty stored UA to the default because the <see cref="ClaudeApi"/> ctor rejects an empty
    /// UA; a pre-fix account (no persisted UA) therefore behaves exactly as today until its next login
    /// captures a real one (KTD2 - no live-UA harvest at startup). Pure + internal so it is unit-tested
    /// directly.
    /// </summary>
    internal static string ResolveSeedUserAgent(Account? account)
        => account?.UserAgent is { Length: > 0 } ua ? ua : DefaultUserAgent;

    /// <summary>
    /// Whether the startup "re-sign-in required (security data could not be read)" surface should be
    /// flagged: at least one account was dropped at load because its DPAPI blob would not decrypt AND
    /// there is no active account (a surviving account that loaded fine means the user is signed in,
    /// so the nudge would be misleading). Pure + internal so the producer -> latch chain is unit-tested
    /// directly (U6/R4). The latch is additionally retired once any authenticated state is observed
    /// (see <see cref="SyncViewModelFromServices"/>), so a later deliberate sign-out cannot resurface it.
    /// </summary>
    internal static bool ShouldFlagSecurityDataUnreadable(AccountStore? store)
        => store is not null && store.DroppedAccountIds.Count > 0 && !store.IsAuthenticated;

    /// <summary>
    /// The retirement rule for the startup DPAPI-drop latch: any authenticated state observed
    /// retires it permanently (returns false), and a retired latch stays retired - a later
    /// deliberate sign-out must NOT resurface the "security data could not be read" copy (false in,
    /// false out). Pure + internal so the promise the inline comment in
    /// <see cref="SyncViewModelFromServices"/> makes is unit-tested directly (U6/R4), matching the
    /// <see cref="ResolveSeedUserAgent"/> / <see cref="ShouldFlagSecurityDataUnreadable"/> pattern.
    /// </summary>
    internal static bool RetireSecurityDataUnreadable(bool latched, bool isAuthenticated)
        => !isAuthenticated && latched;

    private IToastSink CreateToastSink()
    {
#if WINDOWS10_0_19041_0_OR_GREATER
        return new WinRtToastSink();
#else
        // Author/non-Windows build: a sink that never delivers, so the Notifier never latches a
        // toast the platform cannot show. Replaced by WinRtToastSink on the Windows-versioned TFM.
        return new NullToastSink();
#endif
    }

    // ============================================================================================
    // Tray icon
    // ============================================================================================

    /// <summary>
    /// Resolve the App.xaml tray icon, give it its identity, and register it with the shell. Returns
    /// false when the icon could not be created even after a fresh-GUID retry; the app has then
    /// already requested <see cref="Application.Shutdown()"/> and the caller must stop.
    ///
    /// The Id is path-derived (<see cref="TrayIconIdentity"/>) rather than a fixed literal: Windows
    /// binds an unsigned exe's tray GUID to the path that first registered it, so a fixed GUID makes
    /// <c>Shell_NotifyIcon(NIM_ADD)</c> fail the moment the same exe runs from another path (a move,
    /// a rename, a re-download saved as "ClaudeBatteryWin (1).exe"). That failure surfaces here as an
    /// <see cref="InvalidOperationException"/> from <c>ForceCreate</c>; a stale registration for
    /// the same path can still trip it, so one retry with a throwaway GUID (pinning lost, icon
    /// present) precedes giving up. The flyout's <c>Shell_NotifyIconGetRect</c> keys on whichever Id
    /// finally registered, so <see cref="FlyoutWindow.TrayIconGuid"/> is read back AFTER creation.
    /// </summary>
    private bool AcquireTrayIcon()
    {
        _trayIcon = (TaskbarIcon)FindResource("TrayIcon");
        _trayIcon.Id = TrayIconIdentity.Current;

        // Left-click toggles the flyout. Wired in code (App.xaml declares no LeftClickCommand binding,
        // since the resource has no DataContext) so the shell is self-consistent.
        _trayIcon.TrayLeftMouseUp += (_, _) => ShowFlyout(fromTrayClick: true);

        _trayIcon.ContextMenu = BuildTrayContextMenu();

        // ForceCreate ensures the Win32 icon exists immediately at startup, with no taskbar window
        // present (R1). registerAlsoInWow64 = false: this is a 64-bit (win-x64) build.
        try
        {
            _trayIcon.ForceCreate(enablesEfficiencyMode: false);
        }
        catch (InvalidOperationException)
        {
            // Drop any half-registered icon, then retry once under a GUID no path can be bound to.
            _trayIcon.TrayIcon.TryRemove();
            _trayIcon.Id = Guid.NewGuid();
            try
            {
                _trayIcon.ForceCreate(enablesEfficiencyMode: false);
            }
            catch (InvalidOperationException ex)
            {
                WriteCrashLog("tray-icon", new InvalidOperationException("tray icon could not be created", ex));
                MessageBox.Show($"Claude Battery could not add its tray icon: {ex.Message}", "Claude Battery");
                Shutdown();
                return false;
            }
        }

        FlyoutWindow.TrayIconGuid = _trayIcon.Id;
        return true;
    }

    private System.Windows.Controls.ContextMenu BuildTrayContextMenu()
    {
        var menu = new System.Windows.Controls.ContextMenu();

        var settings = new System.Windows.Controls.MenuItem { Header = "Settings…" };
        settings.Click += (_, _) => OpenSettings();
        menu.Items.Add(settings);

        var checkUpdates = new System.Windows.Controls.MenuItem { Header = "Check for Updates…" };
        checkUpdates.Click += async (_, _) =>
        {
            if (_updateService?.IsUpdaterInstalled != true)
            {
                // Raw exe (not a Velopack install): a check would no-op, so hand the user the
                // download page instead, matching the Settings update row.
                OpenReleasesPage();
                return;
            }

            await CheckForUpdatesAsync().ConfigureAwait(true);
        };
        menu.Items.Add(checkUpdates);

        menu.Items.Add(new System.Windows.Controls.Separator());

        var quit = new System.Windows.Controls.MenuItem { Header = "Quit Claude Battery" };
        quit.Click += (_, _) => Shutdown();
        menu.Items.Add(quit);

        return menu;
    }

    /// <summary>
    /// Repaint the tray icon for the current usage/auth/taskbar-theme state and refresh its tooltip.
    /// The renderer's signature cache short-circuits a redundant paint (issue #11 port), so calling
    /// this on every poll, theme flip, and per-minute tick is cheap. A null return means "no
    /// change"; we keep the current icon. A produced bitmap is converted to a System.Drawing.Icon
    /// for the tray. The square icon draws no countdown; the numbers live in the tooltip, which is
    /// set BEFORE the render so it updates even when the signature cache suppresses the repaint.
    /// The icon is rasterized at the live small-icon cell size (SM_CXSMICON: 16 at 100% scaling,
    /// 24 at 150%, 32 at 200%) so it is not upscaled by the shell.
    /// </summary>
    private void RefreshIcon()
    {
        if (_renderer is null || _themeWatcher is null || _trayIcon is null)
        {
            return;
        }

        var state = ResolveTrayState();
        var theme = _themeWatcher.CurrentTrayBucket;
        var usage = _usageService?.LatestUsage;
        var countdown = DualHorizontalRenderer.CountdownCellText(
            usage,
            _settings?.ShowSessionCountdown ?? false,
            DateTimeOffset.UtcNow);

        // Write the tooltip through the core TrayIcon, not the ToolTipText dependency property.
        // (1) TrayIcon.UpdateToolTip throws InvalidOperationException when Shell_NotifyIcon(NIM_MODIFY)
        //     returns FALSE (Explorer restarting or hung, or the new shell has not yet re-sent
        //     TaskbarCreated) and nothing above RefreshIcon catches it, so the DP write would end the
        //     process on an ordinary Explorer restart; the icon write below already tolerates the same
        //     failure by returning false.
        // (2) The DP commits its value before its change callback runs, so after a failed write an
        //     identical next refresh would never retry. TrayIcon.ToolTip only advances on a successful
        //     write (and is what TaskbarCreated's re-create passes to NIM_ADD), so comparing against it
        //     retries until the shell accepts the text.
        var tooltip = BuildTooltip(usage, countdown);
        if (!string.Equals(_trayIcon.TrayIcon.ToolTip, tooltip, StringComparison.Ordinal))
        {
            try
            {
                _trayIcon.TrayIcon.UpdateToolTip(tooltip);
            }
            catch (InvalidOperationException)
            {
                // Shell unavailable (ObjectDisposedException derives from this too, covering a late
                // refresh after Exit disposal). Retried on the next refresh.
            }
        }

        var size = Math.Max(16, GetSystemMetrics(SM_CXSMICON));
        var bitmap = _renderer.Render(state, theme, countdown, size);
        if (bitmap is null)
        {
            return; // signature matched; keep the current icon
        }

        using (bitmap)
        {
            // GetHicon hands back an unmanaged HICON we own; wrap it, clone into a managed Icon the
            // TaskbarIcon owns, then destroy the HICON so it is not leaked. The TaskbarIcon disposes
            // the previously-set Icon automatically when this one replaces it (per H.NotifyIcon).
            var hicon = bitmap.GetHicon();
            try
            {
                using var icon = Icon.FromHandle(hicon);
                _trayIcon.Icon = (Icon)icon.Clone();
            }
            finally
            {
                DestroyIcon(hicon);
            }
        }
    }

    /// <summary>
    /// The tray tooltip: the app name alone when there is no usage snapshot, else the two remaining
    /// percentages and, when the countdown toggle yields a value, the session reset countdown that
    /// the square icon no longer draws. Stays well under the shell's 127-character tooltip limit.
    /// Pure + internal so it is unit-tested directly.
    /// </summary>
    internal static string BuildTooltip(UsageSnapshot? usage, string countdown)
    {
        if (usage is null)
        {
            return "Claude Battery";
        }

        var text = $"Claude Battery - Session {Math.Round(usage.SessionRemaining)}% - Weekly {Math.Round(usage.WeeklyRemaining)}%";
        return countdown.Length > 0 ? $"{text} - resets in {countdown}" : text;
    }

    /// <summary>
    /// Map the polling/auth state to the tray render branch. The branch logic lives in the pure,
    /// unit-tested <see cref="TrayRenderState.Resolve"/>: auth-failed -> faded "!"; an account with a
    /// usable snapshot -> the battery (even when stale, matching the flyout, issue #9); no account ->
    /// the hollow outline; with no snapshot, repeated hard failures -> "!", a sustained stale window
    /// -> "...", an in-flight first poll -> a solid "...".
    /// </summary>
    private TrayRenderState ResolveTrayState()
    {
        var store = _accountStore;
        var svc = _usageService;

        return TrayRenderState.Resolve(
            isAuthenticated: store?.IsAuthenticated ?? false,
            serviceReady: svc is not null,
            authFailed: svc?.AuthFailed ?? false,
            latestUsage: svc?.LatestUsage,
            consecutiveFailures: svc?.ConsecutiveFailures ?? 0,
            isStale: svc?.IsStale ?? true);
    }

    // ============================================================================================
    // Flyout
    // ============================================================================================

    /// <summary>
    /// Surface the flyout anchored to the tray rect. The second-instance signal and the tray
    /// left-click both route here. Lazily constructs the window, binds the view-model, applies the
    /// current app-window theme, and positions it (U10).
    ///
    /// A tray click (<paramref name="fromTrayClick"/>) is a toggle: an open flyout closes instead of
    /// re-showing. Usually the click has ALREADY deactivated and hidden the flyout before the icon's
    /// mouse-up arrives, so the second guard swallows a show that lands within the flyout's toggle
    /// window of that deactivation-hide. Neither guard applies while a login is in progress (the
    /// flyout suppresses its deactivation dismiss then, and a click should bring it back). The
    /// second-instance signal keeps the unguarded show.
    /// </summary>
    private void ShowFlyout(bool fromTrayClick = false)
    {
        if (_flyoutViewModel is null)
        {
            return;
        }

        if (_flyout is null)
        {
            _flyout = new FlyoutWindow { DataContext = _flyoutViewModel };
            _flyout.ApplyTheme(_themeWatcher?.CurrentAppBucket ?? ThemeBucket.Light);
            WireFlyoutInteractions(_flyout);
        }

        if (fromTrayClick && _flyout.IsVisible && !_flyoutViewModel.SuppressDismissOnDeactivate)
        {
            _flyout.Hide();
            return;
        }

        if (fromTrayClick && _flyout.ConsumeRecentDeactivationHide(Environment.TickCount64))
        {
            return; // the click that just dismissed the flyout; not a request to reopen it
        }

        SyncViewModelFromServices();
        _flyout.ApplyTheme(_themeWatcher?.CurrentAppBucket ?? ThemeBucket.Light);
        _flyout.ShowAtTray();
    }

    /// <summary>
    /// Wire the flyout's interactive affordances (the integration glue the view-model deliberately
    /// does not own). The U10 XAML declares named buttons but no <c>Click</c> handlers; the
    /// composition root attaches them here, routing into the live services. Account switching and
    /// account management are owned by the Settings window (the flyout account rows are display-only
    /// in v1), so they are not wired from the flyout.
    /// </summary>
    private void WireFlyoutInteractions(FlyoutWindow flyout)
    {
        HookButton(flyout, "SignInButton", BeginLogin);
        HookButton(flyout, "ReauthButton", BeginLogin);
        HookButton(flyout, "ReauthSecurityButton", BeginLogin);
        HookButton(flyout, "AddAccountLinkButton", BeginLogin);
        HookButton(flyout, "LoginErrorTryAgainButton", () => _authManager?.RetryLogin());
        HookButton(flyout, "UpdateLinkButton", () => _ = ApplyUpdateAsync());
        // Error panel: sign in again, or retry now. HandleResume restarts polling with the one-shot
        // no-network grace and is a no-op when auth has failed or nothing is being polled.
        HookButton(flyout, "ErrorSignInButton", BeginLogin);
        HookButton(flyout, "ErrorRetryButton", () => _usageService?.HandleResume());
    }

    /// <summary>
    /// Attach a click handler to a named <see cref="System.Windows.Controls.Button"/> in the flyout.
    /// A missing element is tolerated (the panel for that state may not be realized), so the shell is
    /// robust to a XAML rename without throwing at startup.
    /// </summary>
    private static void HookButton(FlyoutWindow flyout, string name, Action onClick)
    {
        if (flyout.FindName(name) is System.Windows.Controls.Button button)
        {
            button.Click += (_, _) => onClick();
        }
    }

    /// <summary>
    /// Push the current service state into the flyout view-model. Called on every state change
    /// (poll result, account switch, login transition) after marshaling onto the UI thread.
    /// </summary>
    private void SyncViewModelFromServices()
    {
        if (_flyoutViewModel is null)
        {
            return;
        }

        var store = _accountStore;
        var svc = _usageService;

        // Batch all input setters so the view-model re-resolves ONCE, not once per property (U16/#26).
        using (_flyoutViewModel.SuspendRefresh())
        {
            _flyoutViewModel.IsAuthenticated = store?.IsAuthenticated ?? false;
            _flyoutViewModel.Accounts = store?.Accounts ?? Array.Empty<Account>();
            _flyoutViewModel.ActiveAccountId = store?.ActiveAccountId;
            _flyoutViewModel.CanAddAccount = store?.CanAddAccount ?? true;

            // Retire the startup DPAPI-drop nudge once any authenticated state is observed: a later
            // sign-out is then the user's own action, not the unreadable-security-data cause, so it
            // must not resurface the re-auth copy (review: avoid a stale re-auth surface after a
            // sign-in / account-removal sequence). The rule lives in the pure
            // RetireSecurityDataUnreadable so the retire-then-never-relatch promise is unit-tested.
            _securityDataUnreadable = RetireSecurityDataUnreadable(_securityDataUnreadable, store?.IsAuthenticated == true);
            _flyoutViewModel.SecurityDataUnreadable = _securityDataUnreadable;

            if (svc is not null)
            {
                _flyoutViewModel.LatestUsage = svc.LatestUsage;
                _flyoutViewModel.AuthFailed = svc.AuthFailed;
                _flyoutViewModel.ConsecutiveFailures = svc.ConsecutiveFailures;
                _flyoutViewModel.LastSuccessfulFetch = svc.LastSuccessfulFetch;
            }

            if (_authManager is not null)
            {
                _flyoutViewModel.LoginState = _authManager.LoginState;
            }

            _flyoutViewModel.AvailableUpdateVersion = _updateService?.AvailableUpdate?.Version;
        }
    }

    // ============================================================================================
    // Login flow (U6/U7/U8 gate)
    // ============================================================================================

    /// <summary>
    /// Begin a sign-in, gated on the WebView2 runtime being present (U8). When it is absent, show
    /// the separate <see cref="RuntimeMissingWindow"/> and block login until the bootstrap succeeds;
    /// only then open the WebView2 login flow.
    /// </summary>
    private void BeginLogin()
    {
        if (_runtime is null || _authManager is null)
        {
            return;
        }

        if (!_runtime.IsAvailable())
        {
            if (_runtimeWindowOpen)
            {
                return;
            }

            _runtimeWindowOpen = true;
            try
            {
                var runtimeWindow = new RuntimeMissingWindow(_runtime);
                runtimeWindow.ShowDialog();
                if (!runtimeWindow.RuntimeReady)
                {
                    return; // user dismissed without installing; login stays blocked
                }
            }
            finally
            {
                _runtimeWindowOpen = false;
            }
        }

        _authManager.PresentLogin();
    }

    /// <summary>
    /// Build and wire a real login window each attempt (the production <see cref="ILoginWebView"/>).
    /// Hooks the "Try again" / "Sign in manually" affordances back to the manager and reflects the
    /// login state onto the window's overlays.
    /// </summary>
    private LoginWindow WireLoginWindow()
    {
        var window = new LoginWindow();
        window.RetryRequested += () => _authManager?.RetryLogin();
        window.ManualSignInRequested += () => _authManager?.RequestManualSignIn();
        return window;
    }

    private void OnLoginStateChanged(LoginState state)
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            // Reflect the state onto the live login window's overlays. Key the signing-in overlay on
            // the shared LoginState.IsLoginInProgress predicate (signing-in / capturing / org-discovery
            // / picker) so the four in-progress kinds cannot drift from the flyout's panel + dismiss
            // logic, which key on the same predicate (U3).
            if (_loginWebViewFactory?.CurrentWindow is { } window)
            {
                if (state.IsLoginInProgress)
                {
                    window.ShowSigningInOverlay();
                }
                else if (state.Kind == LoginStateKind.Error)
                {
                    window.ShowError(state.Message ?? "Sign-in failed. Please try again.");
                }
                else
                {
                    window.HideOverlays();
                }
            }

            SyncViewModelFromServices();
        }));
    }

    private void OnAuthSuccess()
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            // Repoint the transport at the WebView2-captured UA (necessary for Cloudflare), then
            // poll the newly active account and refresh the UI.
            if (_authManager?.CapturedUserAgent is { Length: > 0 } ua)
            {
                RebuildApiWithUserAgent(ua);
            }

            if (_accountStore?.ActiveAccount is { } active)
            {
                _usageService?.StartPolling(active.OrganizationId);
            }

            SyncViewModelFromServices();
            RefreshIcon();
            // An open Settings window shows the new account without a reopen.
            _settingsWindow?.RefreshAccounts();
        }));
    }

    // ============================================================================================
    // Settings
    // ============================================================================================

    private void OpenSettings() => OpenSettingsInternal(focusManualSignIn: false);

    private void OpenSettingsAtManualSignIn()
        => Dispatcher.BeginInvoke(new Action(() => OpenSettingsInternal(focusManualSignIn: true)));

    private void OpenSettingsInternal(bool focusManualSignIn)
    {
        if (_accountStore is null || _manualSignIn is null || _autostart is null
            || _settings is null || _updateService is null)
        {
            return;
        }

        if (_settingsWindow is null)
        {
            // The test-toast button goes through the SAME sink the Notifier delivers with, so a
            // tester confirms the real path. A null sender hides the button.
            var toastSink = _toastSink;
            Func<bool>? sendTestToast = toastSink is null
                ? null
                : () => toastSink.TryShow("Claude Battery", "Notifications are working.", Guid.Empty);
            _settingsWindow = new SettingsWindow(
                _accountStore, _manualSignIn, _autostart, _settings, _updateService, sendTestToast);
            _settingsWindow.AddAccountRequested += (_, _) => BeginLogin();
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }

        _settingsWindow.Show();
        _settingsWindow.Activate();

        // When invoked from the login error surface's "Sign in manually" affordance, land the user
        // directly on the manual cookie-paste box rather than just opening Settings (U4).
        if (focusManualSignIn)
        {
            _settingsWindow.FocusManualSignIn();
        }
    }

    // ============================================================================================
    // Updates (U12)
    // ============================================================================================

    private async Task CheckForUpdatesAsync()
    {
        if (_updateService is null)
        {
            return;
        }

        try
        {
            await _updateService.CheckForUpdatesAsync().ConfigureAwait(true);
        }
        catch (Exception)
        {
            // A failed check is a no-op (parity with the Mac swallow); nothing to surface.
            return;
        }

        Dispatcher.BeginInvoke(new Action(() =>
        {
            SyncViewModelFromServices();
            // An open Settings window repaints its About row with the result.
            _settingsWindow?.RefreshUpdateRow();
        }));
    }

    /// <summary>
    /// Open the GitHub Releases page in the default browser: the raw-exe build cannot self-update,
    /// so "Check for Updates" hands the user the download page instead. A missing browser handler
    /// (<see cref="Win32Exception"/>) is ignored; there is no surface on the tray menu to report it.
    /// </summary>
    private static void OpenReleasesPage()
    {
        try
        {
            Process.Start(new ProcessStartInfo(ReleasesPageUrl) { UseShellExecute = true });
        }
        catch (Win32Exception)
        {
            // No handler for https URLs; nothing to do from a tray menu.
        }
    }

    private async Task ApplyUpdateAsync()
    {
        if (_updateService is null)
        {
            return;
        }

        // The flyout "Update" link wires this as a fire-and-forget discard (() => _ = ApplyUpdateAsync()),
        // so a throw here would otherwise become an unobserved faulted task. Guard the boundary,
        // matching SettingsWindow.OnUpdateActionClicked (which catches + surfaces a failure message).
        // ApplyUpdateAsync runs the clean teardown (AppUpdateTeardown below) then relaunches and never
        // returns on a real install; a false return (dev/test/no update) leaves us running, and the
        // catch covers a transient download/disk failure.
        try
        {
            await _updateService.ApplyUpdateAsync().ConfigureAwait(true);
        }
        catch (Exception)
        {
            // A failed apply must not crash the tray; refresh the flyout so its update row reflects
            // that the update did not complete (parity with the SettingsWindow update path).
            SyncViewModelFromServices();
        }
    }

    // ============================================================================================
    // Service callbacks
    // ============================================================================================

    private void OnUsageStateChanged(object? sender, EventArgs e)
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            // Evaluate the weekly-low toast ONLY on a genuine poll success - when LastSuccessfulFetch
            // has advanced since the last evaluation. StateChanged also fires on hard-failure and
            // auth-failure ticks (where LatestUsage is the unchanged prior snapshot); re-evaluating
            // the Notifier there is spurious (issue #19). The Notifier still owns its own dedup latch.
            var svc = _usageService;
            if (svc?.LatestUsage is { } usage && _accountStore?.ActiveAccount is { } active
                && svc.LastSuccessfulFetch is { } fetched && fetched != _lastNotifiedFetch)
            {
                _lastNotifiedFetch = fetched;
                // Pass the session reset so the Notifier can clear its latch on a window rollover (U13).
                _notifier?.Evaluate(active, usage.WeeklyRemaining, usage.SessionResetDate);
            }

            RefreshIcon();
            SyncViewModelFromServices();
        }));
    }

    private void OnAuthFailureDetected(object? sender, EventArgs e)
    {
        // A 401/403 stopped polling and nulled usage. Surface the auth-failed icon + flyout; the
        // user re-authenticates via the flyout sign-in or Settings manual paste.
        Dispatcher.BeginInvoke(new Action(() =>
        {
            RefreshIcon();
            SyncViewModelFromServices();
        }));
    }

    private void OnActiveAccountChanged()
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (_accountStore?.ActiveAccount is { } active)
            {
                // Re-seed the transport with the activated account's persisted UA (review F2): the
                // U2 cold-start seed alone left an in-session switch polling the target account's
                // cookies under the PREVIOUS account's UA (a Cloudflare mismatch when their captured
                // UAs differ). Same swap plumbing as the login path; also keeps the fallback-UA
                // escalation flag honest for accounts with no persisted UA.
                RebuildApiWithUserAgent(ResolveSeedUserAgent(active));
                _usageService?.SwitchAccount(active.OrganizationId);
            }
            else
            {
                _usageService?.StopPolling();
            }

            RefreshIcon();
            SyncViewModelFromServices();
        }));
    }

    // ============================================================================================
    // Theme (U9)
    // ============================================================================================

    private void OnThemeBucketsChanged(object? sender, ThemeBuckets buckets)
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            // A real light/dark flip of either bucket: re-paint the tray for the taskbar bucket (the
            // renderer's signature cache makes an unchanged tray bucket a free no-op) and re-theme
            // the open flyout for the app bucket live without close/reopen (DynamicResource swap).
            RefreshIcon();
            _flyout?.ApplyTheme(buckets.App);
        }));
    }

    /// <summary>
    /// The debounce scheduler the <see cref="ThemeWatcher"/> uses: coalesce a burst of General
    /// broadcasts during a theme swap onto a SINGLE re-read after a short window. Uses ONE reusable
    /// <see cref="DispatcherTimer"/> restarted on each broadcast, not a fresh timer per broadcast -
    /// the latter was a fan-out (N broadcasts -> N timers -> N re-reads) that also leaked timers
    /// because none was ever stopped on shutdown (U11/#16).
    /// </summary>
    private void ScheduleThemeDebounced(Action reevaluate)
    {
        _themeReevaluate = reevaluate;
        if (_themeDebounceTimer is null)
        {
            _themeDebounceTimer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher)
            {
                Interval = TimeSpan.FromMilliseconds(250),
            };
            _themeDebounceTimer.Tick += OnThemeDebounceTick;
        }

        // Restart the single timer so a burst collapses to one fire (only the last broadcast wins).
        _themeDebounceTimer.Stop();
        _themeDebounceTimer.Start();
    }

    private void OnThemeDebounceTick(object? sender, EventArgs e)
    {
        _themeDebounceTimer?.Stop(); // one-shot: stop before re-evaluating so it does not repeat
        _themeReevaluate?.Invoke();
    }

    // ============================================================================================
    // Timers (per-minute countdown re-render; mirrors the Mac MenuBarController)
    // ============================================================================================

    private void StartTimers()
    {
        // Per-minute tick: re-compose the countdown so the tray tooltip's "Nh+"/"Nm" tag stays
        // current. The countdown is not part of the drawn icon, so the renderer's signature cache
        // makes the tick a no-op render and this never churns CPU (issue #11 port).
        _countdownTimer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher)
        {
            Interval = TimeSpan.FromSeconds(60),
        };
        _countdownTimer.Tick += (_, _) =>
        {
            RefreshIcon();
            // The flyout's "Updated N minutes ago" + countdowns also drift with wall-clock time.
            if (_flyout is { IsVisible: true })
            {
                _flyoutViewModel?.Refresh();
            }
        };
        _countdownTimer.Start();
    }

    // ============================================================================================
    // System events
    // ============================================================================================

    private void SubscribeSystemEvents()
    {
        // NOTE: A windowless WPF app may not pump the hidden message loop PowerModeChanged needs. If
        // it is NOT observed to fire windowless (verify by suspending the machine), the fallback is a
        // hidden message-only window handling WM_POWERBROADCAST on its WndProc (U10, field-gated). The
        // theme path (UserPreferenceChanged) is owned entirely by the ThemeWatcher, which
        // self-subscribes; App does not duplicate that subscription (U23/#21).
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume)
        {
            // Re-poll on wake; the first post-resume poll tolerates no-network without penalty
            // (UsageService.HandleResume). The signature cache keeps the subsequent repaint cheap.
            Dispatcher.BeginInvoke(new Action(() =>
            {
                // After a display reconfiguration the cached tray image may no longer be on screen,
                // so invalidate the signature before the next paint (Mac wake reset).
                _renderer?.ResetSignature();
                _usageService?.HandleResume();
                RefreshIcon();
            }));
        }
    }

    // ============================================================================================
    // Exit teardown
    // ============================================================================================

    protected override void OnExit(ExitEventArgs e)
    {
        ReleaseForShutdown();
        base.OnExit(e);
    }

    /// <summary>
    /// Ordered teardown shared by normal exit and the update-relaunch path: stop the poller, dispose
    /// WebView2 environments (the open login window), dispose services, then release the
    /// single-instance mutex LAST so a relaunch (incl. an update restart, U12) can re-acquire it
    /// without bouncing off our predecessor.
    /// </summary>
    private void ReleaseForShutdown()
    {
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;

        _countdownTimer?.Stop();
        _countdownTimer = null;

        // Stop the single theme-debounce timer so no post-shutdown tick fires (U11).
        _themeDebounceTimer?.Stop();
        _themeDebounceTimer = null;
        _themeReevaluate = null;

        // Stop polling and tear down any in-flight login (disposes its WebView2 environment + UDF).
        _usageService?.StopPolling();
        _authManager?.StopLoginWindow();

        _showFlyoutWaitRegistration?.Unregister(waitObject: null);
        _showFlyoutWaitRegistration = null;

        _flyout?.Close();
        _flyout = null;
        _settingsWindow?.Close();
        _settingsWindow = null;

        _trayIcon?.Icon?.Dispose();
        _trayIcon?.Dispose();
        _trayIcon = null;

        if (_themeWatcher is not null)
        {
            _themeWatcher.BucketsChanged -= OnThemeBucketsChanged;
        }
        _themeWatcher?.Dispose();
        _renderer?.Dispose();
        _usageService?.Dispose();
        _network?.Dispose();
        _clock?.Dispose();
        (_api as IDisposable)?.Dispose();

        _showFlyoutEvent?.Dispose();
        _showFlyoutEvent = null;

        // Release the single-instance lock LAST so a relaunch (incl. an update restart, U12) can
        // re-acquire it without bouncing off our predecessor. Disposing the FileStream frees the OS
        // lock from ANY thread (no Mutex thread-affinity), so this cannot throw or leave it held.
        ReleaseSingleInstanceLock();
    }

    /// <summary>
    /// The clean-teardown contract the <see cref="UpdateService"/> runs immediately before
    /// <c>ApplyUpdatesAndRestart</c> (U12): stop the poller, dispose WebView2 environments, then
    /// release the mutex LAST. Routes through the same <see cref="ReleaseForShutdown"/> so the
    /// relaunched instance re-acquires the mutex in <see cref="OnStartup"/>.
    /// </summary>
    private sealed class AppUpdateTeardown : IUpdateTeardown
    {
        private readonly App _app;

        public AppUpdateTeardown(App app) => _app = app;

        public void PrepareForRelaunch()
        {
            try
            {
                _app.Dispatcher.Invoke(_app.ReleaseForShutdown);
            }
            catch (Exception)
            {
                // The dispatcher is unreachable (already shutting down). Still free the single-instance
                // lock directly so the relaunched instance becomes primary - the FileStream lock is not
                // thread-affine, so releasing it off the UI thread is safe (unlike Mutex.ReleaseMutex).
                _app.ReleaseSingleInstanceLock();
            }
        }
    }

    // ============================================================================================
    // Constants + interop
    // ============================================================================================

    /// <summary>
    /// The fallback outbound User-Agent used only before a WebView2 login captures the real session
    /// UA this run. It matches a current Chromium-Edge WebView2 UA shape so a restored-account first
    /// poll is plausible; the captured UA replaces it on the first successful login
    /// (<see cref="RebuildApiWithUserAgent"/>). UA match is necessary, not sufficient, for Cloudflare
    /// (the U2 spike resolves whether the SocketsHttpHandler poll clears it at all).
    /// </summary>
    private const string DefaultUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0";

    /// The GitHub Releases page the raw-exe build points at, since it cannot self-update.
    private const string ReleasesPageUrl = "https://github.com/Reebz/claude-battery/releases";

    /// <summary>
    /// The shipped version for the crash log header. Assembly version, not Assembly.Location /
    /// FileVersionInfo: those are empty or throw under PublishSingleFile (the shipped raw exe).
    /// </summary>
    private static string AppVersion => typeof(App).Assembly.GetName().Version?.ToString(3) ?? "unknown";

    /// <summary>
    /// Append one entry to <c>%LocalAppData%\ClaudeBatteryWin\crash.log</c>. Swallows everything: a
    /// crash logger that throws while the process is already dying only hides the original fault.
    /// Every line written stays free of session cookies and keys (only the exception text lands
    /// here), so the redaction gate has nothing to flag.
    /// </summary>
    private static void WriteCrashLog(string source, Exception? ex)
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ClaudeBatteryWin");
            Directory.CreateDirectory(dir);
            File.AppendAllText(
                Path.Combine(dir, "crash.log"),
                FormatCrashEntry(DateTimeOffset.Now, AppVersion, source, ex));
        }
        catch
        {
            // Never throw from the crash logger.
        }
    }

    /// <summary>
    /// One crash-log block: a header line with the ISO-8601 timestamp, the app version and the
    /// source tag, then the exception's full text (type, message, inner exceptions, stack frames),
    /// then a blank separator line. Pure + internal so it is unit-tested directly.
    /// </summary>
    internal static string FormatCrashEntry(DateTimeOffset now, string version, string source, Exception? ex)
        => $"==== {now:O} ClaudeBatteryWin v{version} [{source}] ===={Environment.NewLine}"
            + (ex?.ToString() ?? "(null exception)") + Environment.NewLine
            + Environment.NewLine;

    // The shell's small-icon cell size (GetSystemMetrics(SM_CXSMICON)): 16 at 100% scaling, 24 at
    // 150%, 32 at 200%. Rendering at this size keeps the tray icon crisp instead of shell-upscaled.
    private const int SM_CXSMICON = 49;

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
}

/// <summary>
/// Adapts the <see cref="AccountStore"/> to the <see cref="INotifyLatch"/> the <see cref="Notifier"/>
/// consumes for the dedup latch (set on confirmed delivery, reset on recovery, U11). Keeps the
/// Notifier decoupled from the concrete store.
/// </summary>
internal sealed class AccountStoreNotifyLatch : INotifyLatch
{
    private readonly AccountStore _store;

    public AccountStoreNotifyLatch(AccountStore store) => _store = store;

    public void SetDidNotify(Guid accountId, bool value) => _store.UpdateDidNotify(accountId, value);
}

/// <summary>
/// The production <see cref="ILoginWebViewFactory"/>: builds a fresh ephemeral
/// <see cref="LoginWindow"/> per sign-in attempt (isolated InPrivate UDF, deleted on Dispose) and
/// tracks the live instance so the org picker can center over it and the login-state overlays can
/// be driven. The supplied <paramref name="build"/> delegate wires the window's affordances back to
/// the <see cref="AuthManager"/>.
/// </summary>
internal sealed class LoginWebViewFactory : ILoginWebViewFactory
{
    private readonly Func<LoginWindow> _build;

    public LoginWebViewFactory(Func<LoginWindow> build) => _build = build;

    /// The most recently created login window, while it is open; null once disposed/closed. The
    /// org picker centers over it; the login-state overlays are driven through it.
    public LoginWindow? CurrentWindow { get; private set; }

    public ILoginWebView Create()
    {
        var window = _build();
        CurrentWindow = window;
        window.Closed += () => CurrentWindow = null;
        return window;
    }
}

#if !WINDOWS10_0_19041_0_OR_GREATER
/// <summary>
/// A no-op toast sink for the non-Windows author/test build (the WinRT sink compiles only on the
/// Windows-versioned TFM). It always reports not-delivered, so the <see cref="Notifier"/> never
/// latches a toast the platform cannot show. Never used in a real Windows build.
/// </summary>
internal sealed class NullToastSink : IToastSink
{
    public bool TryShow(string title, string body, Guid tag) => false;
}
#endif
