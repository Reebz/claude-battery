using System.IO;
using System.Net.Http;
using System.Security.Cryptography.X509Certificates;
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

    // ---- EvergreenBootstrapper: the production runner's locate -> verify -> download -> verify ->
    // run -> exit-code contract, exercised through its seams so no network, stub, signature, or
    // installer is touched.

    private const string BundledPath = @"C:\Users\tester\Downloads\MicrosoftEdgeWebView2Setup.exe";
    private const string DownloadedPath = @"C:\Temp\ClaudeBattery-WebView2-0123\MicrosoftEdgeWebView2Setup.exe";

    /// <summary>Records the path the runner was handed and returns a scripted exit code.</summary>
    private sealed class RecordingRunner
    {
        private readonly int _exitCode;

        public List<string> Paths { get; } = new();

        public RecordingRunner(int exitCode) => _exitCode = exitCode;

        public Task<int> RunAsync(string path, CancellationToken cancellationToken)
        {
            Paths.Add(path);
            return Task.FromResult(_exitCode);
        }
    }

    /// <summary>Counts download calls and returns a scripted path.</summary>
    private sealed class RecordingDownload
    {
        private readonly string? _path;

        public int Calls { get; private set; }

        public RecordingDownload(string? path) => _path = path;

        public Task<string?> DownloadAsync(CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult(_path);
        }
    }

    /// <summary>
    /// Signature check fake (E1): only the listed paths count as Microsoft-signed. Records every
    /// path it was asked about so a test can prove a file was checked before it ran.
    /// </summary>
    private sealed class FakeVerifier : IBootstrapperSignatureVerifier
    {
        private readonly HashSet<string> _trusted;
        private readonly bool _throw;

        public List<string> Checked { get; } = new();

        public FakeVerifier(string[]? trusted = null, bool throwOnCheck = false)
        {
            _trusted = new HashSet<string>(trusted ?? Array.Empty<string>());
            _throw = throwOnCheck;
        }

        public bool IsSignedByMicrosoft(string filePath)
        {
            lock (Checked)
            {
                Checked.Add(filePath);
            }

            if (_throw)
            {
                throw new InvalidOperationException("wintrust unavailable");
            }

            return _trusted.Contains(filePath);
        }
    }

    [Fact]
    public async Task EvergreenBootstrapper_RunsTheSignedBundledStub_AndReportsSuccess_OnZeroExit()
    {
        // A Microsoft-signed stub beside the exe is run as-is and no download happens; a zero exit
        // code is the success signal InstallAsync reports upward.
        var runner = new RecordingRunner(exitCode: 0);
        var download = new RecordingDownload(DownloadedPath);
        var verifier = new FakeVerifier(new[] { BundledPath });
        var bootstrapper = new EvergreenBootstrapper(
            locateBundled: () => BundledPath,
            download: download.DownloadAsync,
            verifier: verifier,
            runInstaller: runner.RunAsync);

        var installed = await bootstrapper.InstallAsync(CancellationToken.None);

        Assert.True(installed);
        Assert.Equal(new[] { BundledPath }, runner.Paths);
        Assert.Equal(new[] { BundledPath }, verifier.Checked);
        Assert.Equal(0, download.Calls);
    }

    [Fact]
    public async Task EvergreenBootstrapper_NeverRunsAnUnsignedBundledStub_AndFallsBackToTheVerifiedDownload()
    {
        // E1: a file planted in Downloads as MicrosoftEdgeWebView2Setup.exe fails the signature
        // check, so it is never run. The download is used instead, and it too is checked first.
        var runner = new RecordingRunner(exitCode: 0);
        var download = new RecordingDownload(DownloadedPath);
        var verifier = new FakeVerifier(new[] { DownloadedPath });
        var bootstrapper = new EvergreenBootstrapper(
            locateBundled: () => BundledPath,
            download: download.DownloadAsync,
            verifier: verifier,
            runInstaller: runner.RunAsync);

        var installed = await bootstrapper.InstallAsync(CancellationToken.None);

        Assert.True(installed);
        Assert.Equal(new[] { DownloadedPath }, runner.Paths);
        Assert.DoesNotContain(BundledPath, runner.Paths);
        Assert.Equal(new[] { BundledPath, DownloadedPath }, verifier.Checked);
        Assert.Equal(1, download.Calls);
    }

    [Fact]
    public async Task EvergreenBootstrapper_DownloadsAndVerifies_WhenNoStubIsBundled()
    {
        // The raw single-file exe has nothing beside it: the download is checked, then run.
        var runner = new RecordingRunner(exitCode: 0);
        var verifier = new FakeVerifier(new[] { DownloadedPath });
        var bootstrapper = new EvergreenBootstrapper(
            locateBundled: () => null,
            download: new RecordingDownload(DownloadedPath).DownloadAsync,
            verifier: verifier,
            runInstaller: runner.RunAsync);

        Assert.True(await bootstrapper.InstallAsync(CancellationToken.None));
        Assert.Equal(new[] { DownloadedPath }, runner.Paths);
        Assert.Equal(new[] { DownloadedPath }, verifier.Checked);
    }

    [Fact]
    public async Task EvergreenBootstrapper_Production_NeverRunsAStubBesideTheExe_EvenASignedOne()
    {
        // Review F5: a Microsoft-signed file run in place from Downloads would load a planted DLL
        // beside it, so production ignores whatever sits beside the exe and always downloads. The
        // file is planted beside the test host, where the old lookup would have found it.
        var beside = Path.Combine(AppContext.BaseDirectory, "MicrosoftEdgeWebView2Setup.exe");
        var planted = !File.Exists(beside);
        if (planted)
        {
            File.WriteAllText(beside, "stub");
        }

        try
        {
            var runner = new RecordingRunner(exitCode: 0);
            var verifier = new FakeVerifier(new[] { beside, DownloadedPath });
            var bootstrapper = new EvergreenBootstrapper(
                locateBundled: null,
                download: new RecordingDownload(DownloadedPath).DownloadAsync,
                verifier: verifier,
                runInstaller: runner.RunAsync);

            Assert.True(await bootstrapper.InstallAsync(CancellationToken.None));
            Assert.Equal(new[] { DownloadedPath }, runner.Paths);
            Assert.Equal(new[] { DownloadedPath }, verifier.Checked);
        }
        finally
        {
            if (planted)
            {
                File.Delete(beside);
            }
        }
    }

    [Fact]
    public async Task EvergreenBootstrapper_NeverRunsAnUnsignedDownload_AndEnsureRuntimeMapsItToFailed()
    {
        // E1: a download that is not Microsoft-signed (tampered, or a captive portal page) is never
        // run. InstallAsync reports false and the gate surfaces Failed, so the window shows Retry.
        var runner = new RecordingRunner(exitCode: 0);
        var bootstrapper = new EvergreenBootstrapper(
            locateBundled: () => BundledPath,
            download: new RecordingDownload(DownloadedPath).DownloadAsync,
            verifier: new FakeVerifier(),
            runInstaller: runner.RunAsync);
        var runtime = new WebView2Runtime(new FakeProbe(initialVersion: null), bootstrapper);

        Assert.False(await bootstrapper.InstallAsync(CancellationToken.None));
        Assert.Equal(RuntimeBootstrapResult.Failed, await runtime.EnsureRuntimeAsync());
        Assert.Empty(runner.Paths);
    }

    [Fact]
    public async Task EvergreenBootstrapper_TreatsAVerifierErrorAsUntrusted_AndRunsNothing()
    {
        // A signature check that throws must never be read as "trusted": nothing runs, and the
        // result is a recoverable false rather than a crash.
        var runner = new RecordingRunner(exitCode: 0);
        var bootstrapper = new EvergreenBootstrapper(
            locateBundled: () => BundledPath,
            download: new RecordingDownload(DownloadedPath).DownloadAsync,
            verifier: new FakeVerifier(throwOnCheck: true),
            runInstaller: runner.RunAsync);

        Assert.False(await bootstrapper.InstallAsync(CancellationToken.None));
        Assert.Empty(runner.Paths);
    }

    [Fact]
    public async Task EvergreenBootstrapper_ReportsFailure_OnNonZeroExit_AndEnsureRuntimeMapsItToFailed()
    {
        // The stub ran but exited non-zero: InstallAsync is false and the gate surfaces Failed (a
        // retry), not a throw.
        var runner = new RecordingRunner(exitCode: 1);
        var bootstrapper = new EvergreenBootstrapper(
            locateBundled: () => BundledPath,
            download: new RecordingDownload(DownloadedPath).DownloadAsync,
            verifier: new FakeVerifier(new[] { BundledPath }),
            runInstaller: runner.RunAsync);
        var runtime = new WebView2Runtime(new FakeProbe(initialVersion: null), bootstrapper);

        Assert.False(await bootstrapper.InstallAsync(CancellationToken.None));
        Assert.Equal(RuntimeBootstrapResult.Failed, await runtime.EnsureRuntimeAsync());
        Assert.Equal(2, runner.Paths.Count);
    }

    [Fact]
    public async Task EvergreenBootstrapper_ReportsFailure_WithoutRunning_WhenNoStubIsObtainable()
    {
        // No bundled stub and a null from the download means there is nothing to run: false, and
        // the runner is never invoked.
        var runner = new RecordingRunner(exitCode: 0);
        var bootstrapper = new EvergreenBootstrapper(
            locateBundled: () => null,
            download: new RecordingDownload(path: null).DownloadAsync,
            verifier: new FakeVerifier(),
            runInstaller: runner.RunAsync);

        Assert.False(await bootstrapper.InstallAsync(CancellationToken.None));
        Assert.Empty(runner.Paths);
    }

    [Fact]
    public async Task EvergreenBootstrapper_DownloadFailure_Propagates_AndEnsureRuntimeMapsItToFailed()
    {
        // An offline download throws HttpRequestException out of the download step. The
        // bootstrapper lets it propagate (so the "check your connection" text is true) and
        // EnsureRuntimeAsync's catch maps it to Failed with no throw and no installer run.
        var runner = new RecordingRunner(exitCode: 0);
        var bootstrapper = new EvergreenBootstrapper(
            locateBundled: () => null,
            download: _ => throw new HttpRequestException("offline"),
            verifier: new FakeVerifier(),
            runInstaller: runner.RunAsync);
        var runtime = new WebView2Runtime(new FakeProbe(initialVersion: null), bootstrapper);

        await Assert.ThrowsAsync<HttpRequestException>(() => bootstrapper.InstallAsync(CancellationToken.None));
        Assert.Equal(RuntimeBootstrapResult.Failed, await runtime.EnsureRuntimeAsync());
        Assert.Empty(runner.Paths);
    }

    [Fact]
    public void NewDownloadPath_IsAFreshUnpredictableFolderPerAttempt_NotTheOldFixedTempFile()
    {
        // E1: the old target was the fixed %TEMP%\MicrosoftEdgeWebView2Setup.exe, which another
        // program could write first. Each attempt now gets its own random folder under %TEMP%.
        const string tempRoot = @"C:\Users\tester\AppData\Local\Temp";

        var first = EvergreenBootstrapper.NewDownloadPath(tempRoot);
        var second = EvergreenBootstrapper.NewDownloadPath(tempRoot);

        Assert.NotEqual(first, second);
        Assert.NotEqual(Path.Combine(tempRoot, "MicrosoftEdgeWebView2Setup.exe"), first);
        Assert.Equal("MicrosoftEdgeWebView2Setup.exe", Path.GetFileName(first));
        Assert.Equal(tempRoot, Path.GetDirectoryName(Path.GetDirectoryName(first)));
        Assert.StartsWith("ClaudeBattery-WebView2-", Path.GetFileName(Path.GetDirectoryName(first)));
    }

    // ---- AuthenticodeSignatureVerifier: the publisher pin on the leaf certificate (E1). The
    // WinVerifyTrust half needs a real signed file on Windows and is not covered here.

    [Theory]
    [InlineData("CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US", true)]
    [InlineData("O=Microsoft Corporation", true)]
    [InlineData("CN=Microsoft Corporation, O=Contoso Ltd, C=US", false)]
    [InlineData("CN=Evil, OU=Microsoft Corporation, O=Evil Inc", false)]
    [InlineData("CN=Evil, O=Microsoft Corporation Ltd", false)]
    [InlineData("CN=Evil, O=microsoft corporation", false)]
    [InlineData("CN=\"O=Microsoft Corporation\", O=Evil Inc", false)]
    public void IsMicrosoftPublisher_MatchesOnlyAnExactMicrosoftOrganizationAttribute(string subject, bool expected)
    {
        Assert.Equal(expected, AuthenticodeSignatureVerifier.IsMicrosoftPublisher(new X500DistinguishedName(subject)));
    }

    [Fact]
    public void AuthenticodeSignatureVerifier_RejectsAMissingFile()
    {
        var missing = Path.Combine(Path.GetTempPath(), "cbw-" + Guid.NewGuid().ToString("N"), "MicrosoftEdgeWebView2Setup.exe");

        Assert.False(new AuthenticodeSignatureVerifier().IsSignedByMicrosoft(missing));
    }

    [Fact]
    public void AuthenticodeSignatureVerifier_RejectsAnUnsignedFile()
    {
        // A planted stand-in with no signature at all: never trusted.
        var path = Path.Combine(Path.GetTempPath(), "cbw-unsigned-" + Guid.NewGuid().ToString("N") + ".exe");
        File.WriteAllBytes(path, new byte[] { 0x4D, 0x5A, 0x90, 0x00 });
        try
        {
            Assert.False(new AuthenticodeSignatureVerifier().IsSignedByMicrosoft(path));
        }
        finally
        {
            File.Delete(path);
        }
    }
}
