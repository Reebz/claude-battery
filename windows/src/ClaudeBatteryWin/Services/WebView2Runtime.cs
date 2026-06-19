using System.Diagnostics;
using System.IO;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// WebView2 Evergreen Runtime detection and bootstrap (U8). There is no Mac analog: WKWebView
/// ships with macOS, but WebView2 is a separately-distributed runtime that can be absent (a clean
/// box) or uninstalled later. The installer (U12) bootstraps the runtime at install time; this
/// service is the uninstalled-later safety net.
///
/// Before any login, the app asks <see cref="IsAvailable"/>. When the runtime is absent, login is
/// blocked and a separate <c>RuntimeMissingWindow</c> (a distinct window, not a flyout/tray render
/// state, which has no runtime-missing variant) intercepts the tray click and drives
/// <see cref="EnsureRuntimeAsync"/>, which runs the Evergreen
/// bootstrapper silently. A failed or offline bootstrap surfaces a retry, never a blank window or
/// a crash.
///
/// Availability and bootstrap are both injected (<see cref="IWebView2RuntimeProbe"/>,
/// <see cref="IWebView2Bootstrapper"/>) so the gate is unit-testable on any platform without a real
/// runtime or installer present.
/// </summary>
public sealed class WebView2Runtime
{
    private readonly IWebView2RuntimeProbe _probe;
    private readonly IWebView2Bootstrapper _bootstrapper;

    public WebView2Runtime(IWebView2RuntimeProbe? probe = null, IWebView2Bootstrapper? bootstrapper = null)
    {
        _probe = probe ?? new CoreWebView2RuntimeProbe();
        _bootstrapper = bootstrapper ?? new EvergreenBootstrapper();
    }

    /// <summary>
    /// True when a usable WebView2 Runtime is installed. The single gate the login flow checks
    /// before opening a <c>LoginWindow</c>: when this is false, login is blocked and the
    /// runtime-missing window is shown instead.
    /// </summary>
    public bool IsAvailable() => !string.IsNullOrEmpty(_probe.GetAvailableVersion());

    /// <summary>
    /// The detected runtime version string, or null when absent. Mirrors what
    /// <see cref="CoreWebView2Environment.GetAvailableBrowserVersionString(string)"/> returns
    /// (channel suffix included for non-stable channels).
    /// </summary>
    public string? AvailableVersion() => _probe.GetAvailableVersion();

    /// <summary>
    /// Ensure the runtime is present, installing it via the Evergreen bootstrapper if it is not.
    /// Idempotent: returns <see cref="RuntimeBootstrapResult.AlreadyInstalled"/> immediately when a
    /// runtime is already available (so a retry after a successful install is a no-op), runs the
    /// silent bootstrapper otherwise, and re-probes afterward to confirm.
    ///
    /// Never throws for an install failure (a missing bootstrapper, an offline download, a non-zero
    /// exit, or an OS error): those map to <see cref="RuntimeBootstrapResult.Failed"/> so the caller
    /// can show a retry button rather than crashing the runtime-missing window.
    /// </summary>
    public async Task<RuntimeBootstrapResult> EnsureRuntimeAsync(CancellationToken cancellationToken = default)
    {
        if (IsAvailable())
        {
            return RuntimeBootstrapResult.AlreadyInstalled;
        }

        bool installed;
        try
        {
            installed = await _bootstrapper.InstallAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Honor cancellation explicitly; a cancelled install is not a "Failed" terminal state.
            throw;
        }
        catch (Exception)
        {
            // Any bootstrapper failure (process launch error, offline download, OS error) is a
            // recoverable Failed, never a crash. The runtime-missing window offers a retry.
            return RuntimeBootstrapResult.Failed;
        }

        if (!installed)
        {
            return RuntimeBootstrapResult.Failed;
        }

        // Re-probe: a zero exit code from the bootstrapper is necessary but not sufficient. Confirm
        // the runtime is actually visible before unblocking login.
        return IsAvailable() ? RuntimeBootstrapResult.Installed : RuntimeBootstrapResult.Failed;
    }
}

/// <summary>
/// Outcome of <see cref="WebView2Runtime.EnsureRuntimeAsync"/>. <see cref="AlreadyInstalled"/> and
/// <see cref="Installed"/> both unblock login; <see cref="Failed"/> keeps the runtime-missing
/// window up with a retry.
/// </summary>
public enum RuntimeBootstrapResult
{
    /// A runtime was already present; no install was attempted.
    AlreadyInstalled,

    /// The bootstrapper ran and a runtime is now present.
    Installed,

    /// The bootstrapper could not install a runtime (failed, offline, or runtime still absent
    /// after a zero exit). The caller shows a retry, not a crash.
    Failed
}

/// <summary>
/// Injectable availability check. Abstracted so the runtime gate can be unit-tested without a real
/// WebView2 runtime installed (the production path calls into the Edge runtime and the registry,
/// neither of which exists on a build/test box without the runtime).
/// </summary>
public interface IWebView2RuntimeProbe
{
    /// <summary>The installed runtime version, or null/empty when no runtime is available.</summary>
    string? GetAvailableVersion();
}

