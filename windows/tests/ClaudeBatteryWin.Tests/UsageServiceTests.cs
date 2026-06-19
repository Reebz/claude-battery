using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Behavioral tests for U4 <see cref="UsageService"/>: backoff progression and reset, the
/// connectivity gate (offline deferral), soft-vs-hard failure classification, the 401/403
/// auth-failure path, credits degradation, and resume re-poll tolerance. Mirrors the Mac
/// <c>UsageService</c> backoff constants and failure semantics (Services/UsageService.swift).
/// Uses fakes for transport, connectivity, and the scheduler so the cadence is asserted without
/// wall-clock waits, and drives <see cref="UsageService.PollUsageAsync"/> directly.
/// </summary>
public class UsageServiceTests
{
    private const string Org = "org-123";

    // MARK: - Backoff progression

    [Fact]
    public async Task Backoff_Advances_120_300_600_1800_AtDocumentedCounts_ResetsOnSuccess()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        // Online hard failures (the transport throws while the adapter reports up).
        var api = new FakeApi { UsageBehavior = _ => throw new HttpRequestExceptionLike() };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        // 0 failures -> base 120.
        Assert.Equal(120, service.PollIntervalSeconds);

        // Failures 1, 2 stay at 120 (threshold is "< 3").
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(1, service.ConsecutiveFailures);
        Assert.Equal(120, service.PollIntervalSeconds);

        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(2, service.ConsecutiveFailures);
        Assert.Equal(120, service.PollIntervalSeconds);

        // Failure 3 -> 300.
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(3, service.ConsecutiveFailures);
        Assert.Equal(300, service.PollIntervalSeconds);

        // Failures 4, 5 stay at 300; failure 6 -> 600.
        await service.PollUsageAsync(CancellationToken.None);
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(5, service.ConsecutiveFailures);
        Assert.Equal(300, service.PollIntervalSeconds);

        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(6, service.ConsecutiveFailures);
        Assert.Equal(600, service.PollIntervalSeconds);

        // Failures 7..9 stay at 600; failure 10 -> 1800, capped thereafter.
        for (var i = 0; i < 3; i++) await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(9, service.ConsecutiveFailures);
        Assert.Equal(600, service.PollIntervalSeconds);

        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(10, service.ConsecutiveFailures);
        Assert.Equal(1800, service.PollIntervalSeconds);

        // Beyond the cap stays at 1800.
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(11, service.ConsecutiveFailures);
        Assert.Equal(1800, service.PollIntervalSeconds);

