using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Microsoft.Web.WebView2.Core;

namespace ClaudeBatteryWin.Views;

/// <summary>
/// The production <see cref="ILoginWebView"/>: a WPF window hosting a real WebView2 with an
/// ephemeral, isolated user-data folder (U6). It owns the WebView2 lifecycle and surfaces the
/// capture triggers the <see cref="AuthManager"/> funnel consumes:
///
/// <list type="bullet">
/// <item><b>Ephemeral profile.</b> A unique UDF under <c>%LOCALAPPDATA%\ClaudeBatteryWin\login-udf\</c>
/// with <c>IsInPrivateModeEnabled = true</c>. Deleted in <see cref="Dispose"/> (the finally path that
/// fires on exception too), and a startup sweep (<see cref="SweepStaleLoginProfiles"/>) deletes leftover
/// UDFs from a crash mid-login before the tray icon shows - a crash otherwise leaves an unencrypted
/// session cookie on disk.</item>
/// <item><b>Cookie capture.</b> <c>CookieManager.GetCookiesAsync(null)</c> polled on a 0.2s timer
/// while the window is open, plus on <c>NavigationCompleted</c> and <c>HistoryChanged</c>. The
/// HttpOnly <c>sessionKey</c> + <c>__cf_bm</c> are read directly (no JS <c>document.cookie</c> path -
/// it can never see HttpOnly cookies).</item>
/// <item><b>Navigation gate.</b> <c>NavigationStarting</c> on the main WebView cancels anything the
/// <see cref="AuthManager"/> rejects (exact-domain claude.ai + about: bootstrap).</item>
/// <item><b>OAuth popups.</b> <c>NewWindowRequested</c> routes <c>window.open()</c> to a SEPARATE
/// hosted WebView2 in the same environment, which gets its OWN <c>NavigationStarting</c> handler
/// enforcing the popup allowlist so it cannot wander after the bootstrap.</item>
/// <item><b>UA capture.</b> After the first <c>NavigationCompleted</c>, the session UA is read from
/// <c>CoreWebView2.Settings.UserAgent</c> and handed up for the U3 outbound poll UA.</item>
/// </list>
///
/// The <see cref="AuthManager"/> drives the overlay surfaces (signing-in / error) via
/// <see cref="ShowSigningInOverlay"/> / <see cref="ShowError"/>, wired through the manager's
/// <c>LoginStateChanged</c> event by the integration layer. Escape closes the window (the cancel
/// path), which raises <see cref="ILoginWebView.Closed"/>.
/// </summary>
public partial class LoginWindow : Window, ILoginWebView
{
    private const string LoginUdfRoot = "login-udf";
    private static readonly TimeSpan CookiePollInterval = TimeSpan.FromMilliseconds(200);

    private readonly string _userDataFolder;
    private readonly DispatcherTimer _cookiePollTimer;

    private CoreWebView2Environment? _environment;
    private Microsoft.Web.WebView2.Wpf.WebView2? _popup;
    private Func<string, bool>? _popupGate;
    private bool _hasCapturedUserAgent;
    private bool _disposed;

    public event Func<string, bool>? NavigationStarting;
    public event Action<NavigationCompletedInfo>? NavigationCompleted;
    public event Action<IReadOnlyList<CapturedCookie>>? HistoryChanged;
    public event Action<IReadOnlyList<CapturedCookie>>? CookiesObserved;
    public event Func<string, NewWindowDecision>? NewWindowRequested;
    public event Action<string>? InitFailed;
    public new event Action? Closed;

    /// Latches a single init failure so it is delivered exactly once even if it fires before the
    /// AuthManager subscribes (the init kicks off from the ctor; see InitializeWebView2Async).
    private bool _initFailureRaised;

    // Explicit interface event implementations: ILoginWebView declares non-nullable delegate events
    // (no remove ambiguity with the field-like events above; the +=/-= map straight through).
    event Func<string, bool> ILoginWebView.NavigationStarting
    {
        add => NavigationStarting += value;
        remove => NavigationStarting -= value;
    }

    event Action<NavigationCompletedInfo> ILoginWebView.NavigationCompleted
    {
        add => NavigationCompleted += value;
        remove => NavigationCompleted -= value;
    }

    event Action<IReadOnlyList<CapturedCookie>> ILoginWebView.HistoryChanged
    {
        add => HistoryChanged += value;
        remove => HistoryChanged -= value;
    }

