namespace ClaudeBatteryWin.Views;

/// <summary>
/// A one-slot navigation latch that bridges the gap between an <c>ILoginWebView.Navigate</c> call and
/// the asynchronous arrival of <c>CoreWebView2</c>.
///
/// <para>
/// The login flow issues <c>Navigate("https://claude.ai/login")</c> synchronously, on the UI thread,
/// immediately after the window is created (<c>AuthManager.PresentLogin</c>). But the WebView2 core
/// initializes asynchronously (<c>LoginWindow.InitializeWebView2Async</c>: <c>Task.Yield</c> →
/// <c>CreateAsync</c> → <c>EnsureCoreWebView2Async</c>), and those continuations cannot run until the
/// synchronous <c>PresentLogin</c> body yields the UI thread. So at <c>Navigate</c> time
/// <c>CoreWebView2</c> is deterministically null, and a direct <c>CoreWebView2?.Navigate</c> is a
/// silent no-op. Without this latch the very first navigation is dropped and the window stays blank at
/// <c>about:blank</c> forever - the field bug: a blank "Sign in to Claude" window with zero network
/// activity, no UA/cookie capture, and no error surface (init succeeded, it just never navigated).
/// </para>
///
/// <para>
/// <c>Navigate</c> calls <see cref="Set"/> when the core is not ready; the init success path calls
/// <see cref="TryConsume"/> once the core comes up and replays the URL. The latest write wins (a Retry
/// issued before init supersedes the initial load), and the slot is cleared on consume so a navigation
/// is never replayed twice. Not thread-safe by design: every caller runs on the WPF UI thread.
/// </para>
/// </summary>
internal sealed class PendingNavigation
{
    private string? _url;

    /// <summary>Whether a URL is currently latched awaiting replay.</summary>
    public bool HasPending => _url is not null;

    /// <summary>Latch a URL to replay once the core is ready. The latest call wins.</summary>
    public void Set(string url) => _url = url;

    /// <summary>
    /// Hand back the latched URL exactly once and clear the slot. Returns false (and an empty string)
    /// when nothing is pending, so the caller does not navigate spuriously.
    /// </summary>
    public bool TryConsume(out string url)
    {
        if (_url is { } pending)
        {
            _url = null;
            url = pending;
            return true;
        }

        url = string.Empty;
        return false;
    }
}
