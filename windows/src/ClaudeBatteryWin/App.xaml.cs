using System.Drawing;
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
/// </list>
/// </summary>
public partial class App : Application
{
    // Per-user names: the suffix keeps two different Windows users from colliding on a machine
    // with fast-user-switching. The GUID-ish base keeps the names from clashing with other apps.
    private const string SingleInstanceMutexName = @"Local\ClaudeBatteryWin.SingleInstance.7E2C1B44";
    private const string ShowFlyoutEventName = @"Local\ClaudeBatteryWin.ShowFlyout.7E2C1B44";

    private Mutex? _singleInstanceMutex;
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

    // Guards against re-entrant tray clicks while the runtime-missing window is up.
    private bool _runtimeWindowOpen;

    protected override void OnStartup(StartupEventArgs e)
    {
        // --- Velopack MUST run first (U12) ----------------------------------------------------
        // Install/uninstall/update hooks run synchronously here and exit the process for hook
        // invocations; if this is not first, a freshly applied update can re-run the old binary's
        // UI on the hook launch. No tray icon, no window, no service may precede it.
        VelopackApp.Build().Run();

        // --- Single-instance gate -------------------------------------------------------------
        // createdNew is false when another instance already holds the mutex.
        _singleInstanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var createdNew);

        // The named auto-reset event the running instance waits on; a second launch sets it.
        _showFlyoutEvent = new EventWaitHandle(
            initialState: false,
            mode: EventResetMode.AutoReset,
            name: ShowFlyoutEventName);

        if (!createdNew)
        {
            // Another instance is already running. Signal it to surface the flyout, then exit
            // WITHOUT showing a tray icon (so a double-launch never yields two icons).
            _showFlyoutEvent.Set();
            // Release our (non-owning) handles before bailing; we never acquired the mutex.
            _showFlyoutEvent.Dispose();
            _singleInstanceMutex.Dispose();
            _singleInstanceMutex = null;
            Shutdown();
            return;
        }

        // We are the primary instance. Wait (off the UI thread) for any later launch to signal,
        // and marshal the show-flyout request back onto the dispatcher.
        _showFlyoutWaitRegistration = ThreadPool.RegisterWaitForSingleObject(
            _showFlyoutEvent,
            (_, _) => Dispatcher.BeginInvoke(new Action(ShowFlyout)),
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
        AcquireTrayIcon();
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

        // Surface any accounts dropped at load (corrupt DPAPI blob) as a one-time re-auth nudge by
        // refreshing the flyout view-model; the flyout shows the unauthenticated/auth surfaces.
        SyncViewModelFromServices();

        // Fire the first update check in the background; the flyout/Settings rows read the result.
        _ = CheckForUpdatesAsync();
    }

    // ============================================================================================
    // Object graph
    // ============================================================================================

    private void BuildObjectGraph()
    {
        // Shared cookie jar: the SAME instance the AccountStore primes and the ClaudeApi transport
        // reads from, so cookie rotation (__cf_bm) and account switches are reflected in both.
        _cookieJar = new CookieContainer();

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
        _api = new SwappableClaudeApi(new ClaudeApi(_cookieJar, DefaultUserAgent));

        _network = new SystemNetworkAvailability();
        _clock = new SystemSchedulerClock();
        // The poller reads the AccountStore's request generation live so a poll superseded by an
        // account switch/re-auth discards its result instead of writing onto the new account (U2).
        _usageService = new UsageService(_api, _network, _clock, () => _accountStore?.CurrentGeneration ?? 0);
        _usageService.StateChanged += OnUsageStateChanged;
        _usageService.AuthFailureDetected += OnAuthFailureDetected;

        // The AccountStore drives the activation boundary; when the active account changes, restart
        // (or stop) polling against the new org.
        _accountStore.ActiveAccountChanged += OnActiveAccountChanged;

        _renderer = new DualHorizontalRenderer();

        // ThemeWatcher debounce: coalesce a burst of General broadcasts onto one re-read after a
        // short window on the UI thread. A real light/dark flip re-renders the icon + re-themes the
        // open flyout; an unrelated broadcast that lands on the same bucket is suppressed (U9).
        _themeWatcher = new ThemeWatcher(ScheduleThemeDebounced);
        _themeWatcher.BucketChanged += OnThemeBucketChanged;

        _settings = new AppSettings();
        _settings.Changed += (_, _) => RefreshIcon(); // countdown toggle re-composes the cell

        // Notifier: weekly-low toasts, gated on the global enable flag (read live), latch on the
        // AccountStore, delivery through the WinRT sink (or a no-op sink off-Windows / in author build).
        _notifier = new Notifier(
            notificationsEnabled: () => _settings.NotificationsEnabled,
            latch: new AccountStoreNotifyLatch(_accountStore),
            toastSink: CreateToastSink());

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
    }

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