        // A success resets the count and interval back to base.
        api.UsageBehavior = null; // default OK response
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(0, service.ConsecutiveFailures);
        Assert.Equal(120, service.PollIntervalSeconds);
        Assert.NotNull(service.LatestUsage);
        Assert.NotNull(service.LastSuccessfulFetch);
    }

    [Fact]
    public async Task OnlineFetchFailure_IsHardFailure_NotAuth()
    {
        // A non-auth fetch failure while online advances backoff (the server answered with an
        // error, or the body was unusable) and must never set authFailed. Mirrors the Mac
        // non-2xx / decode-throws catch arm.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { ThrowResolverFailure = true };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(1, service.ConsecutiveFailures);
        Assert.False(service.AuthFailed);
    }

    // MARK: - Success path

    [Fact]
    public async Task SuccessfulPoll_PublishesSnapshot_ClearsFailuresAndAuthFailed()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None);

        Assert.NotNull(service.LatestUsage);
        Assert.Equal(90, service.LatestUsage!.SessionRemaining);
        Assert.Equal(80, service.LatestUsage.WeeklyRemaining);
        Assert.Equal(0, service.ConsecutiveFailures);
        Assert.False(service.AuthFailed);
        Assert.Equal(clock.Now, service.LastSuccessfulFetch);
    }

    [Fact]
    public async Task IsStale_TrueBeforeFetch_FalseRightAfter_TrueAfter660s()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock);
        Assert.True(service.IsStale); // never fetched

        service.StartPolling(Org);
        await service.PollUsageAsync(CancellationToken.None);
        Assert.False(service.IsStale);

        clock.Advance(TimeSpan.FromSeconds(661));
        Assert.True(service.IsStale);
    }

    // MARK: - Connectivity gate

    [Fact]
    public async Task OfflinePoll_IsDeferred_NotHardFailure_NoBackoffJump_NoAuthFailed_NoCall()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = false };
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        // Several offline polls in a row: none touches the failure count, the interval stays at
        // base, authFailed stays false, and the transport is never even called.
        for (var i = 0; i < 5; i++) await service.PollUsageAsync(CancellationToken.None);

        Assert.Equal(0, service.ConsecutiveFailures);
        Assert.Equal(120, service.PollIntervalSeconds); // never jumps to 1800 on an outage
        Assert.False(service.AuthFailed);
        Assert.Equal(0, api.UsageCallCount);
        Assert.Null(service.LatestUsage);
    }

    [Fact]
    public async Task BriefOutage_ThenSuccess_DoesNotOverEscalate()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = false };
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        // Offline blip: deferred, not failed.
        await service.PollUsageAsync(CancellationToken.None);
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(120, service.PollIntervalSeconds);
        Assert.Equal(0, service.ConsecutiveFailures);

        // Network returns; next poll succeeds normally.
        net.IsAvailable = true;
        await service.PollUsageAsync(CancellationToken.None);
        Assert.NotNull(service.LatestUsage);
        Assert.Equal(0, service.ConsecutiveFailures);
        Assert.Equal(120, service.PollIntervalSeconds);
    }

    [Fact]
    public async Task OnlineTransportThrow_IsHardFailure_ButNeverAuthFailed()
    {
        // The adapter reports up but the request throws: this advances backoff (it is not the
        // offline/just-woke case) and must never set authFailed (only 401/403 does).
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new HttpRequestExceptionLike() };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(1, service.ConsecutiveFailures);
        Assert.False(service.AuthFailed);
    }

    // MARK: - Auth failure (401/403)

    [Fact]
    public async Task AuthFailure_SetsAuthFailed_NullsUsage_StopsPolling()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        // First a success so there is a prior snapshot to null out.
        await service.PollUsageAsync(CancellationToken.None);
        Assert.NotNull(service.LatestUsage);

        var authFired = false;
        service.AuthFailureDetected += (_, _) => authFired = true;

        api.UsageBehavior = _ => throw new ClaudeAuthException(401);
        await service.PollUsageAsync(CancellationToken.None);

        Assert.True(service.AuthFailed);
        Assert.Null(service.LatestUsage);
        Assert.True(authFired);
        // Polling is stopped: the scheduler is disarmed.
        Assert.False(clock.IsArmed);
    }

    [Fact]
    public async Task AuthFailure_On403_SameAs401()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(403) };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);
        await service.PollUsageAsync(CancellationToken.None);

        Assert.True(service.AuthFailed);
        Assert.Null(service.LatestUsage);
    }

    [Fact]
    public async Task AfterAuthFailed_Resume_DoesNotRestartPolling()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(401) };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);
        await service.PollUsageAsync(CancellationToken.None);
        Assert.True(service.AuthFailed);

        clock.Disarm();
        service.HandleResume(); // mirrors Mac handleWake: skips when authFailed
        Assert.False(clock.IsArmed);
    }

    [Fact]
    public async Task AfterAuthFailed_TimerFireChain_DoesNotReArm_PollingGenuinelyStops()
    {
        // The zombie-timer bug (U3): OnTimerFired's ContinueWith re-armed unconditionally, so a
        // 401 -> MarkAuthFailed -> StopPolling was immediately undone by the re-arm. Drive a real
        // timer fire and assert the re-arm is skipped because the generation's token was cancelled.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(401) };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);   // arms the zero-delay first fire
        Assert.True(clock.IsArmed);

        clock.Fire();                                  // OnTimerFired -> poll -> 401 -> StopPolling
        await service.WaitForRearmAfterFireAsync();    // let the re-arm decision run (it must skip)

        Assert.True(service.AuthFailed);
        Assert.False(clock.IsArmed); // the stopped poller was NOT resurrected by the continuation
    }

    [Fact]
    public async Task TimerFireChain_OnSuccess_DoesReArm_ForNextPoll()
    {
        // The guard must not over-fire: a normal successful poll re-arms the next one as before.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        clock.Fire();                               // OnTimerFired -> successful poll
        await service.WaitForRearmAfterFireAsync(); // re-arm runs

        Assert.NotNull(service.LatestUsage);
        Assert.True(clock.IsArmed); // the next poll is scheduled
    }

    // MARK: - Credits degradation

    [Fact]
    public async Task CreditsFetch_ReturnsNull_DegradesToNull_WithoutFailingPoll()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        // GetCreditsAsync returns null (the U3 contract swallows non-2xx/decode internally).
        var api = new FakeApi { CreditsBehavior = _ => null };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);
        await service.PollUsageAsync(CancellationToken.None);

        Assert.NotNull(service.LatestUsage);            // poll still succeeds
        Assert.Null(service.LatestUsage!.Credits);      // credits absent
        Assert.Equal(0, service.ConsecutiveFailures);   // not a failure
    }

    [Fact]
    public async Task CreditsFetch_Throws_DoesNotSinkThePoll()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { CreditsBehavior = _ => throw new HttpRequestExceptionLike() };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);
        await service.PollUsageAsync(CancellationToken.None);

        Assert.NotNull(service.LatestUsage);
        Assert.Equal(0, service.ConsecutiveFailures);
    }

    // MARK: - Switch / cancellation concurrency

    [Fact]
    public async Task SwitchAccount_ClearsPriorState()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);
        await service.PollUsageAsync(CancellationToken.None);
        Assert.NotNull(service.LatestUsage);

        service.SwitchAccount("org-other");
        Assert.Null(service.LatestUsage);
        Assert.Null(service.LastSuccessfulFetch);
        Assert.Equal(0, service.ConsecutiveFailures);
        Assert.False(service.AuthFailed);
    }

    [Fact]
    public async Task SupersededGeneration_LateAuthResponse_IsDiscarded_DoesNotSetAuthFailed()
    {
        // A poll whose token is cancelled mid-flight (the account-switch token bump) must discard
        // its late response - even a 401 - so it can never set authFailed on the new account.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        using var cts = new CancellationTokenSource();
        var api = new FakeApi
        {
            UsageBehavior = _ =>
            {
                cts.Cancel();                       // the switch supersedes this generation
                throw new ClaudeAuthException(401); // the late, now-irrelevant response
            },
        };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        await service.PollUsageAsync(cts.Token);

        Assert.False(service.AuthFailed); // a cancelled generation never mutates state
        Assert.Null(service.LatestUsage);
    }

    // MARK: - Generation guard (U2): a superseded poll never writes onto the new account

    [Fact]
    public async Task SupersededByGenerationBump_SuccessWrite_IsDiscarded_NotWrittenOntoNewAccount()
    {
        // A generation-N poll passes its cancellation check, then a switch to account B bumps the
        // generation mid-flight; the success continuation must NOT publish A's snapshot onto B.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var generation = 5;
        var api = new FakeApi
        {
            UsageBehavior = _ =>
            {
                generation = 6; // the switch to B lands while this poll is in flight
                return new UsageApiResponse
                {
                    Limits = new[]
                    {
                        new UsageLimit { Kind = "session", Percent = 10 },
                        new UsageLimit { Kind = "weekly_all", Percent = 20 },
                    },
                };
            },
        };

        using var service = new UsageService(api, net, clock, () => generation);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None);

        Assert.Null(service.LatestUsage);              // superseded success write discarded
        Assert.Null(service.LastSuccessfulFetch);
        Assert.Equal(0, service.ConsecutiveFailures);
    }

    [Fact]
    public async Task SupersededByGenerationBump_AuthFailure_DoesNotSetAuthFailedOnNewAccount()
    {
        // The token is NOT cancelled here - only the AccountStore generation advanced. A token-only
        // guard would miss this and flag the new account; the generation guard discards the 401.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var generation = 1;
        var api = new FakeApi
        {
            UsageBehavior = _ =>
            {
                generation = 2;                      // switch to B supersedes this poll
                throw new ClaudeAuthException(401);  // the late, now-irrelevant 401 from A
            },
        };

        using var service = new UsageService(api, net, clock, () => generation);
        service.StartPolling(Org);

        var authFired = false;
        service.AuthFailureDetected += (_, _) => authFired = true;

        await service.PollUsageAsync(CancellationToken.None);

        Assert.False(service.AuthFailed); // a superseded generation never flags the new account
        Assert.False(authFired);
    }

    [Fact]
    public async Task SameGeneration_SuccessWrite_StillPublishes()
    {
        // Sanity: with the generation source present but unchanged, the normal success write lands.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var generation = 3;
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock, () => generation);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None);

        Assert.NotNull(service.LatestUsage);
        Assert.Equal(0, service.ConsecutiveFailures);
    }

    // MARK: - Resume tolerance

    [Fact]
    public async Task FirstPollAfterResume_ToleratesOnlineThrow_WithoutPenalty()
    {
        // Right after resume the network may report up but still throw transiently; the first poll
        // tolerates it without advancing backoff.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new HttpRequestExceptionLike() };

        using var service = new UsageService(api, net, clock);
        service.SetOrganization(Org); // prime org without an immediate poll
        service.HandleResume();       // marks the next poll as first-after-resume

        await service.PollUsageAsync(CancellationToken.None);

        Assert.Equal(0, service.ConsecutiveFailures); // first post-resume poll is penalty-free
        Assert.False(service.AuthFailed);

        // The SECOND poll (no longer first-after-resume) does escalate on the same online throw.
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(1, service.ConsecutiveFailures);
    }

    [Fact]
    public async Task FirstPollAfterResume_Offline_IsDeferred_WithoutPenalty()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = false }; // network not up yet post-resume
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock);
        service.SetOrganization(Org);
        service.HandleResume();

        await service.PollUsageAsync(CancellationToken.None);

        Assert.Equal(0, service.ConsecutiveFailures);
        Assert.False(service.AuthFailed);
        Assert.Equal(0, api.UsageCallCount);
    }

    // MARK: - No active account

    [Fact]
    public async Task NoActiveAccount_PollIsSkipped()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock);
        // No org primed.
        await service.PollUsageAsync(CancellationToken.None);

        Assert.Equal(0, api.UsageCallCount);
        Assert.Null(service.LatestUsage);
        Assert.Equal(0, service.ConsecutiveFailures);
    }
}

