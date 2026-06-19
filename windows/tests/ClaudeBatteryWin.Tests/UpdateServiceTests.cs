using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Tests for <see cref="UpdateService"/> (U12). The real Velopack calls are mocked behind
/// <see cref="IVelopackUpdater"/> and the relaunch teardown behind <see cref="IUpdateTeardown"/>,
/// so nothing touches GitHub, disk, or the process. Covers the plan's three scenarios:
/// a null check leaves the row in "last checked", a non-null exposes version + notes, and the
/// apply teardown releases the mutex so relaunch is single-instance.
/// </summary>
public class UpdateServiceTests
{
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
        var pending = new VelopackUpdateInfo { Version = "1.51.0", ReleaseNotes = "Bug fixes." };
        var (service, _, _) = BuildService(checkResult: pending);

        var result = await service.CheckForUpdatesAsync();

        Assert.NotNull(result);
        Assert.Equal("1.51.0", result!.Version);
        Assert.Equal("Bug fixes.", result.ReleaseNotes);
        // The flyout row binds these off the service.
        Assert.NotNull(service.AvailableUpdate);
        Assert.Equal("1.51.0", service.AvailableUpdate!.Version);
        Assert.Equal("Bug fixes.", service.AvailableUpdate.ReleaseNotes);
        Assert.True(service.HasChecked);
    }

    [Fact]
    public async Task CheckForUpdates_WhenNotInstalled_NoOpsToNull()
    {
        // dotnet-run / non-Velopack host: nothing to check against.
        var pending = new VelopackUpdateInfo { Version = "1.51.0" };
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
        var pending = new VelopackUpdateInfo { Version = "1.51.0", ReleaseNotes = "Notes." };
        var (service, updater, _) = BuildService(checkResult: pending);
        await service.CheckForUpdatesAsync();
        Assert.NotNull(service.AvailableUpdate);

        // A later check throws (GitHub blip). The failure is swallowed and must NOT clobber the
        // previously-found update -- parity with the Mac's debug-logged swallow.
        updater.CheckThrows = new HttpRequestException("network down");
        var result = await service.CheckForUpdatesAsync();

        Assert.Null(result);
        Assert.NotNull(service.AvailableUpdate);
        Assert.Equal("1.51.0", service.AvailableUpdate!.Version);
    }

    [Fact]
    public async Task CheckForUpdates_Cancellation_Propagates()
    {
        var (service, updater, _) = BuildService(checkResult: null);
        updater.CheckThrows = new OperationCanceledException();

        // Cancellation is not swallowed like a transport failure; it propagates.
        await Assert.ThrowsAsync<OperationCanceledException>(() => service.CheckForUpdatesAsync());
    }

    // --- ApplyUpdateAsync: teardown contract / single-instance relaunch -------------------------

    [Fact]
    public async Task ApplyUpdate_ReleasesMutexBeforeRelaunch_SoRelaunchIsSingleInstance()
    {
        var pending = new VelopackUpdateInfo { Version = "1.51.0" };
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
        var pending = new VelopackUpdateInfo { Version = "1.51.0" };
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
        var pending = new VelopackUpdateInfo { Version = "1.51.0" };
        var (service, updater, teardown) = BuildService(checkResult: pending, isInstalled: false);
        // AvailableUpdate never gets set because the check no-ops when not installed, but guard the
        // apply path directly too.
        var applied = await service.ApplyUpdateAsync();

        Assert.False(applied);
        Assert.Equal(0, updater.ApplyCount);
        Assert.True(teardown.MutexHeld);
    }
}
