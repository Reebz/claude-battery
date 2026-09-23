using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U9: nothing polls while a sign-in is rewriting the shared cookie jar (R22, KTD3).
///
/// The bug this closes: a poll already in flight reads the jar the sign-in is rewriting, gets a 401
/// back because the credentials are half-written or belong to another account, and marks a perfectly
/// healthy account expired - with polling stopped and nothing left to restart it. The account looks
/// signed out to the user, and cancelling the sign-in does not bring it back.
///
/// Cancelling the poll is not enough on its own. The suspend waits for the in-flight poll to finish,
/// and a response that lands after that is discarded the same way one from a superseded account
/// switch is.
/// </summary>
public class PollingSuspendTests
{
    private static UsageApiResponse Response() => new()
    {
        FiveHour = new UsageTier { Utilization = 20 },
        SevenDay = new UsageTier { Utilization = 30 },
    };

    // --- The race ------------------------------------------------------------------------------

    [Fact]
    public async Task AnAuthFailureFromAPollThatASignInOvertook_NeverMarksTheAccountExpired()
    {
        var gate = new TaskCompletionSource<UsageApiResponse>();
        var api = new FakeApi { UsageGate = gate };
        var clock = new TestSchedulerClock();
        var service = new UsageService(api, new AlwaysOnline(), clock);
        service.StartPolling("org-1");

        // A poll is in flight and about to come back with a 401.
        var poll = service.PollUsageAsync(CancellationToken.None);
        var suspend = service.SuspendPollingAsync();
        gate.SetException(new ClaudeAuthException(401));
        await poll;
        await suspend;

        Assert.False(service.AuthFailed);
        Assert.Equal(0, service.ConsecutiveFailures);
    }

    [Fact]
    public async Task ASuccessFromAPollThatASignInOvertook_NeverLands()
    {
        var gate = new TaskCompletionSource<UsageApiResponse>();
        var api = new FakeApi { UsageGate = gate };
        var service = new UsageService(api, new AlwaysOnline(), new TestSchedulerClock());
        service.StartPolling("org-1");

        var poll = service.PollUsageAsync(CancellationToken.None);
        var suspend = service.SuspendPollingAsync();
        gate.SetResult(Response());
        await poll;
        await suspend;

        Assert.Null(service.LatestReading);
    }

    [Fact]
    public async Task SuspendWaitsForTheInFlightPollToFinish()
    {
        var gate = new TaskCompletionSource<UsageApiResponse>();
        var api = new FakeApi { UsageGate = gate };
        var service = new UsageService(api, new AlwaysOnline(), new TestSchedulerClock());
        service.StartPolling("org-1");

        var poll = service.PollUsageAsync(CancellationToken.None);
        var suspend = service.SuspendPollingAsync();

        // Nothing may claim the jar is free while a request is still reading it.
        Assert.False(suspend.IsCompleted);

        gate.SetResult(Response());
        await poll;
        await suspend;
        Assert.True(suspend.IsCompleted);
    }

    [Fact]
    public async Task WhileSuspended_APollDoesNothingAtAll()
    {
        var api = new FakeApi();
        var service = new UsageService(api, new AlwaysOnline(), new TestSchedulerClock());
        service.StartPolling("org-1");

        await service.SuspendPollingAsync();
        await service.PollUsageAsync(CancellationToken.None);

        Assert.Equal(0, api.UsageCalls);
        Assert.Null(service.LatestReading);
    }

    // --- Resume --------------------------------------------------------------------------------

    [Fact]
    public async Task AfterResume_PollingWorksAgain()
    {
        var api = new FakeApi();
        var service = new UsageService(api, new AlwaysOnline(), new TestSchedulerClock());
        service.StartPolling("org-1");

        await service.SuspendPollingAsync();
        service.ResumePolling();
        await service.PollUsageAsync(CancellationToken.None);

        Assert.Equal(1, api.UsageCalls);
        Assert.NotNull(service.LatestReading);
    }

    [Fact]
    public void ResumeWithoutASuspend_DoesNothing()
    {
        var service = new UsageService(new FakeApi(), new AlwaysOnline(), new TestSchedulerClock());
        service.ResumePolling(); // must not throw, and must not start a chain with no account
        Assert.Null(service.LatestReading);
    }

    [Fact]
    public async Task ResumeIsSafeToCallTwice()
    {
        var api = new FakeApi();
        var service = new UsageService(api, new AlwaysOnline(), new TestSchedulerClock());
        service.StartPolling("org-1");

        await service.SuspendPollingAsync();
        service.ResumePolling();
        service.ResumePolling();

        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(1, api.UsageCalls);
    }

    // --- Fakes ---------------------------------------------------------------------------------

    private sealed class FakeApi : IClaudeApi
    {
        public TaskCompletionSource<UsageApiResponse>? UsageGate;
        public int UsageCalls;

        public Task<UsageApiResponse> GetUsageAsync(string organizationId, CancellationToken cancellationToken)
        {
            UsageCalls++;
            return UsageGate?.Task ?? Task.FromResult(Response());
        }

        public Task<Credits?> GetCreditsAsync(string organizationId, CancellationToken cancellationToken)
            => Task.FromResult<Credits?>(null);

        public Task<string?> GetAccountEmailAsync(CancellationToken cancellationToken)
            => Task.FromResult<string?>(null);

        public Task<IReadOnlyList<Organization>> GetOrganizationsAsync(CancellationToken cancellationToken)
            => Task.FromResult<IReadOnlyList<Organization>>(Array.Empty<Organization>());
    }

    private sealed class AlwaysOnline : INetworkAvailability
    {
        public bool IsAvailable => true;
        public event EventHandler? AvailabilityChanged { add { } remove { } }
    }

    /// <summary>A scheduler that stores the callback instead of firing it, so a test drives polls
    /// explicitly and nothing runs behind its back.</summary>
    private sealed class TestSchedulerClock : ISchedulerClock
    {
        public DateTimeOffset Now { get; set; } = new(2026, 9, 14, 12, 0, 0, TimeSpan.Zero);

        public void Arm(TimeSpan delay, Action callback) { }

        public void Disarm() { }
    }
}
