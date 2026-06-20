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
    /// True only when the host install was actually managed by Velopack (a real installed build).
    /// In a dev (<c>dotnet run</c>) or test context the updater is not installed, so checks no-op.
    /// Mirrors Velopack's own <c>UpdateManager.IsInstalled</c> guard.
    /// </summary>
    public bool IsUpdaterInstalled => _updater.IsInstalled;

    public UpdateService(IVelopackUpdater updater, IUpdateTeardown teardown)
    {
        _updater = updater;
        _teardown = teardown;
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
    /// does not erase a previously-found update.
    /// </summary>
    public async Task<VelopackUpdateInfo?> CheckForUpdatesAsync(CancellationToken cancellationToken = default)
    {
        if (!_updater.IsInstalled)
        {
            // Not a Velopack-managed install (dev/test). Nothing to check against.
            return null;
        }

        try
        {
            var info = await _updater.CheckForUpdatesAsync(cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();

            AvailableUpdate = info;
            HasChecked = true;
            return info;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            // A failed check is a no-op (parity with the Mac's debug-logged swallow). Keep any
            // previously-found update visible; do not mark HasChecked off a failed attempt.
            return null;
        }
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
    /// </summary>
    public async Task<bool> ApplyUpdateAsync(CancellationToken cancellationToken = default)
    {
        if (!_updater.IsInstalled || AvailableUpdate is null)
        {
            return false;
        }

        var update = AvailableUpdate;

        // Background download. Velopack is a no-op if the delta is already present on disk.
        await _updater.DownloadUpdatesAsync(update, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();

        // Clean teardown BEFORE relaunch: stop poller, dispose WebView2 environments, release mutex.
        // After this returns the single-instance mutex is free for the new process to acquire.
        _teardown.PrepareForRelaunch();

        // Hands off to the new version. This call exits the current process; nothing after it runs.
        _updater.ApplyUpdatesAndRestart(update);
        return true;
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

    /// Download the given update's assets into the local package cache.
    Task DownloadUpdatesAsync(VelopackUpdateInfo update, CancellationToken cancellationToken);

    /// Stage the update and relaunch into the new version. Exits the current process.
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
}

/// <summary>
/// Production <see cref="IVelopackUpdater"/> bound to the GitHub Releases source -- the existing
/// <c>gh release</c> pipeline (parity with the Mac <c>UpdateChecker.releasesURL</c> repo). Holds
/// the real <see cref="UpdateManager"/> and the most recent native <c>UpdateInfo</c> so the apply
/// path can pass Velopack's own object back, while the public surface stays on the test-friendly
/// <see cref="VelopackUpdateInfo"/> projection.
///
/// Not exercised by unit tests (it touches GitHub + disk + the process); <see cref="UpdateService"/>
/// is tested against a fake <see cref="IVelopackUpdater"/>.
/// </summary>
public sealed class GitHubVelopackUpdater : IVelopackUpdater
{
    // The repo the Mac UpdateChecker also targets (releases/latest on Reebz/claude-battery).
    private const string GitHubRepoUrl = "https://github.com/Reebz/claude-battery";

    private readonly UpdateManager _manager;

    // Velopack's UpdateInfo is not reconstructable from our projection, so the native object found
    // by the last check is held for the apply path (download + restart take the native type).
    private UpdateInfo? _lastNativeInfo;

    public GitHubVelopackUpdater()
    {
        _manager = new UpdateManager(new GithubSource(GitHubRepoUrl, accessToken: null, prerelease: false));
    }

    public bool IsInstalled => _manager.IsInstalled;

    public async Task<VelopackUpdateInfo?> CheckForUpdatesAsync(CancellationToken cancellationToken)
    {
        var info = await _manager.CheckForUpdatesAsync().ConfigureAwait(false);
        _lastNativeInfo = info;
        if (info is null)
        {
            return null;
        }

        var target = info.TargetFullRelease;
        return new VelopackUpdateInfo
        {
            Version = target.Version.ToString(),
            ReleaseNotes = target.NotesMarkdown ?? target.NotesHTML
        };
    }

    public async Task DownloadUpdatesAsync(VelopackUpdateInfo update, CancellationToken cancellationToken)
    {
        // Use the native object the matching check produced; ignore the projection here.
        if (_lastNativeInfo is null)
        {
            return;
        }

        await _manager.DownloadUpdatesAsync(_lastNativeInfo).ConfigureAwait(false);
    }

    public void ApplyUpdatesAndRestart(VelopackUpdateInfo update)
    {
        if (_lastNativeInfo is null)
        {
            return;
        }

        // Exits the current process and relaunches the new version. The native API takes the
        // VelopackAsset (TargetFullRelease), not the UpdateInfo wrapper.
        _manager.ApplyUpdatesAndRestart(_lastNativeInfo.TargetFullRelease);
    }
}