// MARK: - Test doubles

/// A non-auth, non-cancellation transport throw standing in for an HttpRequestException, so the
/// online-failure path is exercised without referencing System.Net.Http in the test.
internal sealed class HttpRequestExceptionLike : Exception { }

/// Marker the FakeApi throws to model a decode/resolution failure on a returned body.
internal sealed class ResolverFailureSignal : Exception { }

internal sealed class FakeApi : IClaudeApi
{
    public int UsageCallCount { get; private set; }

    /// When set, called instead of returning the default OK response (to throw or customize).
    public Func<string, UsageApiResponse>? UsageBehavior { get; set; }

    /// When set, controls the credits result/throw.
    public Func<string, Credits?>? CreditsBehavior { get; set; }

    /// When true, throws so the service classifies a returned-body resolution failure as hard.
    public bool ThrowResolverFailure { get; set; }

    public Task<UsageApiResponse> GetUsageAsync(string organizationId, CancellationToken cancellationToken)
    {
        UsageCallCount++;
        cancellationToken.ThrowIfCancellationRequested();
        if (ThrowResolverFailure) throw new ResolverFailureSignal();
        if (UsageBehavior is not null) return Task.FromResult(UsageBehavior(organizationId));
        return Task.FromResult(new UsageApiResponse
        {
            Limits = new[]
            {
                new UsageLimit { Kind = "session", Percent = 10 },
                new UsageLimit { Kind = "weekly_all", Percent = 20 },
            },
        });
    }

