using System.Windows;
using ClaudeBatteryWin.Services;

namespace ClaudeBatteryWin.Views;

/// <summary>
/// The separate runtime-bootstrap window (U8). Shown in place of the login window whenever the
/// WebView2 runtime is absent, it drives <see cref="WebView2Runtime.EnsureRuntimeAsync"/> and
/// blocks login until the install succeeds. A failed or offline install turns the primary button
/// into a Retry and shows the reason -- never a blank window or a crash.
///
/// The caller opens this with <see cref="ShowDialog"/> and, after it closes, reads
/// <see cref="RuntimeReady"/>: true means the runtime is now present and login may proceed; false
/// means the user dismissed without installing and login stays blocked (the tray click routes back
/// here next time).
/// </summary>
public partial class RuntimeMissingWindow : Window
{
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
        // (a concurrent install, say), do not make the user click Install for nothing.
        if (_runtime.IsAvailable())
        {
            RuntimeReady = true;
            DialogResult = true;
            Close();
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
            SetFailedState("Couldn't install the runtime. Check your connection and try again.");
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
                SetFailedState("Couldn't install the runtime. Check your connection and try again.");
                break;
        }
    }

    private void SetInstallingState()
    {
        _installing = true;
        InstallButton.IsEnabled = false;
        InstallButton.Content = "Installing...";
        CancelButton.Content = "Not now";
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
        // is recoverable in place.
        InstallButton.Content = "Retry";
        StatusText.Text = reason;
        StatusText.Visibility = Visibility.Visible;
        StatusText.Foreground = (System.Windows.Media.Brush)FindResource("RuntimeMissingErrorBrush");
    }
}
