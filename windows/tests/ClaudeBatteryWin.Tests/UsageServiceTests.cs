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

        // Consume the first-post-construction no-network grace (U1) with one tolerated throw so the
        // backoff progression below counts from a clean slate. The construction default of
        // _firstPollAfterResume is true (honoring the field's own comment), so the very first poll
        // after autostart is penalty-free.
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(0, service.ConsecutiveFailures);

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

        // Consume the first-post-construction grace (U1) before asserting escalation.
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(0, service.ConsecutiveFailures);

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

        // Consume the first-post-construction grace (U1) before asserting escalation.
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(0, service.ConsecutiveFailures);

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

    // MARK: - Cloudflare-block 403 soft-handling (U4)

    [Fact]
    public async Task FirstRestoredPoll_CloudflareBlock403_IsPenaltyFree_NoAuthFailed()
    {
        // The first poll after autostart hits a Cloudflare block (stale/absent __cf_bm). It must be
        // penalty-free: no backoff bump, no authFailed, no re-login prompt - the jar self-heals on
        // the next exchange (U3/U5).
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(403, looksLikeCloudflareBlock: true) };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None);

        Assert.Equal(0, service.ConsecutiveFailures); // penalty-free first poll
        Assert.False(service.AuthFailed);             // a CF block never prompts re-login
    }

    [Fact]
    public async Task FirstRestoredPoll_CloudflareBlock403_KeepsPollingArmed()
    {
        // "Polling continues" is the load-bearing property of the soft path: a CF block must NOT call
        // StopPolling. Drive the scheduler (not PollUsageAsync directly) so a stray StopPolling on the
        // CF path - which would null the CTS and leave the poller disarmed - is caught. Mirror of
        // AfterAuthFailed_TimerFireChain_DoesNotReArm with the OPPOSITE expectation.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(403, looksLikeCloudflareBlock: true) };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);   // arms the zero-delay first fire
        Assert.True(clock.IsArmed);

        clock.Fire();                                // OnTimerFired -> first poll -> CF block (grace)
        await service.WaitForRearmAfterFireAsync();  // let the re-arm decision run

        Assert.False(service.AuthFailed);
        Assert.True(clock.IsArmed); // a CF block re-arms the next poll - polling genuinely continues
    }

    [Fact]
    public async Task SecondCloudflareBlock403_BacksOff_ButNeverAuthFailed()
    {
        // After the one-shot grace, a persistent Cloudflare block backs off (network-like) rather
        // than prompting re-auth - it advances the failure count but NEVER sets authFailed.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(403, looksLikeCloudflareBlock: true) };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None); // first: penalty-free grace
        Assert.Equal(0, service.ConsecutiveFailures);

        await service.PollUsageAsync(CancellationToken.None); // second: hard failure (backoff), not auth
        Assert.Equal(1, service.ConsecutiveFailures);
        Assert.False(service.AuthFailed);
    }

    [Fact]
    public async Task FirstRestoredPoll_Genuine401_HardStopsImmediately_DespiteResumeGrace()
    {
        // The resume/autostart grace covers a Cloudflare block ONLY. A genuine 401 hard-stops on the
        // very first poll (the safety residual: a real expired session still surfaces re-auth).
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(401) };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None);

        Assert.True(service.AuthFailed);
    }

    [Fact]
    public async Task FirstRestoredPoll_403WithoutCloudflareTell_HardStops()
    {
        // The key safety test: status 403 ALONE is not grace-eligible. A 403 lacking the Cloudflare
        // tell is a genuine auth 403 and hard-stops even on the first poll.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(403, looksLikeCloudflareBlock: false) };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None);

        Assert.True(service.AuthFailed);
    }

    [Fact]
    public async Task SupersededGeneration_CloudflareBlock403_IsDiscarded_NeverFlagsNewAccount()
    {
        // A CF block whose generation is superseded mid-flight (an account switch to B). The CF path
        // never sets authFailed, and the generation guard on RecordHardFailure discards even the
        // backoff bump, so B is untouched.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var generation = 1;
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock, () => generation);
        service.StartPolling(Org);

        var authFired = false;
        service.AuthFailureDetected += (_, _) => authFired = true;

        // Poll 1: a normal success consumes the first-poll grace so poll 2 reaches RecordHardFailure
        // (where the generation guard lives).
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(0, service.ConsecutiveFailures);

        // Poll 2: the CF block, with a switch to B landing mid-flight.
        api.UsageBehavior = _ =>
        {
            generation = 2; // the switch supersedes this poll's dispatch generation (1)
            throw new ClaudeAuthException(403, looksLikeCloudflareBlock: true);
        };
        await service.PollUsageAsync(CancellationToken.None);

        Assert.False(service.AuthFailed);
        Assert.False(authFired);
        Assert.Equal(0, service.ConsecutiveFailures); // superseded backoff bump discarded
    }

    // MARK: - Fallback-UA escalation on a persistent Cloudflare block (review F1, KTD4 amendment)

    [Fact]
    public async Task FallbackUaTransport_ThirdConsecutiveCfBlock_EscalatesToAuthFailed()
    {
        // A transport running the frozen DefaultUserAgent (no persisted per-account UA - the
        // pre-1.50.2 upgrade population) under a PERSISTENT Cloudflare block: re-login is the cure
        // there (it captures + persists a real UA), so after the third consecutive block the
        // poller must route to the auth-failed surface instead of backing off forever.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(403, looksLikeCloudflareBlock: true) };

        using var service = new UsageService(api, net, clock, transportUaIsFallback: () => true);
        service.StartPolling(Org);
        var authFired = false;
        service.AuthFailureDetected += (_, _) => authFired = true;

        await service.PollUsageAsync(CancellationToken.None); // block 1: the one-shot grace
        Assert.False(service.AuthFailed);
        await service.PollUsageAsync(CancellationToken.None); // block 2: network-like backoff
        Assert.False(service.AuthFailed);
        Assert.Equal(1, service.ConsecutiveFailures);

        await service.PollUsageAsync(CancellationToken.None); // block 3: escalate

        Assert.True(service.AuthFailed);
        Assert.True(authFired);
        Assert.False(clock.IsArmed); // polling stopped, exactly like any auth failure
    }

    [Fact]
    public async Task CapturedUaTransport_PersistentCfBlock_NeverEscalates_Ktd4Holds()
    {
        // The KTD4 core is untouched: a transport running a CAPTURED per-account UA never
        // escalates a CF block to re-auth, no matter how long it persists - re-login cannot fix a
        // genuine edge block when the UA already matches the login session's.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(403, looksLikeCloudflareBlock: true) };

        using var service = new UsageService(api, net, clock, transportUaIsFallback: () => false);
        service.StartPolling(Org);

        for (var i = 0; i < 5; i++)
        {
            await service.PollUsageAsync(CancellationToken.None);
        }

        Assert.False(service.AuthFailed);
        Assert.Equal(4, service.ConsecutiveFailures); // first was graced; the rest backed off
    }

    [Fact]
    public async Task CfBlockStreak_IsResetBySuccess_NoStaleEscalation()
    {
        // The streak counts CONSECUTIVE blocks: any success resets it, so two blocks, a recovery,
        // and two more blocks must not add up to an escalation.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(403, looksLikeCloudflareBlock: true) };

        using var service = new UsageService(api, net, clock, transportUaIsFallback: () => true);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None); // block (streak 1, graced)
        await service.PollUsageAsync(CancellationToken.None); // block (streak 2)

        api.UsageBehavior = null; // default: success
        await service.PollUsageAsync(CancellationToken.None); // success resets the streak
        Assert.Equal(0, service.ConsecutiveFailures);

        api.UsageBehavior = _ => throw new ClaudeAuthException(403, looksLikeCloudflareBlock: true);
        await service.PollUsageAsync(CancellationToken.None); // block (streak 1 again)
        await service.PollUsageAsync(CancellationToken.None); // block (streak 2)

        Assert.False(service.AuthFailed); // never reached 3 consecutive
    }

    [Fact]
    public async Task NoFallbackSignalWired_CfBlocks_NeverEscalate()
    {
        // Escalation is inert when the integration root wires no fallback-UA signal (and in every
        // pre-existing test): the CF soft path is exactly as before.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(403, looksLikeCloudflareBlock: true) };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        for (var i = 0; i < 4; i++)
        {
            await service.PollUsageAsync(CancellationToken.None);
        }

        Assert.False(service.AuthFailed);
    }

    // MARK: - Invariant pins (review testing gaps)

    [Fact]
    public async Task Poll_401WithCloudflareFlag_StillHardStops()
    {
        // LooksLikeCloudflareBlock's cf-mitigated branch is status-independent, so a 401 CAN carry
        // the flag; only the poller's StatusCode == 403 conjunct keeps a flagged 401 a hard stop.
        // This pins that conjunct directly - a refactor weakening either half now fails a test.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new ClaudeAuthException(401, looksLikeCloudflareBlock: true) };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None);

        Assert.True(service.AuthFailed); // hard stop despite the flag and the first-poll grace
    }

    [Fact]
    public async Task CfBlock_SoftPath_PreservesLatestUsage_UnlikeAuthFailure()
    {
        // The CF soft path must keep showing the stale snapshot during a block - only a genuine
        // auth failure nulls LatestUsage. Pins the distinction from MarkAuthFailed.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org);

        await service.PollUsageAsync(CancellationToken.None); // success: snapshot published
        Assert.NotNull(service.LatestUsage);

        api.UsageBehavior = _ => throw new ClaudeAuthException(403, looksLikeCloudflareBlock: true);
        await service.PollUsageAsync(CancellationToken.None); // CF block: soft

        Assert.NotNull(service.LatestUsage); // stale snapshot retained
        Assert.False(service.AuthFailed);
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
    public async Task FirstPollAfterConstruction_ToleratesOnlineThrow_WithoutPenalty()
    {
        // U1 regression guard: the _firstPollAfterResume field initializer must be true at
        // construction (matching its own comment), so the FIRST poll after autostart - with NO
        // HandleResume call - tolerates a transient online throw without advancing backoff. A flip
        // back to a false default would fail this, not just a review. Before the fix the first
        // post-autostart poll lost its documented no-network grace.
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi { UsageBehavior = _ => throw new HttpRequestExceptionLike() };

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org); // autostart path: no HandleResume

        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(0, service.ConsecutiveFailures); // first post-autostart poll is penalty-free
        Assert.False(service.AuthFailed);

        // The grace is one-shot: the second poll on the same online throw does escalate.
        await service.PollUsageAsync(CancellationToken.None);
        Assert.Equal(1, service.ConsecutiveFailures);
    }

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

    // MARK: - Dispose / reconnect (U12 coverage)

    [Fact]
    public void Dispose_DisarmsScheduler_AndAPostDisposeFireIsNoOp()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = true };
        var api = new FakeApi();

        var service = new UsageService(api, net, clock);
        service.StartPolling(Org);
        Assert.True(clock.IsArmed); // the immediate first fire is armed

        service.Dispose();
        Assert.False(clock.IsArmed); // Dispose disarms the scheduler

        // A stray fire after dispose drives nothing (the pending callback was cleared; OnTimerFired
        // also guards on _disposed): no poll runs, no state changes.
        clock.Fire();
        Assert.Equal(0, api.UsageCallCount);
        Assert.Null(service.LatestUsage);
    }

    [Fact]
    public void NetworkReconnect_ReArmsPolling_ForAnImmediatePoll()
    {
        var clock = new FakeClock();
        var net = new FakeNetwork { IsAvailable = false };
        var api = new FakeApi();

        using var service = new UsageService(api, net, clock);
        service.StartPolling(Org); // arms a first fire even while offline

        clock.Disarm(); // simulate that fire having run; nothing is scheduled now
        Assert.False(clock.IsArmed);

        // Coming back online re-arms an immediate poll rather than waiting out a long backoff window.
        net.IsAvailable = true;
        Assert.True(clock.IsArmed);
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