    private void AcquireTrayIcon()
    {
        _trayIcon = (TaskbarIcon)FindResource("TrayIcon");

        // Left-click opens the flyout. Wired in code (App.xaml declares no LeftClickCommand binding,
        // since the resource has no DataContext) so the shell is self-consistent.
        _trayIcon.TrayLeftMouseUp += (_, _) => ShowFlyout();

        _trayIcon.ContextMenu = BuildTrayContextMenu();

        // ForceCreate ensures the Win32 icon exists immediately at startup, with no taskbar window
        // present (R1). registerAlsoInWow64 = false: this is a 64-bit (win-x64) build.
        _trayIcon.ForceCreate(enablesEfficiencyMode: false);
    }

    private System.Windows.Controls.ContextMenu BuildTrayContextMenu()
    {
        var menu = new System.Windows.Controls.ContextMenu();

        var settings = new System.Windows.Controls.MenuItem { Header = "Settings…" };
        settings.Click += (_, _) => OpenSettings();
        menu.Items.Add(settings);

        var checkUpdates = new System.Windows.Controls.MenuItem { Header = "Check for Updates…" };
        checkUpdates.Click += async (_, _) => await CheckForUpdatesAsync().ConfigureAwait(true);
        menu.Items.Add(checkUpdates);

        menu.Items.Add(new System.Windows.Controls.Separator());

        var quit = new System.Windows.Controls.MenuItem { Header = "Quit Claude Battery" };
        quit.Click += (_, _) => Shutdown();
        menu.Items.Add(quit);

        return menu;
    }

