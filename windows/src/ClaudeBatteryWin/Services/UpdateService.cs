using Velopack;
using Velopack.Sources;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// In-app auto-update (U12, R21). Wraps Velopack's <see cref="UpdateManager"/> against a GitHub
/// Releases source -- the same <c>gh release</c> pipeline the Mac side ships through -- and exposes
/// the available version + release notes for the flyout's version/update row.
///
/// This is the Windows analog of the Mac <c>UpdateChecker</c> (Services/UpdateChecker.swift). The
/// Mac polls <c>releases/latest</c> on a 24h timer and surfaces a download link; Velopack does the
/// version comparison and delta download for us, so this service only orchestrates check -> download
/// -> prompt -> apply, and the flyout owns the timer/cadence.
///
/// IMPORTANT (integration): <c>VelopackApp.Build().Run()</c> MUST be the FIRST line of application
/// startup -- before the tray icon, before any window, before this service is constructed. Velopack
/// runs install/uninstall/update hooks synchronously at that point and exits the process for hook
/// invocations. App.xaml.cs runs it as the first line of OnStartup, before the tray icon and any
/// window. If it is not first, a freshly applied update can re-run the old binary's UI on the hook launch.
///
/// The real Velopack calls live behind <see cref="IVelopackUpdater"/> so this service is unit-testable
/// without the updater touching disk, GitHub, or the running process.
/// </summary>
public sealed class UpdateService
{
    private readonly IVelopackUpdater _updater;
    private readonly IUpdateTeardown _teardown;

    /// <summary>
    /// The update Velopack found on the last successful check, or null if none / not yet checked.
    /// The flyout binds the version + notes off this. Downloaded lazily by <see cref="ApplyUpdateAsync"/>.
    /// </summary>
    public VelopackUpdateInfo? AvailableUpdate { get; private set; }

    /// <summary>
    /// True once a check has completed (success or "no update"), so the flyout can render a
    /// "last checked" state distinct from "never checked". A null <see cref="AvailableUpdate"/>
    /// with this true means up-to-date; a null with this false means no check has run yet.
    /// </summary>
    public bool HasChecked { get; private set; }

    /// <summary>
    /// True when the most recent check threw (GitHub unreachable, no Velopack assets on the latest
    /// release, ...). Cleared by the next successful check. Lets the Settings row land on
    /// "Couldn't check for updates." instead of sitting on "Checking for updates..." forever;
    /// <see cref="HasChecked"/> deliberately stays false on failure so a failed check is never
    /// reported as "Up to date.".
    /// </summary>
    public bool LastCheckFailed { get; private set; }

    /// <summary>
    /// True only when the host install was actually managed by Velopack (a real installed build).
    /// In a dev (<c>dotnet run</c>) or test context the updater is not installed, so checks no-op.
    /// Mirrors Velopack's own <c>UpdateManager.IsInstalled</c> guard.
    /// </summary>
    public bool IsUpdaterInstalled => _updater.IsInstalled;

    /// <summary>How long a single check may take before it counts as failed (R47).</summary>
    public static readonly TimeSpan CheckTimeout = TimeSpan.FromMinutes(1);

    private readonly TimeSpan _checkTimeout;

    // 1 while an ApplyUpdateAsync is between its checks and the hand-off.
    private int _applying;

    /// <param name="checkTimeout">How long one check may run. Only the tests pass this; production
    /// takes <see cref="CheckTimeout"/>.</param>
    public UpdateService(IVelopackUpdater updater, IUpdateTeardown teardown, TimeSpan? checkTimeout = null)
    {
        _updater = updater;
        _teardown = teardown;
        _checkTimeout = checkTimeout ?? CheckTimeout;
    }

