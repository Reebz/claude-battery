using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// WebView2 Evergreen Runtime detection and bootstrap (U8). There is no Mac analog: WKWebView
/// ships with macOS, but WebView2 is a separately-distributed runtime that can be absent (a clean
/// box) or uninstalled later. This service is the in-app safety net: it fetches and runs the
/// Evergreen bootstrapper itself, so the raw exe does not depend on an installer to ship the stub.
///
/// Before any login, the app asks <see cref="IsAvailable"/>. When the runtime is absent, login is
/// blocked and a separate <c>RuntimeMissingWindow</c> (a distinct window, not a flyout/tray render
/// state, which has no runtime-missing variant) intercepts the tray click and drives
/// <see cref="EnsureRuntimeAsync"/>, which fetches and runs the Evergreen bootstrapper silently.
/// A failed or offline bootstrap surfaces a retry plus a link to Microsoft's download page, never
/// a blank window or a crash.
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
    /// Never throws for an install failure (an unobtainable bootstrapper, an offline download, a
    /// non-zero exit, or an OS error): those map to <see cref="RuntimeBootstrapResult.Failed"/> so the caller
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
/// Injectable bootstrapper runner. The production path fetches and launches the Evergreen bootstrapper (<c>MicrosoftEdgeWebView2Setup.exe /silent /install</c>);
/// tests substitute a fake to simulate a successful, failed, or offline install without touching
/// the network or the real installer.
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
/// Production bootstrapper runner. Downloads the Evergreen bootstrapper
/// (<c>MicrosoftEdgeWebView2Setup.exe</c>) from Microsoft's documented permalink (about 2 MB) into a
/// fresh, unpredictable temp folder, checks that it carries a valid Microsoft Authenticode
/// signature, then runs it with <c>/silent /install</c> and awaits its exit. A download failure
/// (offline, DNS, disk) propagates so <see cref="WebView2Runtime.EnsureRuntimeAsync"/> maps it to
/// <see cref="RuntimeBootstrapResult.Failed"/> and the window's "check your connection" text is true;
/// a download that fails the signature check is never run and also reports Failed.
///
/// Why the check (E1): a download can be tampered with or be a captive portal page, and clicking
/// Install would run it as the current user.
///
/// Why production never looks beside the exe (E1, review F5): testers run the raw exe straight from
/// Downloads, so "beside the exe" is the Downloads folder, where any site can drop a file named
/// MicrosoftEdgeWebView2Setup.exe. Even a genuinely Microsoft-signed file run in place there
/// searches Downloads first for the DLLs it loads, so a planted DLL next to it would still run.
/// Nothing ships a stub beside the exe (the raw single-file exe is the whole download), so the stub
/// is always fetched into its own folder. The <c>locateBundled</c> seam stays so tests still pin
/// that a stub found beside the app is verified before it is run.
///
/// Every step is an injectable seam so the locate -> verify -> download -> verify -> run -> exit-code
/// contract is unit-testable without a network, a real stub, a signature, or a real install.
/// </summary>
public sealed class EvergreenBootstrapper : IWebView2Bootstrapper
{
    // The Evergreen "bootstrapper" is a tiny stub that downloads and installs the full runtime.
    // /silent /install does an unattended, context-appropriate (per-machine when elevated, else
    // per-user) install.
    private const string BootstrapperFileName = "MicrosoftEdgeWebView2Setup.exe";
    private static readonly string[] SilentInstallArguments = { "/silent", "/install" };

    // Prefix for the per-attempt download folder under %TEMP%. The folder name carries a random
    // GUID, so nothing can pre-plant a file at the path the download will be run from (E1).
    private const string DownloadFolderPrefix = "ClaudeBattery-WebView2-";

    // Microsoft's documented Evergreen bootstrapper permalink (WebView2 distribution docs). It
    // redirects to the current stub; HttpClient follows the redirect by default.
    private const string BootstrapperDownloadUrl = "https://go.microsoft.com/fwlink/p/?LinkId=2124703";

    // One shared client for the process: a per-attempt client would leak sockets across retries.
    // 60 s covers the ~2 MB stub on a slow link.
    private static readonly HttpClient DownloadClient = new() { Timeout = TimeSpan.FromSeconds(60) };

    /// <summary>Upper bound on the whole stub download, headers plus the ~2 MB body.</summary>
    private static readonly TimeSpan DownloadDeadline = TimeSpan.FromMinutes(3);