    event Action<IReadOnlyList<CapturedCookie>> ILoginWebView.CookiesObserved
    {
        add => CookiesObserved += value;
        remove => CookiesObserved -= value;
    }

    event Func<string, NewWindowDecision> ILoginWebView.NewWindowRequested
    {
        add => NewWindowRequested += value;
        remove => NewWindowRequested -= value;
    }

    event Action<string> ILoginWebView.InitFailed
    {
        add => InitFailed += value;
        remove => InitFailed -= value;
    }

    event Action ILoginWebView.Closed
    {
        add => Closed += value;
        remove => Closed -= value;
    }

    public LoginWindow()
    {
        InitializeComponent();

        _userDataFolder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ClaudeBatteryWin",
            LoginUdfRoot,
            Guid.NewGuid().ToString("N"));

        _cookiePollTimer = new DispatcherTimer { Interval = CookiePollInterval };
        // async-void event handler: a throw escaping here would crash the process mid-login, so the
        // body is fully guarded (U7). PollCookiesAsync already swallows read failures internally.
        _cookiePollTimer.Tick += async (_, _) =>
        {
            try
            {
                await PollCookiesAsync().ConfigureAwait(true);
            }
            catch (Exception ex)
            {
                DebugLog($"Cookie poll tick threw: {ex.GetType().Name}");
            }
        };

