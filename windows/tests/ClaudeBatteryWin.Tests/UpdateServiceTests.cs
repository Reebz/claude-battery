using System.Net.Http;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Tests for <see cref="UpdateService"/> (U12). The real Velopack calls are mocked behind
/// <see cref="IVelopackUpdater"/> and the relaunch teardown behind <see cref="IUpdateTeardown"/>,
/// so nothing touches GitHub, disk, or the process. Covers the plan's three scenarios:
/// a null check leaves the row in "last checked", a non-null exposes version + notes, and the
/// apply teardown releases the mutex so relaunch is single-instance. Also pins the failure flag
/// (<see cref="UpdateService.LastCheckFailed"/>) and the Settings row text precedence
/// (<see cref="UpdateService.UpdateRowText"/>) so the raw exe never sits on "Checking..." forever.
/// </summary>
public class UpdateServiceTests
{
    /// <summary>
    /// A version the running build would actually accept as an update. Derived from the running
    /// version rather than written out, because the service refuses to announce anything that is not
    /// numerically newer, and a literal here silently stops being newer the next time the app's
    /// version is bumped.
    /// </summary>
    private static readonly string ANewerVersion = NextMajorAfterRunning();

    private static string NextMajorAfterRunning()
    {
        var parts = ClaudeBatteryWin.Services.AppVersionInfo.Version.Split('.');
        var major = int.TryParse(parts[0], out var value) ? value : 1;
        return $"{major + 1}.0.0";
    }

    // --- Fakes ----------------------------------------------------------------------------------

    /// <summary>
    /// Scriptable <see cref="IVelopackUpdater"/>. Records the call order so the apply test can
    /// assert download-then-restart, and lets a check throw to exercise the failure-swallow path.
    /// </summary>
    private sealed class FakeUpdater : IVelopackUpdater
    {
        public bool IsInstalled { get; set; } = true;
        public VelopackUpdateInfo? CheckResult { get; set; }
        public Exception? CheckThrows { get; set; }

        public int CheckCount { get; private set; }
        public int DownloadCount { get; private set; }
        public int ApplyCount { get; private set; }
        public readonly List<string> Calls = new();

        public Task<VelopackUpdateInfo?> CheckForUpdatesAsync(CancellationToken cancellationToken)
        {
            CheckCount++;
            Calls.Add("check");
            if (CheckThrows is not null)
            {
                throw CheckThrows;
            }
            return Task.FromResult(CheckResult);
        }

        public Task DownloadUpdatesAsync(VelopackUpdateInfo update, CancellationToken cancellationToken)
        {
            DownloadCount++;
            Calls.Add("download");
            return Task.CompletedTask;
        }

        public void ApplyUpdatesAndRestart(VelopackUpdateInfo update)
        {
            ApplyCount++;
            Calls.Add("apply");
        }
    }

    /// <summary>
    /// Stand-in for the ordered teardown. Models the single-instance mutex as a bool flag so a
    /// test can assert the relaunch path leaves it released, and records its position in the call
    /// sequence relative to download/apply.
    /// </summary>
    private sealed class FakeTeardown : IUpdateTeardown
    {
        private readonly FakeUpdater _updater;

        /// True while the single-instance mutex is held. Starts held (the primary instance owns it);
        /// <see cref="PrepareForRelaunch"/> must release it before the new instance can acquire it.
        public bool MutexHeld { get; private set; } = true;
        public int TeardownCount { get; private set; }

        public FakeTeardown(FakeUpdater updater)
        {
            _updater = updater;
        }

        public void PrepareForRelaunch()
        {
            TeardownCount++;
            _updater.Calls.Add("teardown");
            // Mirror the real ordering: poller/WebView2 disposal happens here, then the mutex is
            // released LAST so the relaunched instance becomes primary.
            MutexHeld = false;
        }
    }

    private static (UpdateService service, FakeUpdater updater, FakeTeardown teardown) BuildService(
        VelopackUpdateInfo? checkResult = null,
        Exception? checkThrows = null,
        bool isInstalled = true)
    {
        var updater = new FakeUpdater
        {
            IsInstalled = isInstalled,
            CheckResult = checkResult,
            CheckThrows = checkThrows
        };
        var teardown = new FakeTeardown(updater);
        var service = new UpdateService(updater, teardown);
        return (service, updater, teardown);
    }

