using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U8 runtime-gate tests. The window itself (<c>RuntimeMissingWindow</c>) is a WPF surface that
/// needs an STA UI thread, so the load-bearing logic lives in <see cref="WebView2Runtime"/> with
/// the availability check and bootstrapper both injected -- exactly so this gate is unit-testable
/// without a real runtime or installer present. These cover the three plan scenarios:
///   1. runtime reported absent -> login is blocked (IsAvailable false) and a bootstrap is needed,
///   2. a successful bootstrap transitions to the normal login flow (Installed),
///   3. a failed/offline bootstrap surfaces a retry (Failed), not a crash.
/// </summary>
public class WebView2RuntimeTests
{
    /// <summary>A probe whose answer can flip mid-test to model an install succeeding.</summary>
    private sealed class FakeProbe : IWebView2RuntimeProbe
    {
        public string? Version { get; set; }
        public int CallCount { get; private set; }

        public FakeProbe(string? initialVersion) => Version = initialVersion;

        public string? GetAvailableVersion()
        {
            CallCount++;
            return Version;
        }
    }

    /// <summary>
    /// A bootstrapper with scripted behavior: it can report success/failure, throw to model an OS
    /// error, honor cancellation, and flip a probe to "installed" to model a real install landing.
    /// </summary>
    private sealed class FakeBootstrapper : IWebView2Bootstrapper
    {
        private readonly bool _result;
        private readonly Exception? _throw;
        private readonly FakeProbe? _probeToFlip;
        private readonly string? _versionAfterInstall;

        public int InstallCalls { get; private set; }

        public FakeBootstrapper(
            bool result,
            Exception? throwOnInstall = null,
            FakeProbe? probeToFlip = null,
            string? versionAfterInstall = null)
        {
            _result = result;
            _throw = throwOnInstall;
            _probeToFlip = probeToFlip;
            _versionAfterInstall = versionAfterInstall;
        }

        public Task<bool> InstallAsync(CancellationToken cancellationToken)
        {
            InstallCalls++;
            cancellationToken.ThrowIfCancellationRequested();

            if (_throw is not null)
            {
                throw _throw;
            }

            // Model a real install: a successful run makes the runtime visible to the next probe.
            if (_result && _probeToFlip is not null)
            {
                _probeToFlip.Version = _versionAfterInstall ?? "120.0.0.0";
            }

            return Task.FromResult(_result);
        }
    }

    [Fact]
    public void IsAvailable_IsFalse_WhenProbeReportsNoRuntime()
    {
        // Scenario 1: runtime reported absent -> the login gate is closed. The caller checks
        // IsAvailable() before opening a LoginWindow; false here means it shows RuntimeMissingWindow.
        var runtime = new WebView2Runtime(new FakeProbe(initialVersion: null), new FakeBootstrapper(result: false));

        Assert.False(runtime.IsAvailable());
        Assert.Null(runtime.AvailableVersion());
    }

    [Fact]
    public void IsAvailable_IsTrue_WhenProbeReportsAVersion()
    {
        var runtime = new WebView2Runtime(new FakeProbe(initialVersion: "120.0.2210.91"), new FakeBootstrapper(result: false));

        Assert.True(runtime.IsAvailable());
        Assert.Equal("120.0.2210.91", runtime.AvailableVersion());
    }

    [Fact]
    public async Task EnsureRuntime_ReturnsAlreadyInstalled_AndSkipsBootstrap_WhenPresent()
    {
        // A retry after the runtime is already present must not re-run the installer.
        var bootstrapper = new FakeBootstrapper(result: true);
        var runtime = new WebView2Runtime(new FakeProbe(initialVersion: "120.0.0.0"), bootstrapper);

        var result = await runtime.EnsureRuntimeAsync();

        Assert.Equal(RuntimeBootstrapResult.AlreadyInstalled, result);
        Assert.Equal(0, bootstrapper.InstallCalls);
    }

    [Fact]
    public async Task EnsureRuntime_ReturnsInstalled_WhenBootstrapSucceeds()
    {
        // Scenario 2: a successful bootstrap transitions to the normal login flow. The probe starts
        // absent, the bootstrapper flips it to present, and EnsureRuntime confirms by re-probing.
        var probe = new FakeProbe(initialVersion: null);
        var bootstrapper = new FakeBootstrapper(result: true, probeToFlip: probe, versionAfterInstall: "120.0.2210.91");
        var runtime = new WebView2Runtime(probe, bootstrapper);

        var result = await runtime.EnsureRuntimeAsync();

        Assert.Equal(RuntimeBootstrapResult.Installed, result);
        Assert.Equal(1, bootstrapper.InstallCalls);
        Assert.True(runtime.IsAvailable());
    }

    [Fact]
    public async Task EnsureRuntime_ReturnsFailed_WhenBootstrapReportsFailure()
    {
        // Scenario 3a: the installer ran but failed (non-zero exit). Surfaces a retry, not a crash.
        var probe = new FakeProbe(initialVersion: null);
        var bootstrapper = new FakeBootstrapper(result: false);
        var runtime = new WebView2Runtime(probe, bootstrapper);

        var result = await runtime.EnsureRuntimeAsync();

        Assert.Equal(RuntimeBootstrapResult.Failed, result);
        Assert.Equal(1, bootstrapper.InstallCalls);
    }

    [Fact]
    public async Task EnsureRuntime_ReturnsFailed_NotCrash_WhenBootstrapThrows()
    {
        // Scenario 3b: an offline/OS error throws from the bootstrapper. EnsureRuntime must swallow
        // it into Failed (a recoverable retry), never propagate the throw.
        var probe = new FakeProbe(initialVersion: null);
        var bootstrapper = new FakeBootstrapper(result: false, throwOnInstall: new InvalidOperationException("offline"));
        var runtime = new WebView2Runtime(probe, bootstrapper);

        var result = await runtime.EnsureRuntimeAsync();

        Assert.Equal(RuntimeBootstrapResult.Failed, result);
    }

    [Fact]
    public async Task EnsureRuntime_ReturnsFailed_WhenInstallExitsZeroButRuntimeStillAbsent()
    {
        // A zero exit code is necessary but not sufficient: if the runtime is still not visible
        // after the install, treat it as Failed so login is not wrongly unblocked.
        var probe = new FakeProbe(initialVersion: null);
        // result:true but no probe flip -> install "succeeded" yet the runtime never appeared.
        var bootstrapper = new FakeBootstrapper(result: true);
        var runtime = new WebView2Runtime(probe, bootstrapper);

        var result = await runtime.EnsureRuntimeAsync();

        Assert.Equal(RuntimeBootstrapResult.Failed, result);
    }

    [Fact]
    public async Task EnsureRuntime_PropagatesCancellation()
    {
        // A cancelled install is distinct from a failed one: it must surface as cancellation so the
        // window can show a retry rather than silently flipping to a misleading terminal state.
        var probe = new FakeProbe(initialVersion: null);
        var bootstrapper = new FakeBootstrapper(result: true, probeToFlip: probe);
        var runtime = new WebView2Runtime(probe, bootstrapper);

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => runtime.EnsureRuntimeAsync(cts.Token));
    }
}