    public Task<Credits?> GetCreditsAsync(string organizationId, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (CreditsBehavior is not null) return Task.FromResult(CreditsBehavior(organizationId));
        return Task.FromResult<Credits?>(null);
    }

    public Task<IReadOnlyList<Organization>> GetOrganizationsAsync(CancellationToken cancellationToken)
        => Task.FromResult<IReadOnlyList<Organization>>(Array.Empty<Organization>());
}

internal sealed class FakeNetwork : INetworkAvailability
{
    private bool _isAvailable;

    public bool IsAvailable
    {
        get => _isAvailable;
        set
        {
            var changed = _isAvailable != value;
            _isAvailable = value;
            if (changed) AvailabilityChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public event EventHandler? AvailabilityChanged;
}

internal sealed class FakeClock : ISchedulerClock
{
    private DateTimeOffset _now = new(2026, 6, 19, 12, 0, 0, TimeSpan.Zero);
    private Action? _pending;

    public DateTimeOffset Now => _now;
    public bool IsArmed => _pending is not null;

    public void Advance(TimeSpan by) => _now = _now.Add(by);

    public void Arm(TimeSpan delay, Action onFire) => _pending = onFire;

    public void Disarm() => _pending = null;

    /// Invoke the pending scheduler callback (drives <c>OnTimerFired</c>) exactly as the real timer
    /// would, so the timer-fire -> re-arm chain can be exercised deterministically.
    public void Fire() => _pending?.Invoke();
}