    /// <summary>
    /// Repaint the tray icon for the current usage/auth/theme/countdown state. The renderer's
    /// signature cache short-circuits a redundant paint (issue #11 port), so calling this on every
    /// poll, theme flip, and per-minute tick is cheap. A null return means "no change"; we keep the
    /// current icon. A produced bitmap is converted to a System.Drawing.Icon for the tray.
    /// </summary>
    private void RefreshIcon()
    {
        if (_renderer is null || _themeWatcher is null || _trayIcon is null)
        {
            return;
        }

        var state = ResolveTrayState();
        var theme = _themeWatcher.CurrentBucket;
        var usage = _usageService?.LatestUsage;
        var countdown = DualHorizontalRenderer.CountdownCellText(
            usage,
            _settings?.ShowSessionCountdown ?? false,
            DateTimeOffset.UtcNow);

        var bitmap = _renderer.Render(state, theme, countdown);
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
    /// Map the polling/auth state to the tray render branch, mirroring the Mac MenuBarController
    /// RenderState selection: auth-failed -> faded "!"; an account with a usable snapshot -> the
    /// battery; no account -> the hollow outline; repeated hard failures with no snapshot -> "!";
    /// a stale snapshot -> "..."; an in-flight first poll -> a solid "...".
    /// </summary>
    private TrayRenderState ResolveTrayState()
    {
        var store = _accountStore;
        var svc = _usageService;

        if (store is null || !store.IsAuthenticated)
        {
            return new TrayRenderState.Unauthenticated();
        }

        if (svc is null)
        {
            return new TrayRenderState.StatusLoading();
        }

        if (svc.AuthFailed)
        {
            return new TrayRenderState.AuthFailed();
        }

        if (svc.LatestUsage is { } usage)
        {
            return svc.IsStale
                ? new TrayRenderState.StatusStale()
                : new TrayRenderState.Battery(usage);
        }

        if (svc.ConsecutiveFailures >= 10)
        {
            return new TrayRenderState.StatusError();
        }

        return new TrayRenderState.StatusLoading();
    }

    // ============================================================================================
    // Flyout
    // ============================================================================================

    /// <summary>
    /// Surface the flyout anchored to the tray rect. The second-instance signal and the tray
    /// left-click both route here. Lazily constructs the window, binds the view-model, applies the
    /// current theme, and positions it (U10).
    /// </summary>
    private void ShowFlyout()
    {
        if (_flyoutViewModel is null)
        {
            return;
        }

        if (_flyout is null)
        {
            _flyout = new FlyoutWindow { DataContext = _flyoutViewModel };
            _flyout.ApplyTheme(_themeWatcher?.CurrentBucket ?? ThemeBucket.Light);
            WireFlyoutInteractions(_flyout);
        }

        SyncViewModelFromServices();
        _flyout.ApplyTheme(_themeWatcher?.CurrentBucket ?? ThemeBucket.Light);
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
        HookButton(flyout, "AddAccountLinkButton", BeginLogin);
        HookButton(flyout, "LoginErrorTryAgainButton", () => _authManager?.RetryLogin());
        HookButton(flyout, "UpdateLinkButton", () => _ = ApplyUpdateAsync());
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

        _flyoutViewModel.IsAuthenticated = store?.IsAuthenticated ?? false;
        _flyoutViewModel.Accounts = store?.Accounts ?? Array.Empty<Account>();
        _flyoutViewModel.ActiveAccountId = store?.ActiveAccountId;
        _flyoutViewModel.CanAddAccount = store?.CanAddAccount ?? true;

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
            // Reflect the state onto the live login window's overlays.
            if (_loginWebViewFactory?.CurrentWindow is { } window)
            {
                switch (state.Kind)
                {
                    case LoginStateKind.SigningIn:
                    case LoginStateKind.Capturing:
                    case LoginStateKind.OrgDiscovery:
                    case LoginStateKind.Picker:
                        window.ShowSigningInOverlay();
                        break;
                    case LoginStateKind.Error:
                        window.ShowError(state.Message ?? "Sign-in failed. Please try again.");
                        break;
                    default:
                        window.HideOverlays();
                        break;
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
            _settingsWindow = new SettingsWindow(_accountStore, _manualSignIn, _autostart, _settings, _updateService);
            _settingsWindow.AddAccountRequested += (_, _) => BeginLogin();
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }

        _settingsWindow.Show();
        _settingsWindow.Activate();
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

        Dispatcher.BeginInvoke(new Action(SyncViewModelFromServices));
    }

    private async Task ApplyUpdateAsync()
    {
        if (_updateService is null)
        {
            return;
        }

        // ApplyUpdateAsync runs the clean teardown (AppUpdateTeardown below) then relaunches and
        // never returns on a real install; a false return (dev/test/no update) leaves us running.
        await _updateService.ApplyUpdateAsync().ConfigureAwait(true);
    }

    // ============================================================================================
    // Service callbacks
    // ============================================================================================

    private void OnUsageStateChanged(object? sender, EventArgs e)
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            // Fire the weekly-low toast off the resolved snapshot (Notifier owns the dedup + the
            // delivery-order fix). Then refresh the icon and the flyout.
            if (_usageService?.LatestUsage is { } usage && _accountStore?.ActiveAccount is { } active)
            {
                _notifier?.Evaluate(active, usage.WeeklyRemaining);
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

    private void OnThemeBucketChanged(object? sender, ThemeBucket bucket)
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            // A real light/dark flip: re-paint the tray (the signature now differs on the theme
            // bucket) and re-theme the open flyout live without close/reopen (DynamicResource swap).
            RefreshIcon();
            _flyout?.ApplyTheme(bucket);
        }));
    }

    /// <summary>
    /// The debounce scheduler the <see cref="ThemeWatcher"/> uses: post the coalesced re-read onto
    /// a one-shot WPF <see cref="DispatcherTimer"/> after a short window, so a burst of General
    /// broadcasts during a theme swap collapses to one re-read on the UI thread.
    /// </summary>
    private void ScheduleThemeDebounced(Action reevaluate)
    {
        var timer = new DispatcherTimer(DispatcherPriority.Background, Dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(250),
        };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            reevaluate();
        };
        timer.Start();
    }

    // ============================================================================================
    // Timers (per-minute countdown re-render; mirrors the Mac MenuBarController)
    // ============================================================================================

    private void StartTimers()
    {
        // Per-minute tick: re-compose the countdown cell so the tray "Nh+"/"Nm" tag stays current.
        // The renderer's signature cache means a tick that does not change the drawn string is a
        // no-op render, so this never churns CPU (issue #11 port).
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
        // NOTE: A windowless WPF app may not pump the hidden message loop these broadcasts need.
        // If PowerModeChanged / UserPreferenceChanged are NOT observed to fire in this configuration
        // (verify by toggling the system theme and suspending the machine), the fallback is to host
        // a hidden message-only window and subscribe to WM_POWERBROADCAST / WM_SETTINGCHANGE on its
        // WndProc. The U1 verification step covers this; the ThemeWatcher also self-subscribes to
        // UserPreferenceChanged for the theme path.
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
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

    private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        // The ThemeWatcher self-subscribes and owns the filter/debounce/dedup. This handler stays as
        // the documented entry point + future hook; the theme path is fully handled in ThemeWatcher.
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
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;

        _countdownTimer?.Stop();
        _countdownTimer = null;

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

        _themeWatcher?.Dispose();
        _renderer?.Dispose();
        _usageService?.Dispose();
        _network?.Dispose();
        _clock?.Dispose();
        (_api as IDisposable)?.Dispose();

        _showFlyoutEvent?.Dispose();
        _showFlyoutEvent = null;

        // Release the single-instance mutex LAST so a relaunch (incl. an update restart, U12) can
        // re-acquire it without bouncing off our predecessor.
        try
        {
            _singleInstanceMutex?.ReleaseMutex();
        }
        catch (ApplicationException)
        {
            // Not the owning thread (already released by the update teardown); safe to ignore.
        }
        _singleInstanceMutex?.Dispose();
        _singleInstanceMutex = null;
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
            => _app.Dispatcher.Invoke(_app.ReleaseForShutdown);
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