    private readonly Func<string?> _locateBundled;
    private readonly Func<CancellationToken, Task<string?>> _download;
    private readonly IBootstrapperSignatureVerifier _verifier;
    private readonly Func<string, CancellationToken, Task<int>> _runInstaller;

    public EvergreenBootstrapper() : this(null, null, null, null)
    {
    }

    /// <summary>
    /// Test seam. <paramref name="locateBundled"/> returns the path of a stub beside the app, or
    /// null when there is none; <paramref name="download"/> fetches a stub and returns its path
    /// (null = none obtainable, reported as a non-throwing false; a throw propagates);
    /// <paramref name="verifier"/> decides whether a file is Microsoft-signed and may be run;
    /// <paramref name="runInstaller"/> runs it and returns the process exit code. Any null falls
    /// back to the production behavior, which for <paramref name="locateBundled"/> is "none".
    /// </summary>
    public EvergreenBootstrapper(
        Func<string?>? locateBundled = null,
        Func<CancellationToken, Task<string?>>? download = null,
        IBootstrapperSignatureVerifier? verifier = null,
        Func<string, CancellationToken, Task<int>>? runInstaller = null)
    {
        // Production has no stub beside the exe to find (review F5).
        _locateBundled = locateBundled ?? (() => null);
        _download = download ?? DownloadAsync;
        _verifier = verifier ?? new AuthenticodeSignatureVerifier();
        _runInstaller = runInstaller ?? RunInstallerAsync;
    }

    public async Task<bool> InstallAsync(CancellationToken cancellationToken)
    {
        // A stub beside the exe (test seam only; production passes none, review F5) is used only
        // when it is Microsoft-signed. An unsigned or foreign one is skipped (never run) and the
        // download below takes over, so a planted file cannot block the install either (E1).
        var bootstrapperPath = _locateBundled();
        if (bootstrapperPath is null || !await IsTrustedAsync(bootstrapperPath, cancellationToken).ConfigureAwait(false))
        {
            bootstrapperPath = await _download(cancellationToken).ConfigureAwait(false);
            if (bootstrapperPath is null)
            {
                // Nothing to run: a recoverable failure, surfaced as a retry by the caller.
                return false;
            }

            if (!await IsTrustedAsync(bootstrapperPath, cancellationToken).ConfigureAwait(false))
            {
                // The download is not a valid Microsoft-signed stub (tampered, truncated, or a
                // captive portal page). Never run it; the window shows the existing Retry state.
                return false;
            }
        }

        var exitCode = await _runInstaller(bootstrapperPath, cancellationToken).ConfigureAwait(false);
        return exitCode == 0;
    }