    // --- CheckForUpdatesAsync: null result -> "last checked" state ------------------------------

    [Fact]
    public async Task CheckForUpdates_NullResult_LeavesRowInLastCheckedState()
    {
        var (service, _, _) = BuildService(checkResult: null);

        var result = await service.CheckForUpdatesAsync();

        Assert.Null(result);
        // "Last checked, up to date": no available update, but a check did complete.
        Assert.Null(service.AvailableUpdate);
        Assert.True(service.HasChecked);
    }

    [Fact]
    public async Task CheckForUpdates_BeforeAnyCheck_HasNotCheckedAndNoUpdate()
    {
        var (service, _, _) = BuildService(checkResult: null);

        // The "never checked" state is distinct from "checked, up to date".
        Assert.False(service.HasChecked);
        Assert.Null(service.AvailableUpdate);

        await service.CheckForUpdatesAsync();
        Assert.True(service.HasChecked);
    }

    // --- CheckForUpdatesAsync: non-null result -> exposes version + notes -----------------------

    [Fact]
    public async Task CheckForUpdates_NonNullResult_ExposesVersionAndNotes()
    {
        var pending = new VelopackUpdateInfo { Version = ANewerVersion, ReleaseNotes = "Bug fixes." };
        var (service, _, _) = BuildService(checkResult: pending);

        var result = await service.CheckForUpdatesAsync();

        Assert.NotNull(result);
        Assert.Equal(ANewerVersion, result!.Version);
        Assert.Equal("Bug fixes.", result.ReleaseNotes);
        // The flyout row binds these off the service.
        Assert.NotNull(service.AvailableUpdate);
        Assert.Equal(ANewerVersion, service.AvailableUpdate!.Version);
        Assert.Equal("Bug fixes.", service.AvailableUpdate.ReleaseNotes);
        Assert.True(service.HasChecked);
    }

    [Fact]
    public async Task CheckForUpdates_WhenNotInstalled_NoOpsToNull()
    {
        // dotnet-run / non-Velopack host: nothing to check against.
        var pending = new VelopackUpdateInfo { Version = ANewerVersion };
        var (service, updater, _) = BuildService(checkResult: pending, isInstalled: false);

        var result = await service.CheckForUpdatesAsync();

        Assert.Null(result);
        Assert.Null(service.AvailableUpdate);
        Assert.False(service.HasChecked);
        Assert.Equal(0, updater.CheckCount);
    }

    [Fact]
    public async Task CheckForUpdates_TransientFailure_DoesNotErasePriorUpdateOrFlipChecked()
    {
        // First check finds an update.
        var pending = new VelopackUpdateInfo { Version = ANewerVersion, ReleaseNotes = "Notes." };
        var (service, updater, _) = BuildService(checkResult: pending);
        await service.CheckForUpdatesAsync();
        Assert.NotNull(service.AvailableUpdate);

        // A later check throws (GitHub blip). The failure is swallowed and must NOT clobber the
        // previously-found update -- parity with the Mac's debug-logged swallow.
        updater.CheckThrows = new HttpRequestException("network down");
        var result = await service.CheckForUpdatesAsync();

        Assert.Null(result);
        Assert.NotNull(service.AvailableUpdate);
        Assert.Equal(ANewerVersion, service.AvailableUpdate!.Version);
    }

    // --- CheckForUpdatesAsync: failure lands on LastCheckFailed, never on "Up to date" -------------

    [Fact]
    public async Task CheckForUpdates_ThrowingCheck_SetsLastCheckFailedWithoutFlippingChecked()
    {
        var (service, _, _) = BuildService(checkThrows: new HttpRequestException("network down"));

        var result = await service.CheckForUpdatesAsync();

        Assert.Null(result);
        Assert.True(service.LastCheckFailed);
        Assert.Null(service.AvailableUpdate);
        // A failed check must not read as "Up to date." - only a completed check sets HasChecked.
        Assert.False(service.HasChecked);
    }

    [Fact]
    public async Task CheckForUpdates_SuccessAfterFailure_ClearsLastCheckFailed()
    {
        var (service, updater, _) = BuildService(checkThrows: new HttpRequestException("network down"));
        await service.CheckForUpdatesAsync();
        Assert.True(service.LastCheckFailed);

        // GitHub comes back; the next check completes and the failure flag clears.
        updater.CheckThrows = null;
        updater.CheckResult = null;
        await service.CheckForUpdatesAsync();

        Assert.False(service.LastCheckFailed);
        Assert.True(service.HasChecked);
        Assert.Null(service.AvailableUpdate);
    }

