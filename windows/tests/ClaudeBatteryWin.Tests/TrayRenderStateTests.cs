using ClaudeBatteryWin.Icons;
using ClaudeBatteryWin.Models;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Tests for the pure tray-state mapping <see cref="TrayRenderState.Resolve"/> (issue #9). The
/// load-bearing case: a present-but-stale snapshot must render the battery, not "...", so the tray
/// and the open flyout never disagree on a known reading.
/// </summary>
public class TrayRenderStateTests
{
    private static UsageSnapshot Snapshot(double session = 50, double weekly = 50)
        => new() { SessionRemaining = session, WeeklyRemaining = weekly };

    [Fact]
    public void PresentSnapshot_ButStale_RendersBattery_NotStale()
    {
        // The regression: stale + present used to yield StatusStale ("..."), hiding a known value.
        var state = TrayRenderState.Resolve(
            isAuthenticated: true, serviceReady: true, authFailed: false,
            latestUsage: Snapshot(), consecutiveFailures: 4, isStale: true);

        var battery = Assert.IsType<TrayRenderState.Battery>(state);
        Assert.Equal(50, battery.Usage.SessionRemaining);
    }

    [Fact]
    public void PresentSnapshot_Fresh_RendersBattery()
    {
        var state = TrayRenderState.Resolve(
            isAuthenticated: true, serviceReady: true, authFailed: false,
            latestUsage: Snapshot(), consecutiveFailures: 0, isStale: false);

        Assert.IsType<TrayRenderState.Battery>(state);
    }

    [Fact]
    public void NoSnapshot_SustainedStale_RendersStale()
    {
        var state = TrayRenderState.Resolve(
            isAuthenticated: true, serviceReady: true, authFailed: false,
            latestUsage: null, consecutiveFailures: 3, isStale: true);

        Assert.IsType<TrayRenderState.StatusStale>(state);
    }

    [Fact]
    public void NoSnapshot_TenFailures_RendersError_EvenWhenStale()
    {
        // The >=10 error branch sits before the stale branch.
        var state = TrayRenderState.Resolve(
            isAuthenticated: true, serviceReady: true, authFailed: false,
            latestUsage: null, consecutiveFailures: 10, isStale: true);

        Assert.IsType<TrayRenderState.StatusError>(state);
    }

    [Fact]
    public void NoSnapshot_FewFailures_RendersLoading()
    {
        var state = TrayRenderState.Resolve(
            isAuthenticated: true, serviceReady: true, authFailed: false,
            latestUsage: null, consecutiveFailures: 2, isStale: true);

        Assert.IsType<TrayRenderState.StatusLoading>(state);
    }

    [Fact]
    public void AuthFailed_RendersAuthFailed_BeforeBattery()
    {
        // authFailed wins over any (here, already-nulled) snapshot.
        var state = TrayRenderState.Resolve(
            isAuthenticated: true, serviceReady: true, authFailed: true,
            latestUsage: null, consecutiveFailures: 1, isStale: true);

        Assert.IsType<TrayRenderState.AuthFailed>(state);
    }

    [Fact]
    public void NotAuthenticated_RendersUnauthenticated()
    {
        var state = TrayRenderState.Resolve(
            isAuthenticated: false, serviceReady: true, authFailed: false,
            latestUsage: null, consecutiveFailures: 0, isStale: true);

        Assert.IsType<TrayRenderState.Unauthenticated>(state);
    }

    [Fact]
    public void ServiceNotReady_RendersLoading()
    {
        var state = TrayRenderState.Resolve(
            isAuthenticated: true, serviceReady: false, authFailed: false,
            latestUsage: null, consecutiveFailures: 0, isStale: true);

        Assert.IsType<TrayRenderState.StatusLoading>(state);
    }
}