    /// <summary>
    /// Runs the signature check off the calling thread: InstallAsync starts synchronously on the
    /// UI thread (RuntimeMissingWindow awaits EnsureRuntimeAsync with no ConfigureAwait), and
    /// WinVerifyTrust can take seconds while it builds the certificate chain. A verifier that
    /// throws counts as "not trusted", so a check error can never lead to running the file.
    /// </summary>
    private async Task<bool> IsTrustedAsync(string path, CancellationToken cancellationToken)
    {
        try
        {
            return await Task.Run(() => _verifier.IsSignedByMicrosoft(path), cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// A new download target for one attempt: <c>%TEMP%\ClaudeBattery-WebView2-{guid}\</c> plus the
    /// stub file name. The random folder replaces the old fixed <c>%TEMP%\MicrosoftEdgeWebView2Setup.exe</c>,
    /// which another program could have written first. Pure (creates nothing) so it is testable.
    /// </summary>
    internal static string NewDownloadPath(string tempRoot) =>
        Path.Combine(tempRoot, DownloadFolderPrefix + Guid.NewGuid().ToString("N"), BootstrapperFileName);

    /// <summary>
    /// Production download into a fresh temp folder. Network and disk errors propagate to the
    /// caller. The caller verifies the file before it is ever run.
    /// </summary>
    private static async Task<string?> DownloadAsync(CancellationToken cancellationToken)
    {
        var downloadPath = NewDownloadPath(Path.GetTempPath());
        Directory.CreateDirectory(Path.GetDirectoryName(downloadPath)!);

        // HttpClient.Timeout only covers the request up to the headers under ResponseHeadersRead, so
        // a body that stalls (captive portal, flaky Wi-Fi, a proxy that accepts then hangs) would sit
        // on the modal "Installing..." dialog forever with no Cancel. One linked deadline bounds
        // headers and body together; a deadline expiry is reported as a download failure so
        // EnsureRuntimeAsync maps it to Failed and the window offers Retry.
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(DownloadDeadline);
        try
        {
            using var response = await DownloadClient
                .GetAsync(BootstrapperDownloadUrl, HttpCompletionOption.ResponseHeadersRead, deadline.Token)
                .ConfigureAwait(false);
            response.EnsureSuccessStatusCode();

            // FileMode.CreateNew in a folder made for this attempt: nothing else can already be at
            // this path, and a torn file from an earlier failed attempt lives in a different folder.
            // The installer only runs after this write completes and the signature check passes,
            // so a partial download is never executed. The file handle is released before the
            // catch runs and before verification opens the file.
            await using (var file = new FileStream(downloadPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                await response.Content.CopyToAsync(file, deadline.Token).ConfigureAwait(false);
            }

            return downloadPath;
        }
        catch (OperationCanceledException ex) when (!cancellationToken.IsCancellationRequested)
        {
            throw new HttpRequestException("WebView2 bootstrapper download timed out.", ex);
        }
    }

    /// <summary>Production run: launch the stub silently and return its exit code.</summary>
    private static async Task<int> RunInstallerAsync(string bootstrapperPath, CancellationToken cancellationToken)
    {
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
            // Process.Start handed back no process: report a failed run (non-zero), not a crash.
            return -1;
        }

        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        return process.ExitCode;
    }
}

/// <summary>
/// Injectable signature check for the bootstrapper (E1). The production check needs wintrust.dll
/// and a real signed file, so tests substitute a fake to prove an unsigned file is never run.
/// </summary>
public interface IBootstrapperSignatureVerifier
{
    /// <summary>
    /// True only when <paramref name="filePath"/> has a valid Authenticode signature that chains
    /// to a trusted root AND the signing (leaf) certificate belongs to Microsoft Corporation.
    /// </summary>
    bool IsSignedByMicrosoft(string filePath);
}

/// <summary>
/// Production signature check: WinVerifyTrust with the Authenticode policy
/// (WINTRUST_ACTION_GENERIC_VERIFY_V2, no UI), then a publisher pin on the leaf certificate's
/// organization (O=) attribute. Both must pass; any error along the way answers false.
///
/// Revocation: WTD_REVOKE_NONE plus WTD_REVOCATION_CHECK_NONE, so an offline or captive-portal
/// network cannot stall the check on CRL or OCSP fetches. The trust chain and the publisher pin
/// are what keep a planted file from running; revocation of Microsoft's own signing certificate
/// is not the threat this guards against.
/// </summary>
public sealed class AuthenticodeSignatureVerifier : IBootstrapperSignatureVerifier
{
    /// <summary>The organization every Microsoft code-signing leaf certificate names.</summary>
    internal const string MicrosoftOrganization = "Microsoft Corporation";

    // X.500 organizationName attribute type (O=).
    private const string OrganizationOid = "2.5.4.10";

    public bool IsSignedByMicrosoft(string filePath)
    {
        if (!OperatingSystem.IsWindows() || !File.Exists(filePath))
        {
            return false;
        }

        try
        {
            if (!WinTrust.VerifyEmbeddedSignature(filePath))
            {
                return false;
            }

            // WinVerifyTrust has just validated the primary signature; CreateFromSignedFile reads
            // the signer certificate of that same primary signature.
            using var signer = new X509Certificate2(X509Certificate.CreateFromSignedFile(filePath));
            return IsMicrosoftPublisher(signer.SubjectName);
        }
        catch (Exception)
        {
            // Unsigned file (CreateFromSignedFile throws CryptographicException), unreadable file,
            // or a missing wintrust export: never trusted.
            return false;
        }
    }

    /// <summary>
    /// True when the subject has an O= attribute that is exactly "Microsoft Corporation". Parsed
    /// through the distinguished name's attributes rather than a substring match, so a subject
    /// like <c>CN="O=Microsoft Corporation"</c>, <c>OU=Microsoft Corporation</c>, or
    /// <c>O=Microsoft Corporation Ltd</c> does not pass.
    /// </summary>
    internal static bool IsMicrosoftPublisher(X500DistinguishedName subject)
    {
        foreach (var rdn in subject.EnumerateRelativeDistinguishedNames())
        {
            if (rdn.HasMultipleElements)
            {
                continue;
            }

            if (rdn.GetSingleElementType().Value == OrganizationOid &&
                string.Equals(rdn.GetSingleElementValue(), MicrosoftOrganization, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// wintrust.dll P/Invoke. Layouts follow wintrust.h (WINTRUST_DATA, WINTRUST_FILE_INFO) with
    /// every pointer and handle as IntPtr, so the structs are blittable and get the same natural
    /// alignment as the native ones on x64 and ARM64 (WINTRUST_DATA is 88 bytes on both).
    /// </summary>
    private static class WinTrust
    {
        // WINTRUST_ACTION_GENERIC_VERIFY_V2 (Softpub.h): the Authenticode policy provider.
        private static readonly Guid GenericVerifyV2 = new("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");

        private const uint WTD_UI_NONE = 2;
        private const uint WTD_REVOKE_NONE = 0;
        private const uint WTD_CHOICE_FILE = 1;
        private const uint WTD_STATEACTION_VERIFY = 1;
        private const uint WTD_STATEACTION_CLOSE = 2;
        private const uint WTD_REVOCATION_CHECK_NONE = 0x10;
        private const uint WTD_DISABLE_MD2_MD4 = 0x2000;
        private const uint WTD_UICONTEXT_EXECUTE = 0;

        // INVALID_HANDLE_VALUE as the hwnd tells WinVerifyTrust there is no interactive user.
        private static readonly IntPtr NoInteractiveUser = new(-1);

        [StructLayout(LayoutKind.Sequential)]
        private struct WINTRUST_FILE_INFO
        {
            public uint cbStruct;
            public IntPtr pcwszFilePath;
            public IntPtr hFile;
            public IntPtr pgKnownSubject;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WINTRUST_DATA
        {
            public uint cbStruct;
            public IntPtr pPolicyCallbackData;
            public IntPtr pSIPClientData;
            public uint dwUIChoice;
            public uint fdwRevocationChecks;
            public uint dwUnionChoice;
            public IntPtr pFile; // union; WTD_CHOICE_FILE selects pFile
            public uint dwStateAction;
            public IntPtr hWVTStateData;
            public IntPtr pwszURLReference;
            public uint dwProvFlags;
            public uint dwUIContext;
            public IntPtr pSignatureSettings;
        }

        // Returns a LONG, not an HRESULT: only exactly zero means trusted.
        [DllImport("wintrust.dll", ExactSpelling = true, SetLastError = false)]
        private static extern int WinVerifyTrust(IntPtr hwnd, ref Guid pgActionID, ref WINTRUST_DATA pWVTData);

        public static bool VerifyEmbeddedSignature(string filePath)
        {
            var pathPtr = Marshal.StringToCoTaskMemUni(filePath);
            var fileInfoPtr = IntPtr.Zero;
            try
            {
                var fileInfo = new WINTRUST_FILE_INFO
                {
                    cbStruct = (uint)Marshal.SizeOf<WINTRUST_FILE_INFO>(),
                    pcwszFilePath = pathPtr,
                    hFile = IntPtr.Zero,
                    pgKnownSubject = IntPtr.Zero,
                };
                fileInfoPtr = Marshal.AllocCoTaskMem(Marshal.SizeOf<WINTRUST_FILE_INFO>());
                Marshal.StructureToPtr(fileInfo, fileInfoPtr, fDeleteOld: false);

                var data = new WINTRUST_DATA
                {
                    cbStruct = (uint)Marshal.SizeOf<WINTRUST_DATA>(),
                    dwUIChoice = WTD_UI_NONE,
                    fdwRevocationChecks = WTD_REVOKE_NONE,
                    dwUnionChoice = WTD_CHOICE_FILE,
                    pFile = fileInfoPtr,
                    dwStateAction = WTD_STATEACTION_VERIFY,
                    dwProvFlags = WTD_REVOCATION_CHECK_NONE | WTD_DISABLE_MD2_MD4,
                    dwUIContext = WTD_UICONTEXT_EXECUTE,
                };

                var action = GenericVerifyV2;
                var status = WinVerifyTrust(NoInteractiveUser, ref action, ref data);

                // Every WTD_STATEACTION_VERIFY must be paired with a WTD_STATEACTION_CLOSE to free
                // hWVTStateData, whatever the verify result was.
                data.dwStateAction = WTD_STATEACTION_CLOSE;
                WinVerifyTrust(NoInteractiveUser, ref action, ref data);

                return status == 0;
            }
            finally
            {
                if (fileInfoPtr != IntPtr.Zero)
                {
                    Marshal.FreeCoTaskMem(fileInfoPtr);
                }

                Marshal.FreeCoTaskMem(pathPtr);
            }
        }
    }
}
