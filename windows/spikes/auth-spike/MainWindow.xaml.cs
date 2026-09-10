using System.IO;
using System.Linq;
using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace AuthSpike;

/// <summary>
/// The interactive harness window for the U2 spike. It hosts a real WebView2 configured EXACTLY like
/// the production <c>LoginWindow</c> (ephemeral isolated user-data folder, <c>IsInPrivateModeEnabled</c>),
/// so the captured session UA and the cookies it primes match what ships. A human drives a real login
/// in the WebView, then clicks "Run U2 gate test" to fire the load-bearing poll through the production
/// transport. See <see cref="SpikeRunner"/> for the gate logic and README.md for the run script.
/// </summary>
public partial class MainWindow : Window
{
    private const string LoginUrl = "https://claude.ai/login";

    private readonly string _userDataFolder;
    private CoreWebView2Environment? _environment;
    private string? _capturedUserAgent;
    private bool _initialized;
    private bool _loggedResidual;

    public MainWindow()
    {
        InitializeComponent();

        // An ephemeral, isolated UDF under TEMP (the production LoginWindow uses %LOCALAPPDATA%; a
        // throwaway spike uses TEMP). Deleted on close. The Guid keeps each run isolated.
        _userDataFolder = Path.Combine(
            Path.GetTempPath(),
            "auth-spike-udf",
            Guid.NewGuid().ToString("N"));

        Loaded += OnLoaded;
        Closed += OnClosed;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        // Step 7 (runtime-absent observation): record what the availability probe returns BEFORE
        // creating the environment. On a box WITH the runtime this logs a version; on a box without
        // it, the thrown exception type/message is the signal handed to U8's RuntimeMissingWindow.
        try
        {
            var version = CoreWebView2Environment.GetAvailableBrowserVersionString(browserExecutableFolder: null);
            Log($"[RUNTIME] WebView2 runtime present: version {version}");
        }
        catch (Exception ex)
        {
            Log($"[RUNTIME] GetAvailableBrowserVersionString threw {ex.GetType().Name}: {ex.Message}");
            Log("[RUNTIME] (no runtime installed - this is the U8 RuntimeMissingWindow trigger signal.)");
        }

        try
        {
            // Mirror the production LoginWindow init: isolated UDF + InPrivate controller option.
            Directory.CreateDirectory(_userDataFolder);
            _environment = await CoreWebView2Environment.CreateAsync(
                browserExecutableFolder: null,
                userDataFolder: _userDataFolder);

            var controllerOptions = _environment.CreateCoreWebView2ControllerOptions();
            controllerOptions.IsInPrivateModeEnabled = true;

            await WebView.EnsureCoreWebView2Async(_environment, controllerOptions);

            WebView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
            _initialized = true;

            Log($"[UDF] ephemeral InPrivate user-data folder: {_userDataFolder}");
            Log("[STEP 2] Drive a real login in the window (Google / Apple / email-code / SSO).");
            Log("[STEP 2] Record per-provider: completes / blocked (disallowed_useragent) / partial.");
            Log("[STEP 5] When the dashboard has loaded, click \"Run U2 gate test\".");

            WebView.CoreWebView2.Navigate(LoginUrl);
        }
        catch (Exception ex)
        {
            Log($"[INIT] WebView2 init failed: {ex.GetType().Name}: {ex.Message}");
        }
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        // Step 4 (UA capture): read the session UA off the first completed navigation, exactly as the
        // production LoginWindow does. This is the UA the outbound poll must send verbatim.
        if (_capturedUserAgent is null && WebView.CoreWebView2 is { } core)
        {
            var ua = core.Settings.UserAgent;
            if (!string.IsNullOrEmpty(ua))
            {
                _capturedUserAgent = ua;
                Log($"[UA] captured WebView2 session User-Agent (length {ua.Length}).");
            }
        }

        // Step 6 (UDF residual): confirm session material lands on disk during the session, so the
        // production sweep/delete is load-bearing security rather than theatre. Logged once.
        if (!_loggedResidual)
        {
            try
            {
                if (Directory.Exists(_userDataFolder))
                {
                    var fileCount = Directory
                        .EnumerateFiles(_userDataFolder, "*", SearchOption.AllDirectories)
                        .Count();
                    Log($"[UDF] {fileCount} file(s) on disk in the UDF during the session "
                        + "(> 0 confirms the production sweep/delete protects a real on-disk cookie).");
                    _loggedResidual = true;
                }
            }
            catch
            {
                // Best-effort observation; never disrupt the harness.
            }
        }
    }

    private async void OnRunGateClicked(object sender, RoutedEventArgs e)
    {
        if (!_initialized || WebView.CoreWebView2 is not { } core)
        {
            Log("[GATE] WebView2 is not initialized yet - wait for the login page to load.");
            return;
        }

        GateButton.IsEnabled = false;
        try
        {
            // Step 3 capture: GetCookiesAsync(null) returns HttpOnly cookies too (sessionKey, __cf_bm),
            // unlike a JS document.cookie read - the same call the production LoginWindow makes.
            var cookies = await core.CookieManager.GetCookiesAsync(null);
            await SpikeRunner.RunGateAsync(cookies, _capturedUserAgent, Log);
        }
        catch (Exception ex)
        {
            Log($"[GATE] threw {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            GateButton.IsEnabled = true;
        }
    }

    private void OnHomeClicked(object sender, RoutedEventArgs e) => WebView.CoreWebView2?.Navigate(LoginUrl);

    private void OnClearLogClicked(object sender, RoutedEventArgs e) => LogBox.Clear();

    private void OnCopyLogClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            Clipboard.SetText(LogBox.Text);
        }
        catch
        {
            // Clipboard contention is non-fatal for a throwaway harness.
        }
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        // Throwaway hygiene: dispose the WebView and delete the ephemeral UDF so no session cookie is
        // left on disk after the run (the production LoginWindow.Dispose does the same).
        try
        {
            WebView.Dispose();
        }
        catch
        {
        }

        try
        {
            if (Directory.Exists(_userDataFolder))
            {
                Directory.Delete(_userDataFolder, recursive: true);
            }
        }
        catch
        {
            // A still-locked UDF from a tearing-down host process is acceptable for a throwaway spike.
        }
    }

    private void Log(string message)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(new Action(() => Log(message)));
            return;
        }

        LogBox.AppendText(message + Environment.NewLine);
        LogBox.ScrollToEnd();
    }
}