    /// <summary>
    /// Check the GitHub Releases source for a newer version. On a null result the update row stays
    /// in its "last checked, up to date" state (<see cref="AvailableUpdate"/> is cleared,
    /// <see cref="HasChecked"/> is set). A non-null result populates <see cref="AvailableUpdate"/>
    /// with the available version + notes for the flyout to surface.
    ///
    /// Swallows transport/source failures the way the Mac update check does (a failed check is a
    /// no-op, not an error surfaced to the user); leaves the prior <see cref="AvailableUpdate"/>
    /// untouched on failure and does not flip <see cref="HasChecked"/>, so a transient GitHub blip
    /// does not erase a previously-found update. A failure does set <see cref="LastCheckFailed"/>
    /// so the UI can say so.
    /// </summary>
    public async Task<VelopackUpdateInfo?> CheckForUpdatesAsync(CancellationToken cancellationToken = default)
    {
        if (!_updater.IsInstalled)
        {
            // Not a Velopack-managed install (dev/test). Nothing to check against.
            return null;
        }

        // A check that never answers would leave the About row reading "Checking for updates..."
        // for the life of the process (R47). Bound it, and treat running out of time as a failed
        // check, which the row already has words for.
        using var timeout = new CancellationTokenSource(_checkTimeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);

        try
        {
            // WaitAsync, not just the token: Velopack's own check takes no token, so an updater
            // that cannot observe it would otherwise hold this await past the timeout forever and
            // the timeout branch below could never run (R47).
            var info = await _updater.CheckForUpdatesAsync(linked.Token)
                .WaitAsync(linked.Token).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();

            // Guard the announcement with our own component-wise comparison (R47): a release named
            // "1.50.4.0" or "v1.50.4" is the version already running, and announcing it would leave
            // the user with an update button that reinstalls what they have.
            if (info is not null && !IsNewerVersion(info.Version, AppVersionInfo.Version))
            {
                info = null;
            }

            AvailableUpdate = info;
            HasChecked = true;
            LastCheckFailed = false;
            return info;
        }
        catch (OperationCanceledException)
            when (timeout.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            // Our own timeout, not the caller's and not one the updater raised itself: a slow check
            // reads as a failed one.
            LastCheckFailed = true;
            return null;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            // A failed check is a no-op (parity with the Mac's debug-logged swallow). Keep any
            // previously-found update visible; do not mark HasChecked off a failed attempt. Only
            // record that the attempt failed so the update row can stop saying "Checking...".
            LastCheckFailed = true;
            return null;
        }
    }

    /// <summary>
    /// Whether <paramref name="remote"/> is a later version than <paramref name="current"/>
    /// (R47), ported from the Mac <c>isNewerVersion</c>.
    ///
    /// Numbers compared one component at a time, never as strings: "2.0" is later than "1.9", and
    /// "1.45.0" is the same version as "1.45", not a later one. The missing components are zeroes,
    /// which is the whole point of the rule: the Mac shipped a false "update available" because the
    /// release was named with one more component than the running build. Anything that is not a
    /// number is dropped, and a leading "v" is ignored, because release names carry both.
    /// </summary>
    public static bool IsNewerVersion(string? remote, string? current)
    {
        var left = Components(remote);
        var right = Components(current);
        if (left.Count == 0)
        {
            return false; // nothing parseable: never announce
        }

        var length = Math.Max(left.Count, right.Count);
        for (var i = 0; i < length; i++)
        {
            var a = i < left.Count ? left[i] : 0;
            var b = i < right.Count ? right[i] : 0;
            if (a != b)
            {
                return a > b;
            }
        }

        return false; // equal versions are never newer
    }

    private static List<int> Components(string? version)
    {
        var parts = new List<int>();
        if (string.IsNullOrWhiteSpace(version))
        {
            return parts;
        }

        var text = version.Trim();
        if (text.StartsWith("v", StringComparison.OrdinalIgnoreCase))
        {
            text = text[1..];
        }

        foreach (var piece in text.Split('.'))
        {
            if (int.TryParse(piece, System.Globalization.NumberStyles.None,
                    System.Globalization.CultureInfo.InvariantCulture, out var value))
            {
                parts.Add(value);
            }
        }

        return parts;
    }

