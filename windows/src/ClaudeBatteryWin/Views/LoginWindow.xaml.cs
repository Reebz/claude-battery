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
/// WebView2 hosted in its own <see cref="OAuthPopupWindow"/>, initialised on the same environment
/// AND the same InPrivate profile (the controller options kept in <c>_controllerOptions</c>).
/// WebView2 requires a <c>NewWindow</c> to share the opener's profile, and without it the popup's
/// cookies would land in a jar the main view's <c>CookieManager</c> never reads, so the callback
/// that sets <c>sessionKey</c> would never be captured. The popup lives in a real window because a
/// WebView2 control outside a visual tree never finishes initialising. It gets its OWN
/// <c>NavigationStarting</c> handler enforcing the popup allowlist so it cannot wander after the
/// bootstrap, and it is torn down when the page calls <c>window.close()</c> or the user closes it.</item>
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

    // Bridges a Navigate() call issued before CoreWebView2 exists (PresentLogin navigates synchronously
    // right after Create(), while init is still async) to the init success path that replays it. Without
    // it the first navigation is silently dropped and the window stays blank at about:blank.
    private readonly PendingNavigation _pendingNavigation = new();

    private CoreWebView2Environment? _environment;

    // The controller options the main view was created with (IsInPrivateModeEnabled = true). Kept
    // so an OAuth popup is initialised with the SAME options and therefore the same InPrivate
    // profile - WebView2 rejects a NewWindow on a different profile, and a different profile would
    // hold the popup's cookies where the main view's CookieManager cannot see them.
    private CoreWebView2ControllerOptions? _controllerOptions;
    private OAuthPopupWindow? _popup;
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

            _controllerOptions = _environment.CreateCoreWebView2ControllerOptions();
            _controllerOptions.IsInPrivateModeEnabled = true;

            await WebView.EnsureCoreWebView2Async(_environment, _controllerOptions).ConfigureAwait(true);

            var core = WebView.CoreWebView2;
            core.NavigationStarting += OnCoreNavigationStarting;
            core.NavigationCompleted += OnCoreNavigationCompleted;
            core.HistoryChanged += OnCoreHistoryChanged;
            core.NewWindowRequested += OnCoreNewWindowRequested;

            // Replay any navigation requested before the core was ready - the PresentLogin initial load
            // (and any Retry issued during init). Routed through core.Navigate so it still passes the
            // NavigationStarting gate. Without this the first navigation is lost and the window stays
            // blank at about:blank (the field bug: blank "Sign in to Claude" window, zero network).
            if (_pendingNavigation.TryConsume(out var pendingUrl))
            {
                core.Navigate(pendingUrl);
            }
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

    public void Navigate(string url)
    {
        // The core initializes asynchronously (InitializeWebView2Async), and AuthManager.PresentLogin
        // calls Navigate synchronously right after Create() - so on the first call CoreWebView2 is null
        // and a direct Navigate would be silently dropped, leaving the window blank at about:blank.
        // Latch the URL when the core is not ready; the init success path replays it. When the core is
        // already up (e.g. the Retry path after a completed init), navigate immediately.
        if (WebView.CoreWebView2 is { } core)
        {
            core.Navigate(url);
            return;
        }

        _pendingNavigation.Set(url);
    }

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
        // Synchronous WebView2 COM callback: a throw escaping here propagates into the COM caller and
        // can crash the host mid-login. Guard fully (U9, mirroring the async-void guards above). On an
        // unexpected throw, refuse the popup deterministically (Handled = true) and surface the
        // retry/init-fail path rather than leaving "Continue with Google" in an undefined state.
        try
        {
            var decision = NewWindowRequested?.Invoke(e.Uri) ?? NewWindowDecision.Block;
            if (!decision.Allowed)
            {
                // Handled = true with no NewWindow refuses the popup outright (a disallowed host).
                e.Handled = true;
                return;
            }

            // Route the popup into a separate hosted WebView2 in the SAME environment AND the same
            // InPrivate profile so window.opener is preserved, the OAuth callback can postMessage back
            // to the claude.ai page, and any cookie the popup sets lands in the jar the main view's
            // CookieManager reads. Setting e.NewWindow IS the handling here - do NOT also set
            // Handled = true (that would suppress the window instead of hosting it). A deferral keeps
            // the script blocked until NewWindow is set.
            // The gate travels as an argument (not a shared field) so a 2nd popup's TeardownPopup of the
            // 1st cannot null the gate the new popup's NavigationStarting closure depends on.
            _ = HostPopupAsync(e, decision.PopupNavigationGate);
        }
        catch (Exception ex)
        {
            DebugLog($"NewWindowRequested handler threw: {ex.GetType().Name}");
            e.Handled = true;
            RaiseInitFailed("Could not open the sign-in popup. Please try again.");
        }
    }

    private async Task HostPopupAsync(CoreWebView2NewWindowRequestedEventArgs e, Func<string, bool>? popupGate)
    {
        // Take the deferral INSIDE the try and complete it in finally so no path - including a throw
        // from GetDeferral itself - can leave WebView2 awaiting an uncompleted deferral (U9). A null
        // deferral (GetDeferral threw before assignment) makes the finally a no-op.
        CoreWebView2Deferral? deferral = null;
        try
        {
            deferral = e.GetDeferral();

            // Retire any prior popup before creating a new one.
            TeardownPopup();

            // A popup can only come from the main view's NewWindowRequested, so its options must
            // exist by now; a null here means init never completed and there is no profile to share.
            if (_controllerOptions is null)
            {
                throw new InvalidOperationException("OAuth popup requested before the login WebView2 initialised.");
            }

            // Host the popup control in a real, shown window FIRST: the WPF WebView2 is an HwndHost
            // whose EnsureCoreWebView2Async waits for the host HWND, so a control that is not in a
            // visual tree never finishes initialising (the await below would hang forever).
            var popupWindow = new OAuthPopupWindow();
            // Field assignment before any await so the catch's TeardownPopup disposes it on failure.
            _popup = popupWindow;

            // The user closing the popup (title-bar X) must dispose its control and release the
            // field, but only if it is still the CURRENT popup - a retired one was already torn
            // down by TeardownPopup, whose Close raises this same event (Dispose is a no-op then).
            popupWindow.Closed += (_, _) =>
            {
                if (ReferenceEquals(_popup, popupWindow))
                {
                    _popup = null;
                }

                popupWindow.Dispose();
            };

            // Owner keeps the popup above the login window and closes it with the owner. WPF only
            // accepts an owner that already has a native handle, which the login window has once
            // shown; a not-yet-shown owner (defensive) just leaves the popup unowned.
            if (new System.Windows.Interop.WindowInteropHelper(this).Handle != IntPtr.Zero)
            {
                popupWindow.Owner = this;
            }
            else
            {
                popupWindow.WindowStartupLocation = WindowStartupLocation.CenterScreen;
            }

            popupWindow.Show();

            // Same environment AND the same controller options as the main view, so both views share
            // one InPrivate profile (WebView2 requires a NewWindow to share the opener's profile).
            await popupWindow.WebView.EnsureCoreWebView2Async(_environment, _controllerOptions).ConfigureAwait(true);

            var popupCore = popupWindow.WebView.CoreWebView2;
            var mainCore = WebView.CoreWebView2
                ?? throw new InvalidOperationException("Login WebView2 core is gone while hosting a popup.");

            // Blind self-check before handing the view over: if the profiles differ, WebView2 would
            // reject the NewWindow or the popup's cookies would be invisible to the main view's
            // reads - either way sign-in silently never completes. Throwing here lands in the catch
            // below, so a regression shows up as the "Could not open the sign-in popup" card.
            var popupProfile = popupCore.Profile;
            var mainProfile = mainCore.Profile;
            if (popupProfile.IsInPrivateModeEnabled != mainProfile.IsInPrivateModeEnabled
                || !string.Equals(popupProfile.ProfilePath, mainProfile.ProfilePath, StringComparison.OrdinalIgnoreCase))
            {
                DebugLog($"OAuth popup profile mismatch: inPrivate popup={popupProfile.IsInPrivateModeEnabled} main={mainProfile.IsInPrivateModeEnabled}, samePath={string.Equals(popupProfile.ProfilePath, mainProfile.ProfilePath, StringComparison.OrdinalIgnoreCase)}");
                throw new InvalidOperationException("OAuth popup profile does not match the login view's profile.");
            }

            // The popup gets its OWN navigation gate enforcing the same allowlist so it cannot
            // wander outside the OAuth providers after the bootstrap. Bind the gate captured for THIS
            // popup (the argument), never a shared field a later popup's teardown could null.
            popupCore.NavigationStarting += (_, args) =>
            {
                var allowed = popupGate?.Invoke(args.Uri) ?? false;
                args.Cancel = !allowed;
            };

            // OAuth pages call window.close() once the callback has posted back to the opener.
            // Tear the popup down then - off the COM callback frame (BeginInvoke), since disposing
            // a CoreWebView2 from inside its own event handler is re-entrant - and only if it is
            // still the current popup.
            popupCore.WindowCloseRequested += (_, _) =>
            {
                Dispatcher.BeginInvoke(() =>
                {
                    if (ReferenceEquals(_popup, popupWindow))
                    {
                        TeardownPopup();
                    }
                });
            };

            // Never set Source or call Navigate on the popup: WebView2 performs its first navigation
            // itself once NewWindow is assigned, and a NewWindow must not have been navigated.
            e.NewWindow = popupCore;
        }
        catch (Exception ex)
        {
            // EnsureCoreWebView2Async threw (or the profile self-check failed) after the deferral was
            // taken. Completing it with a null NewWindow and Handled==false would make WebView2
            // silently block the popup, so "Continue with Google" looks dead. Explicitly refuse
            // (Handled = true), close the half-built popup window, and surface a retry error instead
            // of a silent no-op (U8).
            DebugLog($"OAuth popup host init failed: {ex.GetType().Name}");
            TeardownPopup();
            e.Handled = true;
            RaiseInitFailed("Could not open the sign-in popup. Please try again.");
        }
        finally
        {
            deferral?.Complete();
        }
    }

    private void TeardownPopup()
    {
        if (_popup is null)
        {
            return;
        }

        // Clear the field before disposing: Dispose closes the window, whose Closed handler checks
        // the field to decide whether it is retiring the current popup.
        var popup = _popup;
        _popup = null;

        try
        {
            // Disposes the hosted WebView2 control, then closes the window if it is still open.
            popup.Dispose();
        }
        catch (Exception)
        {
            // Disposing an already-closed popup must not abort teardown.
        }
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
