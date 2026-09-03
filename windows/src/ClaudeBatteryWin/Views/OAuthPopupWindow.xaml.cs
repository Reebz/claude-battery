using System.Windows;

namespace ClaudeBatteryWin.Views;

/// <summary>
/// A plain WPF window whose only content is the <c>WebView</c> control that hosts an OAuth popup
/// (the <c>window.open()</c> from "Continue with Google" / Apple on the login page).
///
/// It exists because a WebView2 control outside a visual tree never finishes initialising: the WPF
/// control is an <c>HwndHost</c>, and its <c>EnsureCoreWebView2Async</c> waits for the host HWND
/// that is only created once the control sits in a shown window. <see cref="LoginWindow"/> creates
/// this window, shows it, initialises <c>WebView</c> on the login view's environment and InPrivate
/// profile, and only then assigns it as the <c>NewWindow</c>. Everything else - the navigation gate,
/// the close-on-<c>window.close()</c>, and the teardown - is owned by <see cref="LoginWindow"/>.
///
/// <see cref="Dispose"/> is close-safe: it disposes the WebView2 control first (releasing the
/// CoreWebView2 and its share of the profile), then closes the window if it is still open. Calling
/// it from the window's own <c>Closed</c> handler is fine - the second call is a no-op.
/// </summary>
public partial class OAuthPopupWindow : Window, IDisposable
{
    private bool _disposed;
    private bool _closed;

    public OAuthPopupWindow()
    {
        InitializeComponent();
    }

    protected override void OnClosed(EventArgs e)
    {
        _closed = true;
        base.OnClosed(e);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        try
        {
            WebView.Dispose();
        }
        catch (Exception)
        {
            // A control whose core already died (popup closed by the page, teardown mid-init) must
            // not abort the window close below.
        }

        if (_closed)
        {
            return;
        }

        try
        {
            Close();
        }
        catch (Exception)
        {
            // Closing during the owner's own shutdown can throw; the window is going away regardless.
        }
    }
}