        // Escape closes the window (cancel). The base Window.Closed raises our ILoginWebView.Closed.
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                Close();
            }
        };

        // Route the WPF window-close through our teardown-and-notify path exactly once.
        base.Closed += (_, _) => Closed?.Invoke();

        _ = InitializeWebView2Async();
    }

    /// <summary>
    /// Delete leftover login user-data folders from a previous run that crashed mid-login. MUST be
    /// called at startup before the tray icon shows: a crash leaves an unencrypted session cookie on
    /// disk in the InPrivate UDF, readable by any same-user process. Best-effort; a folder still
    /// locked by a zombie process is skipped, not fatal.
    /// </summary>
    public static void SweepStaleLoginProfiles()
    {
        try
        {
            var root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ClaudeBatteryWin",
                LoginUdfRoot);
            if (!Directory.Exists(root))
            {
                return;
            }

            foreach (var dir in Directory.EnumerateDirectories(root))
            {
                try
                {
                    Directory.Delete(dir, recursive: true);
                }
                catch (IOException)
                {
                    // Locked by a zombie WebView2 host; leave it for the next sweep.
                }
                catch (UnauthorizedAccessException)
                {
                }
            }
        }
        catch (Exception)
        {
            // Never let the sweep block startup.
        }
    }

    private async Task InitializeWebView2Async()
    {
        // Yield first so the rest of this runs AFTER the ctor returns and the AuthManager has wired
        // InitFailed in PresentLogin; otherwise an early synchronous failure (e.g. UDF creation) would
        // raise InitFailed before anyone is listening (U6).
        await Task.Yield();
        try
        {
            // The environment owns the isolated user-data folder; InPrivate mode is a CONTROLLER
            // option (CoreWebView2ControllerOptions.IsInPrivateModeEnabled), not an environment one,
            // so it is set on the controller options handed to EnsureCoreWebView2Async. The UDF still
            // writes to disk during the session, so Dispose deletes it and the startup sweep covers a
            // crash.
            Directory.CreateDirectory(_userDataFolder);
            _environment = await CoreWebView2Environment
                .CreateAsync(browserExecutableFolder: null, userDataFolder: _userDataFolder)
                .ConfigureAwait(true);

            var controllerOptions = _environment.CreateCoreWebView2ControllerOptions();
            controllerOptions.IsInPrivateModeEnabled = true;

            await WebView.EnsureCoreWebView2Async(_environment, controllerOptions).ConfigureAwait(true);

            var core = WebView.CoreWebView2;
            core.NavigationStarting += OnCoreNavigationStarting;
            core.NavigationCompleted += OnCoreNavigationCompleted;
            core.HistoryChanged += OnCoreHistoryChanged;
            core.NewWindowRequested += OnCoreNewWindowRequested;
        }
        catch (Exception ex)
        {
            DebugLog($"WebView2 init failed: {ex.GetType().Name}");
            // A dead WebView2 has nothing to poll; stop the cookie timer so it does not spin (U6).
            _cookiePollTimer.Stop();
            // A failed init must not leave an orphaned UDF on disk.
            DeleteUserDataFolder();
            // Surface the failure so the manager shows an error+retry instead of a silent blank window.
            RaiseInitFailed("Could not start the sign-in browser. Please try again.");
        }
    }

    /// <summary>
    /// Raise <see cref="InitFailed"/> at most once. Both the WebView2 environment init failure and an
    /// OAuth popup-host init failure (U8) route here, so a second failure cannot stack a second error.
    /// </summary>
    private void RaiseInitFailed(string message)
    {
        if (_initFailureRaised)
        {
            return;
        }

        _initFailureRaised = true;
        InitFailed?.Invoke(message);
    }

    public void StartCookiePolling() => _cookiePollTimer.Start();

    public void Navigate(string url) => WebView.CoreWebView2?.Navigate(url);

    void ILoginWebView.Show() => Show();

    void ILoginWebView.Focus()
    {
        if (WindowState == WindowState.Minimized)
        {
            WindowState = WindowState.Normal;
        }

        Activate();
        Topmost = true;
        Topmost = false;
        Focus();
    }

    // ---- Overlay surfaces (driven by AuthManager.LoginStateChanged) ----------------------------

    public void ShowSigningInOverlay()
    {
        ErrorOverlay.Visibility = Visibility.Collapsed;
        SigningInOverlay.Visibility = Visibility.Visible;
    }

    public void ShowError(string message)
    {
        SigningInOverlay.Visibility = Visibility.Collapsed;
        ErrorMessageText.Text = message;
        ErrorOverlay.Visibility = Visibility.Visible;
    }

    public void HideOverlays()
    {
        SigningInOverlay.Visibility = Visibility.Collapsed;
        ErrorOverlay.Visibility = Visibility.Collapsed;
    }

    /// <summary>The "Try again" affordance. Wired by the integration layer to <c>AuthManager.RetryLogin</c>.</summary>
    public event Action? RetryRequested;

    /// <summary>The "Sign in manually" affordance. Wired to <c>AuthManager.RequestManualSignIn</c>.</summary>
    public event Action? ManualSignInRequested;

    private void OnRetryClicked(object sender, RoutedEventArgs e) => RetryRequested?.Invoke();

    private void OnManualClicked(object sender, RoutedEventArgs e) => ManualSignInRequested?.Invoke();

    // ---- CoreWebView2 event bridges ------------------------------------------------------------

    private void OnCoreNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        var allowed = NavigationStarting?.Invoke(e.Uri) ?? true;
        e.Cancel = !allowed;
    }

    private async void OnCoreNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        // async void: a COM throw escaping here would crash the process mid-login, so guard fully (U7).
        try
        {
            string? ua = null;
            if (!_hasCapturedUserAgent && WebView.CoreWebView2 is { } core)
            {
                ua = core.Settings.UserAgent;
                if (!string.IsNullOrEmpty(ua))
                {
                    _hasCapturedUserAgent = true;
                }
            }

            var cookies = await ReadCookiesAsync().ConfigureAwait(true);
            NavigationCompleted?.Invoke(new NavigationCompletedInfo { Cookies = cookies, UserAgent = ua });
        }
        catch (Exception ex)
        {
            DebugLog($"NavigationCompleted handler threw: {ex.GetType().Name}");
        }
    }

    private async void OnCoreHistoryChanged(object? sender, object e)
    {
        // async void: guard fully so a COM throw cannot crash the process mid-login (U7).
        try
        {
            var cookies = await ReadCookiesAsync().ConfigureAwait(true);
            HistoryChanged?.Invoke(cookies);
        }
        catch (Exception ex)
        {
            DebugLog($"HistoryChanged handler threw: {ex.GetType().Name}");
        }
    }

    private void OnCoreNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        var decision = NewWindowRequested?.Invoke(e.Uri) ?? NewWindowDecision.Block;
        if (!decision.Allowed)
        {
            // Handled = true with no NewWindow refuses the popup outright (a disallowed host).
            e.Handled = true;
            return;
        }

        // Route the popup into a separate hosted WebView2 in the SAME environment so window.opener
        // is preserved and the OAuth callback can postMessage back to the claude.ai page. Setting
        // e.NewWindow IS the handling here - do NOT also set Handled = true (that would suppress the
        // window instead of hosting it). A deferral keeps the script blocked until NewWindow is set.
        _popupGate = decision.PopupNavigationGate;
        _ = HostPopupAsync(e);
    }

    private async Task HostPopupAsync(CoreWebView2NewWindowRequestedEventArgs e)
    {
        var deferral = e.GetDeferral();
        try
        {
            // Retire any prior popup before creating a new one.
            TeardownPopup();

            var popup = new Microsoft.Web.WebView2.Wpf.WebView2();
            await popup.EnsureCoreWebView2Async(_environment).ConfigureAwait(true);

            // The popup gets its OWN navigation gate enforcing the same allowlist so it cannot
            // wander outside the OAuth providers after the bootstrap.
            popup.CoreWebView2.NavigationStarting += (_, args) =>
            {
                var allowed = _popupGate?.Invoke(args.Uri) ?? false;
                args.Cancel = !allowed;
            };

            e.NewWindow = popup.CoreWebView2;
            _popup = popup;
        }
        catch (Exception ex)
        {
            // EnsureCoreWebView2Async threw after the deferral was taken. Completing it with a null
            // NewWindow and Handled==false would make WebView2 silently block the popup, so
            // "Continue with Google" looks dead. Explicitly refuse (Handled = true) and surface a
            // retry error instead of a silent no-op (U8).
            DebugLog($"OAuth popup host init failed: {ex.GetType().Name}");
            TeardownPopup();
            e.Handled = true;
            RaiseInitFailed("Could not open the sign-in popup. Please try again.");
        }
        finally
        {
            deferral.Complete();
        }
    }

    private void TeardownPopup()
    {
        if (_popup is null)
        {
            return;
        }

        try
        {
            _popup.Dispose();
        }
        catch (Exception)
        {
            // Disposing an already-closed popup must not abort teardown.
        }

        _popup = null;
        _popupGate = null;
    }

    // ---- Cookie reads --------------------------------------------------------------------------

    private async Task PollCookiesAsync()
    {
        var cookies = await ReadCookiesAsync().ConfigureAwait(true);
        if (cookies.Count > 0)
        {
            CookiesObserved?.Invoke(cookies);
        }
    }

    /// <summary>
    /// Read every cookie from the WebView2 profile via <c>GetCookiesAsync(null)</c> - returns HttpOnly
    /// cookies too (<c>sessionKey</c>, <c>__cf_bm</c>), unlike a JS <c>document.cookie</c> read. Maps
    /// each onto a <see cref="CapturedCookie"/> for the manager's funnel. Cookie VALUES are never
    /// logged.
    /// </summary>
    private async Task<IReadOnlyList<CapturedCookie>> ReadCookiesAsync()
    {
        var core = WebView.CoreWebView2;
        if (core is null)
        {
            return Array.Empty<CapturedCookie>();
        }

        try
        {
            var raw = await core.CookieManager.GetCookiesAsync(null).ConfigureAwait(true);
            var mapped = new List<CapturedCookie>(raw.Count);
            foreach (var c in raw)
            {
                mapped.Add(new CapturedCookie
                {
                    Name = c.Name,
                    Value = c.Value,
                    Domain = c.Domain,
                    Path = c.Path,
                    IsSecure = c.IsSecure,
                    IsHttpOnly = c.IsHttpOnly,
                });
            }

            return mapped;
        }
        catch (Exception)
        {
            // A teardown mid-read (the core disposed) must not crash the poll tick.
            return Array.Empty<CapturedCookie>();
        }
    }

    // ---- Teardown ------------------------------------------------------------------------------

    public new void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        try
        {
            _cookiePollTimer.Stop();
            TeardownPopup();

            if (WebView.CoreWebView2 is { } core)
            {
                core.NavigationStarting -= OnCoreNavigationStarting;
                core.NavigationCompleted -= OnCoreNavigationCompleted;
                core.HistoryChanged -= OnCoreHistoryChanged;
                core.NewWindowRequested -= OnCoreNewWindowRequested;
            }

            WebView.Dispose();
        }
        catch (Exception)
        {
            // Best-effort teardown; the UDF deletion below is the security-critical part.
        }
        finally
        {
            // The finally path that fires even on an earlier exception: delete the InPrivate UDF so
            // no session material is left on disk.
            DeleteUserDataFolder();

            if (IsLoaded)
            {
                try
                {
                    base.Close();
                }
                catch (Exception)
                {
                }
            }
        }
    }

    private void DeleteUserDataFolder()
    {
        try
        {
            if (Directory.Exists(_userDataFolder))
            {
                Directory.Delete(_userDataFolder, recursive: true);
            }
        }
        catch (IOException)
        {
            // Still locked by the WebView2 host process tearing down; the startup sweep covers it.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[LoginWindow] {message}");
}