/// <summary>
/// Injectable bootstrapper runner. The production path launches the Evergreen bootstrapper
/// (<c>MicrosoftEdgeWebView2Setup.exe /silent /install</c>); tests substitute a fake to simulate a
/// successful, failed, or offline install without touching the real installer.
/// </summary>
public interface IWebView2Bootstrapper
{
    /// <summary>
    /// Run the silent runtime install. Returns true when the install process completed with a
    /// success exit code; false (or a throw, which the caller treats as Failed) otherwise.
    /// </summary>
    Task<bool> InstallAsync(CancellationToken cancellationToken);
}

/// <summary>
/// Production availability probe. Asks the WebView2 managed API first, falling back to the
/// EdgeUpdate <c>pv</c> registry value the runtime distribution docs document, so a probe still
/// works if the managed call is unavailable for any reason.
/// </summary>
public sealed class CoreWebView2RuntimeProbe : IWebView2RuntimeProbe
{
    // EdgeUpdate client GUID for the WebView2 Runtime (per the WebView2 distribution docs). The
    // pv (REG_SZ) value under these keys holds the installed runtime version.
    private const string WebView2ClientGuid = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
    private const string PerMachineKeyPath =
        @"SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\" + WebView2ClientGuid;
    private const string PerUserKeyPath =
        @"Software\Microsoft\EdgeUpdate\Clients\" + WebView2ClientGuid;

    public string? GetAvailableVersion()
    {
        try
        {
            // Empty browserExecutableFolder = use the installed Evergreen runtime. Throws
            // WebView2RuntimeNotFoundException when no runtime is installed.
            var version = CoreWebView2Environment.GetAvailableBrowserVersionString(browserExecutableFolder: null);
            if (!string.IsNullOrEmpty(version))
            {
                return version;
            }
        }
        catch (WebView2RuntimeNotFoundException)
        {
            // No runtime installed -- fall through to the registry check (it will also be absent,
            // but the fallback exists for environments where the managed call mis-reports).
        }
        catch (Exception)
        {
            // Loader/COM failures: do not crash detection. Treat as "ask the registry."
        }

        return ReadRegistryVersion();
    }

    private static string? ReadRegistryVersion()
    {
        // Per-machine install is the common case; per-user is the fallback.
        return ReadPvValue(Registry.LocalMachine, PerMachineKeyPath)
               ?? ReadPvValue(Registry.CurrentUser, PerUserKeyPath);
    }

    private static string? ReadPvValue(RegistryKey root, string subKeyPath)
    {
        try
        {
            using var key = root.OpenSubKey(subKeyPath);
            // A pv of "0.0.0.0" means EdgeUpdate tracks the client but no runtime is installed.
            if (key?.GetValue("pv") is string pv && !string.IsNullOrEmpty(pv) && pv != "0.0.0.0")
            {
                return pv;
            }
        }
        catch (Exception)
        {
            // Registry access denied / hive unavailable: treat as not found.
        }

        return null;
    }
}

/// <summary>
/// Production bootstrapper runner. Launches the Evergreen bootstrapper
/// (<c>MicrosoftEdgeWebView2Setup.exe /silent /install</c>) and awaits its exit. The bootstrapper
/// is expected next to the app (the U12 installer ships it); if it is not present this returns
/// false and the caller surfaces a retry.
/// </summary>
public sealed class EvergreenBootstrapper : IWebView2Bootstrapper
{
    // The Evergreen "bootstrapper" is a tiny stub that downloads and installs the full runtime; it
    // is what the U12 installer bundles next to the app. /silent /install does an unattended,
    // context-appropriate (per-machine when elevated, else per-user) install.
    private const string BootstrapperFileName = "MicrosoftEdgeWebView2Setup.exe";
    private static readonly string[] SilentInstallArguments = { "/silent", "/install" };

    public async Task<bool> InstallAsync(CancellationToken cancellationToken)
    {
        var bootstrapperPath = ResolveBootstrapperPath();
        if (bootstrapperPath is null)
        {
            // No bundled bootstrapper to run (and we cannot reach the network from here to fetch
            // one): a recoverable failure, surfaced as a retry by the caller.
            return false;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = bootstrapperPath,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var arg in SilentInstallArguments)
        {
            startInfo.ArgumentList.Add(arg);
        }

        using var process = Process.Start(startInfo);
        if (process is null)
        {
            return false;
        }

        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        return process.ExitCode == 0;
    }

    private static string? ResolveBootstrapperPath()
    {
        // The bootstrapper ships next to the app (the single-file extraction dir at run time).
        var baseDir = AppContext.BaseDirectory;
        var candidate = Path.Combine(baseDir, BootstrapperFileName);
        return File.Exists(candidate) ? candidate : null;
    }
}
