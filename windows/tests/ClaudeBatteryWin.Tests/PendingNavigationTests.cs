using ClaudeBatteryWin.Views;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Regression tests for the login-window navigation latch (<see cref="PendingNavigation"/>). This is
/// the unit-testable core of the field bug where the "Sign in to Claude" window stayed blank at
/// about:blank: AuthManager.PresentLogin navigates synchronously right after the window is created,
/// but the WebView2 core initializes asynchronously, so the first Navigate landed on a null core and
/// was silently dropped. LoginWindow.Navigate now latches the URL here when the core is not ready, and
/// the init success path replays it via <see cref="PendingNavigation.TryConsume"/>.
///
/// The real LoginWindow is a WPF + WebView2 surface that needs an STA UI thread and the runtime, so -
/// exactly like WebView2Runtime backing RuntimeMissingWindow - the load-bearing logic is extracted
/// here and tested directly with no GUI.
/// </summary>
public class PendingNavigationTests
{
    [Fact]
    public void TryConsume_WithNothingLatched_ReturnsFalseAndDoesNotNavigate()
    {
        var nav = new PendingNavigation();

        Assert.False(nav.HasPending);
        Assert.False(nav.TryConsume(out var url));
        Assert.Equal(string.Empty, url);
    }

    [Fact]
    public void SetThenTryConsume_ReplaysTheLatchedUrlOnce()
    {
        // The bug: a navigation requested before the core is ready must not be lost. Set models
        // LoginWindow.Navigate latching the URL; TryConsume models the init success path replaying it.
        var nav = new PendingNavigation();

        nav.Set("https://claude.ai/login");

        Assert.True(nav.HasPending);
        Assert.True(nav.TryConsume(out var url));
        Assert.Equal("https://claude.ai/login", url);
    }

    [Fact]
    public void TryConsume_ClearsTheSlot_SoANavigationIsNeverReplayedTwice()
    {
        // A second init-success replay (or any second consume) must not re-fire a stale navigation.
        var nav = new PendingNavigation();
        nav.Set("https://claude.ai/login");

        Assert.True(nav.TryConsume(out _));

        Assert.False(nav.HasPending);
        Assert.False(nav.TryConsume(out var second));
        Assert.Equal(string.Empty, second);
    }

    [Fact]
    public void Set_LatestWriteWins()
    {
        // A Retry issued while init is still in flight supersedes the initial load: only the most
        // recent latched URL should replay when the core comes up.
        var nav = new PendingNavigation();

        nav.Set("https://claude.ai/login");
        nav.Set("https://claude.ai/login?retry");

        Assert.True(nav.TryConsume(out var url));
        Assert.Equal("https://claude.ai/login?retry", url);
    }
}