    /// <summary>
    /// The status line for the Settings update row, as a pure function of the service state so it
    /// is unit-testable without a window. Precedence: a known update always wins; then a build the
    /// updater cannot manage (the raw single-file exe testers run, where a check never runs and so
    /// never "completes"); then a completed check; then a failed check; else still checking.
    /// </summary>
    public static string UpdateRowText(bool isInstalled, string? availableVersion, bool hasChecked, bool lastCheckFailed)
    {
        if (availableVersion is not null)
        {
            return $"Update available: v{availableVersion}";
        }

        if (!isInstalled)
        {
            return "Auto-update isn't available for this build. Get new versions from GitHub Releases.";
        }

        if (hasChecked)
        {
            return "Up to date.";
        }

        if (lastCheckFailed)
        {
            return "Couldn't check for updates.";
        }

        return "Checking for updates...";
    }

    /// <summary>
    /// Download the pending update (if not already downloaded), then perform the clean teardown
    /// contract and relaunch into the new version. Returns false (without relaunching) when there
    /// is no pending update or the updater is not installed, so a caller can fall back to "open the
    /// release page" the way the Mac row does.
    ///
    /// Teardown ordering is load-bearing (U12 + U1 mutex interaction): stop the poller and dispose
    /// the WebView2 environments first (so no background poll or login session is mid-flight), then
    /// release the single-instance mutex LAST, immediately before <c>ApplyUpdatesAndRestart</c>.
    /// The relaunched instance re-acquires the mutex in App.OnStartup; if the mutex were still held
    /// here, the new instance would see <c>createdNew == false</c>, signal the (dying) old instance,
    /// and exit -- the double-instance bounce. <see cref="IUpdateTeardown.PrepareForRelaunch"/> owns
    /// that exact sequence so it is testable in isolation.
    ///
    /// The teardown is one-way: after it the tray icon is gone, polling is stopped and the lock is
    /// free. So the preconditions the updater can report (a pending update, <c>CanApply</c>) are
    /// checked BEFORE it, and throw there (the callers already turn a throw into the "Update failed"
    /// row) while the app is still whole. Failures only the hand-off itself can reveal (a missing
    /// Update.exe, a refused process start) still happen after the teardown, which is why the next
    /// step exists. If
    /// the hand-off itself fails after the teardown, the process is ended through
    /// <see cref="IUpdateTeardown.ExitAfterFailedRelaunch"/> rather than left running with no icon,
    /// no window and no lock, where the next launch would become a second instance.
    /// </summary>
    public async Task<bool> ApplyUpdateAsync(CancellationToken cancellationToken = default)
    {
        if (!_updater.IsInstalled || AvailableUpdate is null)
        {
            return false;
        }

        // One apply at a time: a second click on the flyout link while the first is downloading
        // must not run the teardown and the hand-off twice.
        if (Interlocked.Exchange(ref _applying, 1) == 1)
        {
            return false;
        }

        try
        {
            // Captured once. A re-check that lands mid-apply may replace or clear AvailableUpdate,
            // but this snapshot carries its own Velopack object, so it stays applicable.
            var update = AvailableUpdate;

            if (!_updater.CanApply(update))
            {
                // Nothing torn down yet: the app keeps running and the row says the update failed.
                throw new InvalidOperationException("The pending update can no longer be applied.");
            }

            // Background download. Velopack is a no-op if the delta is already present on disk.
            await _updater.DownloadUpdatesAsync(update, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();

            // Clean teardown BEFORE relaunch: stop poller, dispose WebView2 environments, release mutex.
            // After this returns the single-instance mutex is free for the new process to acquire.
            _teardown.PrepareForRelaunch();

            try
            {
                // Hands off to the new version. On success this exits the current process and
                // nothing after it runs.
                _updater.ApplyUpdatesAndRestart(update);
            }
            catch (Exception ex)
            {
                // Past the point of no return: the icon and the lock are already gone. End the
                // process cleanly so the user can simply launch it again.
                _teardown.ExitAfterFailedRelaunch(ex);
                return false;
            }

            return true;
        }
        finally
        {
            Volatile.Write(ref _applying, 0);
        }
    }
}

/// <summary>
/// The clean-teardown contract the update apply runs immediately before relaunch (U12). Kept as an
/// interface so <see cref="UpdateService.ApplyUpdateAsync"/> can assert the sequence runs without a
/// real poller / WebView2 / mutex. App.xaml.cs supplies the concrete implementation
/// (<c>AppUpdateTeardown</c>) that, in order: stops <c>UsageService</c> polling, disposes every live
/// WebView2 <c>CoreWebView2Environment</c> (login + popup), then releases the single-instance
/// lock from App.xaml.cs LAST so the relaunched instance can re-acquire it.
/// </summary>
public interface IUpdateTeardown
{
    /// <summary>
    /// Run the ordered teardown: stop poller -> dispose WebView2 environments -> release mutex.
    /// Must leave the single-instance mutex released so the relaunched process becomes the primary.
    /// </summary>
    void PrepareForRelaunch();