    [Fact]
    public async Task CheckForUpdates_WhenNotInstalled_DoesNotMarkFailed()
    {
        // The raw exe never runs a check, so it neither completes nor fails; the row's
        // not-installed text is driven off IsUpdaterInstalled instead.
        var (service, _, _) = BuildService(checkResult: null, isInstalled: false);

        await service.CheckForUpdatesAsync();

        Assert.False(service.LastCheckFailed);
        Assert.False(service.HasChecked);
    }

    [Fact]
    public async Task CheckForUpdates_Cancellation_Propagates()
    {
        var (service, updater, _) = BuildService(checkResult: null);
        updater.CheckThrows = new OperationCanceledException();

        // Cancellation is not swallowed like a transport failure; it propagates.
        await Assert.ThrowsAsync<OperationCanceledException>(() => service.CheckForUpdatesAsync());
    }

    // --- UpdateRowText: the Settings About row as a pure function of service state --------------

    [Theory]
    // Still checking: installed, nothing known yet.
    [InlineData(true, null, false, false, "Checking for updates...")]
    // A completed check with nothing newer.
    [InlineData(true, null, true, false, "Up to date.")]
    // A failed check must not claim up-to-date, and must not sit on "Checking...".
    [InlineData(true, null, false, true, "Couldn't check for updates.")]
    // The raw exe: honest about the missing updater instead of "Checking..." forever.
    [InlineData(false, null, false, false, "Auto-update isn't available for this build. Get new versions from GitHub Releases.")]
    // Not-installed wins over a (stale or impossible) checked flag.
    [InlineData(false, null, true, false, "Auto-update isn't available for this build. Get new versions from GitHub Releases.")]
    // Not-installed also wins over a failed flag.
    [InlineData(false, null, false, true, "Auto-update isn't available for this build. Get new versions from GitHub Releases.")]
    // A known update wins over everything else, including not-installed and a later failure.
    [InlineData(true, "1.51.0", true, false, "Update available: v1.51.0")]
    [InlineData(true, "1.51.0", true, true, "Update available: v1.51.0")]
    [InlineData(false, "1.51.0", false, false, "Update available: v1.51.0")]
    public void UpdateRowText_ReflectsStatePrecedence(
        bool isInstalled, string? availableVersion, bool hasChecked, bool lastCheckFailed, string expected)
    {
        Assert.Equal(expected, UpdateService.UpdateRowText(isInstalled, availableVersion, hasChecked, lastCheckFailed));
    }

    // --- ApplyUpdateAsync: teardown contract / single-instance relaunch -------------------------

    [Fact]
    public async Task ApplyUpdate_ReleasesMutexBeforeRelaunch_SoRelaunchIsSingleInstance()
    {
        var pending = new VelopackUpdateInfo { Version = ANewerVersion };
        var (service, updater, teardown) = BuildService(checkResult: pending);
        await service.CheckForUpdatesAsync();

        var applied = await service.ApplyUpdateAsync();

        Assert.True(applied);
        // The teardown ran and released the mutex; a relaunched instance can re-acquire it
        // (createdNew == true) instead of bouncing off its predecessor.
        Assert.Equal(1, teardown.TeardownCount);
        Assert.False(teardown.MutexHeld);
        Assert.Equal(1, updater.ApplyCount);
    }

    [Fact]
    public async Task ApplyUpdate_OrdersDownloadThenTeardownThenRestart()
    {
        var pending = new VelopackUpdateInfo { Version = ANewerVersion };
        var (service, updater, _) = BuildService(checkResult: pending);
        await service.CheckForUpdatesAsync();

        await service.ApplyUpdateAsync();

        // Load-bearing order: download the payload, tear down cleanly (mutex released last inside
        // teardown), then hand off to Velopack's relaunch. The check is first from the earlier call.
        Assert.Equal(new[] { "check", "download", "teardown", "apply" }, updater.Calls.ToArray());
    }

