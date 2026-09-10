using System.Diagnostics;
using System.Windows;
using ClaudeBatteryWin.Services;

namespace ClaudeBatteryWin.Views;

/// <summary>
/// The separate runtime-bootstrap window (U8). Shown in place of the login window whenever the
/// WebView2 runtime is absent, it drives <see cref="WebView2Runtime.EnsureRuntimeAsync"/> and
/// blocks login until the install succeeds. A failed or offline install turns the primary button
/// into a Retry, shows the reason, and offers Microsoft's download page as a manual fallback (Retry
/// then re-probes, so a hand-installed runtime unblocks login) -- never a blank window or a crash.
///
/// The caller opens this with <see cref="ShowDialog"/> and, after it closes, reads
/// <see cref="RuntimeReady"/>: true means the runtime is now present and login may proceed; false
/// means the user dismissed without installing and login stays blocked (the tray click routes back
/// here next time).
/// </summary>
public partial class RuntimeMissingWindow : Window
{
    // Microsoft's WebView2 download page, for the manual fallback when the in-app install fails.
    private const string WebView2DownloadPageUrl = "https://developer.microsoft.com/microsoft-edge/webview2/";

    private const string InstallFailedText =
        "Couldn't download or install the WebView2 runtime. Check your connection and try again, or install it from Microsoft.";

    private readonly WebView2Runtime _runtime;
    private bool _installing;

    /// <summary>
    /// True once a runtime is available (already installed when the window opened, or installed
    /// during this session). The caller checks this to decide whether to unblock login.
    /// </summary>
    public bool RuntimeReady { get; private set; }

    public RuntimeMissingWindow(WebView2Runtime runtime)
    {
        _runtime = runtime ?? throw new ArgumentNullException(nameof(runtime));
        InitializeComponent();

        // Defensive: if the runtime appeared between the gate check and this window opening
        // (a concurrent install, say), do not make the user click Install for nothing. The close
        // is deferred to Loaded: setting DialogResult before ShowDialog has started throws
        // InvalidOperationException, so it cannot happen in the constructor.
        if (_runtime.IsAvailable())
        {
            RuntimeReady = true;
            Loaded += (_, _) =>
            {
                DialogResult = true;
                Close();
            };
        }
    }

    private async void OnInstallClicked(object sender, RoutedEventArgs e)
    {
        await RunBootstrapAsync();
    }

    private void OnCancelClicked(object sender, RoutedEventArgs e)
    {
        if (_installing)
        {
            // An install is in flight; a re-click of the now-"Not now" cancel is ignored so we do
            // not tear the window down from under the running bootstrapper. The process keeps
            // going; the user can reopen via the tray to see the result.
            return;
        }

        RuntimeReady = _runtime.IsAvailable();
        DialogResult = RuntimeReady;
        Close();
    }

    private async Task RunBootstrapAsync()
    {
        if (_installing)
        {
            return;
        }

        SetInstallingState();

        RuntimeBootstrapResult result;
        try
        {
            result = await _runtime.EnsureRuntimeAsync();
        }
        catch (OperationCanceledException)
        {
            // Treated as a non-terminal stop: leave the window up with a retry.
            SetFailedState("Installation was cancelled.");
            return;
        }
        catch (Exception)
        {
            // EnsureRuntimeAsync already swallows install failures into Failed; this catch is a
            // belt-and-suspenders guard so an unexpected throw never crashes the window.
            SetFailedState(InstallFailedText);
            return;
        }

        switch (result)
        {
            case RuntimeBootstrapResult.AlreadyInstalled:
            case RuntimeBootstrapResult.Installed:
                RuntimeReady = true;
                DialogResult = true;
                Close();
                break;

            case RuntimeBootstrapResult.Failed:
            default:
                SetFailedState(InstallFailedText);
                break;
        }
    }

    private void OnGetFromMicrosoftClicked(object sender, RoutedEventArgs e)
    {
        // Manual fallback: open Microsoft's download page in the default browser. UseShellExecute
        // is what routes a URL to the browser. The window stays up so Retry can re-probe once the
        // user has installed the runtime by hand.
        try
        {
            Process.Start(new ProcessStartInfo(WebView2DownloadPageUrl) { UseShellExecute = true });
        }
        catch (Exception)
        {
            // No browser association or shell error: keep the URL visible in the status line so
            // the user can still get there; never crash the gate window.
            StatusText.Text = $"Couldn't open the browser. Install the runtime from {WebView2DownloadPageUrl} then click Retry.";
            StatusText.Visibility = Visibility.Visible;
        }
    }

    private void SetInstallingState()
    {
        _installing = true;
        InstallButton.IsEnabled = false;
        InstallButton.Content = "Installing...";
        CancelButton.Content = "Not now";
        GetFromMicrosoftButton.Visibility = Visibility.Collapsed;
        StatusText.Text = "Downloading and installing the WebView2 runtime...";
        StatusText.Visibility = Visibility.Visible;
        InstallProgress.Visibility = Visibility.Visible;
    }

    private void SetFailedState(string reason)
    {
        _installing = false;
        InstallProgress.Visibility = Visibility.Collapsed;
        InstallButton.IsEnabled = true;
        // The retry affordance: the primary button now reads Retry so a transient/offline failure
        // is recoverable in place. The Microsoft link appears alongside it as the manual route.
        InstallButton.Content = "Retry";
        GetFromMicrosoftButton.Visibility = Visibility.Visible;
        StatusText.Text = reason;
        StatusText.Visibility = Visibility.Visible;
        StatusText.Foreground = (System.Windows.Media.Brush)FindResource("RuntimeMissingErrorBrush");
    }
}