    /// <summary>
    /// The hand-off failed after <see cref="PrepareForRelaunch"/> already ran. Record why, then end
    /// the process through the app's normal shutdown so no icon-less, lock-less copy keeps running
    /// and the user can relaunch.
    /// </summary>
    void ExitAfterFailedRelaunch(Exception error);
}

/// <summary>
/// Thin seam over Velopack's <see cref="UpdateManager"/> so the updater can be mocked in tests.
/// The production implementation (<see cref="GitHubVelopackUpdater"/>) forwards each call to a real
/// <see cref="UpdateManager"/> bound to the GitHub Releases source. Tests substitute a fake.
/// </summary>
public interface IVelopackUpdater
{
    /// True when the host process is a Velopack-managed install (the real <c>UpdateManager.IsInstalled</c>).
    bool IsInstalled { get; }

    /// Check the source for a newer release; null means up to date.
    Task<VelopackUpdateInfo?> CheckForUpdatesAsync(CancellationToken cancellationToken);

    /// True when <paramref name="update"/> still carries what the updater needs to download and
    /// apply it. Asked before the teardown, so a refusal leaves the app running.
    bool CanApply(VelopackUpdateInfo update);

    /// Download the given update's assets into the local package cache.
    Task DownloadUpdatesAsync(VelopackUpdateInfo update, CancellationToken cancellationToken);

    /// Stage the update and relaunch into the new version. Exits the current process on success
    /// and throws on failure; it never returns without having handed off.
    void ApplyUpdatesAndRestart(VelopackUpdateInfo update);
}

/// <summary>
/// Transport-agnostic view of a pending update for the flyout row (available version + notes),
/// decoupling the UI/test surface from Velopack's <c>UpdateInfo</c> concrete type. The production
/// updater maps Velopack's <c>UpdateInfo.TargetFullRelease</c> (version, notes) onto this.
/// </summary>
public sealed record VelopackUpdateInfo
{
    /// The semantic version of the update (e.g. "1.51.0"), for the "Update to vX" label.
    public required string Version { get; init; }

    /// Release notes (markdown/text) for the available release, shown in the update row.
    public string? ReleaseNotes { get; init; }