    [Fact]
    public async Task ApplyUpdate_WithNoPendingUpdate_DoesNotTearDownOrRestart()
    {
        var (service, updater, teardown) = BuildService(checkResult: null);
        await service.CheckForUpdatesAsync();

        var applied = await service.ApplyUpdateAsync();

        Assert.False(applied);
        Assert.Equal(0, updater.DownloadCount);
        Assert.Equal(0, updater.ApplyCount);
        Assert.Equal(0, teardown.TeardownCount);
        // The mutex stays held: no relaunch happened, so the running instance keeps ownership.
        Assert.True(teardown.MutexHeld);
    }

    [Fact]
    public async Task ApplyUpdate_WhenNotInstalled_DoesNothing()
    {
        var pending = new VelopackUpdateInfo { Version = ANewerVersion };
        var (service, updater, teardown) = BuildService(checkResult: pending, isInstalled: false);
        // AvailableUpdate never gets set because the check no-ops when not installed, but guard the
        // apply path directly too.
        var applied = await service.ApplyUpdateAsync();

        Assert.False(applied);
        Assert.Equal(0, updater.ApplyCount);
        Assert.True(teardown.MutexHeld);
    }

    // --- U16: the version comparison rule (R47) --------------------------------------------------

    [Theory]
    [InlineData("2.0", "1.45", true)]      // a later major
    [InlineData("1.46", "1.45", true)]     // a later minor
    [InlineData("1.45.1", "1.45", true)]   // a later patch
    [InlineData("1.45", "1.45", false)]    // the same version
    [InlineData("1.45.0", "1.45", false)]  // the bug this rule exists for: a trailing zero is not newer
    [InlineData("1.45", "1.45.0", false)]  // and neither is the same thing the other way round
    [InlineData("1.44", "1.45", false)]    // an earlier version
    [InlineData("2.0", "1.9", true)]       // numbers, not letters: "2.0" beats "1.9"
    [InlineData("1.45.0", "1.45.0", false)]
    [InlineData("v1.51", "1.50.4", true)]  // release names carry a leading v
    [InlineData("1.50.4.0", "1.50.4", false)]
    public void IsNewerVersion_ComparesOneNumberAtATime(string remote, string current, bool expected) =>
        Assert.Equal(expected, UpdateService.IsNewerVersion(remote, current));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("not-a-version")]
    public void AnUnparseableRemoteVersion_IsNeverAnnounced(string? remote) =>
        Assert.False(UpdateService.IsNewerVersion(remote, "1.50.4"));

    [Fact]
    public async Task AReleaseThatIsNotNewerThanTheRunningBuild_IsNotAnnounced()
    {
        var updater = new FakeUpdater
        {
            CheckResult = new VelopackUpdateInfo { Version = ClaudeBatteryWin.Services.AppVersionInfo.Version },
        };
        var service = new UpdateService(updater, new FakeTeardown(updater));

        var result = await service.CheckForUpdatesAsync();

        Assert.Null(result);
        Assert.Null(service.AvailableUpdate);
        Assert.True(service.HasChecked);
        Assert.Equal("Up to date.", UpdateService.UpdateRowText(
            isInstalled: true, service.AvailableUpdate?.Version, service.HasChecked, service.LastCheckFailed));
    }

    [Fact]
    public async Task AfterAFinishedCheckFindsARelease_TheRowNamesIt()
    {
        var updater = new FakeUpdater { CheckResult = new VelopackUpdateInfo { Version = ANewerVersion } };
        var service = new UpdateService(updater, new FakeTeardown(updater));

        await service.CheckForUpdatesAsync();

        Assert.Equal($"Update available: v{ANewerVersion}", UpdateService.UpdateRowText(
            isInstalled: true, service.AvailableUpdate?.Version, service.HasChecked, service.LastCheckFailed));
    }

    [Fact]
    public async Task AfterAFailedCheck_TheRowSaysSoRatherThanStayingOnChecking()
    {
        var updater = new FakeUpdater { CheckThrows = new HttpRequestException("offline") };
        var service = new UpdateService(updater, new FakeTeardown(updater));

        await service.CheckForUpdatesAsync();

        Assert.Equal("Couldn't check for updates.", UpdateService.UpdateRowText(
            isInstalled: true, service.AvailableUpdate?.Version, service.HasChecked, service.LastCheckFailed));
    }

    [Fact]
    public async Task ACheckThatNeverAnswers_ResolvesTheRowInsteadOfSittingOnChecking()
    {
        // The updater hangs; only our own timeout ends it. The row has to say something.
        var updater = new HangingUpdater();
        var service = new UpdateService(
            updater, new FakeTeardown(new FakeUpdater()), checkTimeout: TimeSpan.FromMilliseconds(50));

        var result = await service.CheckForUpdatesAsync();

        Assert.Null(result);
        Assert.True(service.LastCheckFailed);
        Assert.False(service.HasChecked);
        Assert.Equal("Couldn't check for updates.", UpdateService.UpdateRowText(
            isInstalled: true, null, service.HasChecked, service.LastCheckFailed));
    }

    [Fact]
    public void TheCheckIsBoundedAtAMinuteInProduction() =>
        Assert.Equal(TimeSpan.FromMinutes(1), UpdateService.CheckTimeout);

    /// <summary>An updater whose check never returns on its own: only the token ends it.</summary>
    private sealed class HangingUpdater : IVelopackUpdater
    {
        public bool IsInstalled => true;

        public async Task<VelopackUpdateInfo?> CheckForUpdatesAsync(CancellationToken cancellationToken)
        {
            await Task.Delay(Timeout.Infinite, cancellationToken).ConfigureAwait(false);
            return null;
        }

        public Task DownloadUpdatesAsync(VelopackUpdateInfo update, CancellationToken cancellationToken) =>
            Task.CompletedTask;

        public void ApplyUpdatesAndRestart(VelopackUpdateInfo update)
        {
        }
    }

    // --- U16: the daily re-check and the wake hook (R47, KTD15) ----------------------------------

    /// <summary>A one-shot timer the test fires by hand.</summary>
    private sealed class FakeDelayedAction : IDelayedAction
    {
        public TimeSpan? ArmedFor;
        public int Arms;
        public int Cancels;
        private Action? _due;

        public void Arm(TimeSpan delay, Action action)
        {
            ArmedFor = delay;
            _due = action;
            Arms++;
        }

        public void Cancel()
        {
            _due = null;
            Cancels++;
        }

        /// <summary>Let the armed delay elapse.</summary>
        public void Fire()
        {
            var due = _due;
            _due = null;
            due?.Invoke();
        }
    }

    [Fact]
    public void TheScheduler_ChecksAtOnceAndThenEveryTwentyFourHours()
    {
        var checks = 0;
        var timer = new FakeDelayedAction();
        using var schedule = new UpdateRecheckScheduler(() => { checks++; return Task.CompletedTask; }, timer);

        schedule.Start();
        Assert.Equal(1, checks);                                  // not made to wait a day for the first one
        Assert.Equal(TimeSpan.FromHours(24), timer.ArmedFor);

        timer.Fire();
        Assert.Equal(2, checks);
        Assert.Equal(TimeSpan.FromHours(24), timer.ArmedFor);     // and re-armed for the next day

        timer.Fire();
        Assert.Equal(3, checks);
    }

    [Fact]
    public void WakingUp_ChecksAndCountsTheNextDayFromTheWakeMoment()
    {
        var checks = 0;
        var timer = new FakeDelayedAction();
        using var schedule = new UpdateRecheckScheduler(() => { checks++; return Task.CompletedTask; }, timer);

        schedule.Start();
        var armsAfterStart = timer.Arms;

        schedule.HandleResume();

        Assert.Equal(2, checks);
        Assert.Equal(armsAfterStart + 1, timer.Arms);   // re-armed
        Assert.True(timer.Cancels >= 2);                // and the pending one dropped first
        Assert.Equal(TimeSpan.FromHours(24), timer.ArmedFor);
    }

    [Fact]
    public void AfterShutdown_NoFurtherCheckRuns()
    {
        var checks = 0;
        var timer = new FakeDelayedAction();
        var schedule = new UpdateRecheckScheduler(() => { checks++; return Task.CompletedTask; }, timer);

        schedule.Start();
        schedule.Dispose();
        schedule.HandleResume();

        Assert.Equal(1, checks);
    }

    [Fact]
    public void ACheckThatThrowsSynchronously_DoesNotStopTheSchedule()
    {
        var timer = new FakeDelayedAction();
        using var schedule = new UpdateRecheckScheduler(
            () => Task.FromException(new HttpRequestException("offline")), timer);

        var ex = Record.Exception(() => schedule.Start());

        Assert.Null(ex);
        Assert.Equal(TimeSpan.FromHours(24), timer.ArmedFor);
    }
}