    /// The updater's own object for this release (Velopack's <c>UpdateInfo</c> in production).
    /// Carried on the projection rather than kept as "the last check's result" inside the updater,
    /// so a re-check that finds nothing cannot pull it out from under an apply already under way.
    internal object? Native { get; init; }
}

/// <summary>
/// Production <see cref="IVelopackUpdater"/> bound to the GitHub Releases source -- the existing
/// <c>gh release</c> pipeline (parity with the Mac <c>UpdateChecker.releasesURL</c> repo). Holds
/// the real <see cref="UpdateManager"/>; each check's native <c>UpdateInfo</c> rides on the
/// <see cref="VelopackUpdateInfo"/> it returns (<see cref="VelopackUpdateInfo.Native"/>) so the
/// apply path can pass Velopack's own object back, while the public surface stays on the
/// test-friendly projection.
///
/// The manager calls are not exercised by unit tests (they touch GitHub + disk + the process);
/// <see cref="UpdateService"/> is tested against a fake <see cref="IVelopackUpdater"/>. The check
/// that an update still carries its Velopack object (<see cref="CarriesNativeRelease"/>,
/// <see cref="NativeOf"/>) is tested directly, since that is where D1 lived (review F7).
/// </summary>
public sealed class GitHubVelopackUpdater : IVelopackUpdater
{
    // The repo the Mac UpdateChecker also targets (releases/latest on Reebz/claude-battery).
    private const string GitHubRepoUrl = "https://github.com/Reebz/claude-battery";

    private readonly UpdateManager _manager;

    public GitHubVelopackUpdater()
    {
        // prerelease: true because every Windows build ships as a GitHub pre-release
        // (windows-test-*); with false, Velopack drops all of them and a Velopack install would
        // report "Up to date." forever. The Mac releases in the same repo do not shadow the Windows
        // feed: GithubSource reads the 10 newest releases and skips any without this channel's
        // releases.<channel>.json asset, which the Mac DMG releases never carry.
        _manager = new UpdateManager(new GithubSource(GitHubRepoUrl, accessToken: null, prerelease: true));
    }

    public bool IsInstalled => _manager.IsInstalled;

    public async Task<VelopackUpdateInfo?> CheckForUpdatesAsync(CancellationToken cancellationToken)
    {
        // Velopack's check takes no token, so WaitAsync is the only way the caller's timeout can
        // end the wait (R47). The abandoned check keeps running; observe its fault so a late
        // failure is not reported as an unobserved task exception.
        var check = _manager.CheckForUpdatesAsync();
        _ = check.ContinueWith(
            t => _ = t.Exception,
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);

        var info = await check.WaitAsync(cancellationToken).ConfigureAwait(false);
        if (info is null)
        {
            return null;
        }

        var target = info.TargetFullRelease;
        return new VelopackUpdateInfo
        {
            Version = target.Version.ToString(),
            ReleaseNotes = target.NotesMarkdown ?? target.NotesHTML,
            Native = info
        };
    }

    public bool CanApply(VelopackUpdateInfo update) => CarriesNativeRelease(update);

    public async Task DownloadUpdatesAsync(VelopackUpdateInfo update, CancellationToken cancellationToken)
    {
        await _manager.DownloadUpdatesAsync(NativeOf(update)).ConfigureAwait(false);
    }

    public void ApplyUpdatesAndRestart(VelopackUpdateInfo update)
    {
        // Exits the current process and relaunches the new version (Velopack launches Update.exe,
        // then calls Environment.Exit(0)); a failure to launch the updater throws out of here. The
        // native API takes the VelopackAsset (TargetFullRelease), not the UpdateInfo wrapper.
        _manager.ApplyUpdatesAndRestart(NativeOf(update).TargetFullRelease);

        // Unreachable with Velopack as shipped. If a future version ever returns instead of
        // exiting, turn that into the failure UpdateService already handles rather than a silent
        // return after the teardown.
        throw new InvalidOperationException("Velopack returned from ApplyUpdatesAndRestart without exiting.");
    }

    /// <summary>True when <paramref name="update"/> carries the Velopack object its check produced.
    /// Read only from the update itself, never from updater state a later check could replace.</summary>
    internal static bool CarriesNativeRelease(VelopackUpdateInfo update) => update.Native is UpdateInfo;

    /// <summary>The Velopack object carried on <paramref name="update"/>. Throws when it is missing,
    /// so the apply fails loudly instead of returning silently after the teardown (D1).</summary>
    internal static UpdateInfo NativeOf(VelopackUpdateInfo update) =>
        update.Native as UpdateInfo
        ?? throw new InvalidOperationException("The update has no Velopack release attached.");
}
