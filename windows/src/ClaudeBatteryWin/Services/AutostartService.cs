using System.Diagnostics;
using System.IO;
using Microsoft.Win32;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// Launch-at-login via the per-user <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Run</c> key
/// (U11). The Windows analog of the Mac <c>SMAppService.mainApp.register()/.unregister()</c> in
/// SettingsView.swift: the Settings toggle calls <see cref="SetEnabled"/>, and <see cref="IsEnabled"/>
/// reflects the current state when the toggle appears.
///
/// <para>
/// <b>The canonical path is load-bearing.</b> The Run value must point at the stable Velopack
/// <c>current\ClaudeBatteryWin.exe</c> launcher path - the one that survives version updates - not
/// the versioned <c>app-X.Y.Z\</c> folder, which Velopack deletes on the next update and would leave
/// a dangling autostart entry. <see cref="CanonicalExePath"/> resolves that stable path (see its
/// remarks). The Velopack uninstaller also removes the Run value, so an uninstall does not leave a
/// startup entry behind; this service does not need to clean up on uninstall.
/// </para>
///
/// <para>
/// The registry surface and the path resolver are injected so the write/remove/read behavior is
/// unit-testable against an in-memory fake without touching the real <c>HKCU</c> hive or depending
/// on a Velopack-managed install layout. Production uses the real <c>HKCU\...\Run</c> key.
/// </para>
/// </summary>
public sealed class AutostartService
{
    /// The value name under the Run key. Stable across versions.
    public const string RunValueName = "ClaudeBatteryWin";

    /// HKCU Run subkey path. The per-user key, so no elevation is needed (matches the Mac per-user
    /// SMAppService scope).
    public const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";

    private readonly IRunKey _runKey;
    private readonly Func<string> _exePath;

    /// <summary>Production constructor: the real HKCU Run key and the canonical Velopack exe path.</summary>
    public AutostartService()
        : this(new HkcuRunKey(), () => CanonicalExePath())
    {
    }

    /// <summary>
    /// Testable constructor: injects the registry surface and the path resolver so the
    /// write/remove/read flow is exercised without the real registry or a Velopack install.
    /// </summary>
    public AutostartService(IRunKey runKey, Func<string> exePath)
    {
        _runKey = runKey ?? throw new ArgumentNullException(nameof(runKey));
        _exePath = exePath ?? throw new ArgumentNullException(nameof(exePath));
    }

    /// <summary>
    /// True when an autostart Run value is present (regardless of its exact path; the toggle only
    /// reflects on/off). Mirrors the Mac <c>SMAppService.mainApp.status == .enabled</c> read.
    /// </summary>
    public bool IsEnabled => _runKey.GetValue(RunValueName) is not null;

    /// <summary>
    /// Enable or disable launch-at-login. Enabling writes the canonical exe path (quoted, so a path
    /// containing spaces parses as a single argv[0]); disabling removes the value. Idempotent and
    /// best-effort: a registry failure is swallowed (the Mac catch arm re-reads status and leaves
    /// the toggle reflecting reality), so the caller should re-read <see cref="IsEnabled"/> after.
    /// Returns the resulting enabled state (the actual state after the attempt), so the Settings
    /// toggle can snap back if the write failed - the same recovery the Mac does on a thrown
    /// register/unregister.
    /// </summary>
    public bool SetEnabled(bool enabled)
    {
        try
        {
            if (enabled)
            {
                // Quote the path: HKCU Run values are parsed as a command line, so an unquoted path
                // with spaces (e.g. under "Program Files") would split into bad args.
                _runKey.SetValue(RunValueName, $"\"{_exePath()}\"");
            }
            else
            {
                _runKey.DeleteValue(RunValueName);
            }
        }
        catch (Exception ex)
        {
            DebugLog($"Autostart {(enabled ? "enable" : "disable")} failed: {ex.GetType().Name}");
        }

        return IsEnabled;
    }

    /// <summary>
    /// Resolve the stable, version-independent launcher path Velopack keeps at
    /// <c>%LOCALAPPDATA%\ClaudeBatteryWin\current\ClaudeBatteryWin.exe</c>. Velopack installs each
    /// version under a versioned <c>app-X.Y.Z\</c> folder but exposes a stable <c>current\</c>
    /// launcher (and a top-level stub) that always points at the active version; autostart and
    /// tray-pinning must use that stable path or they break after the first update.
    ///
    /// The current process path is normally already the stable launcher when running from a Velopack
    /// install. If it resolves inside a versioned <c>app-*</c> folder (an edge during a hand-off),
    /// rewrite it up to the sibling <c>current\</c> folder so the persisted Run value never captures
    /// a folder Velopack will delete.
    /// </summary>
    public static string CanonicalExePath()
        => CanonicalExePathFor(
            Environment.ProcessPath
            ?? Process.GetCurrentProcess().MainModule?.FileName
            ?? AppContext.BaseDirectory);

    /// <summary>
    /// Pure path-rewrite rule: given a launcher path, return the stable, update-surviving form. If
    /// <paramref name="current"/> resolves inside a versioned <c>app-X.Y.Z\</c> folder, rewrite it
    /// to the sibling <c>current\</c> launcher (the folder Velopack keeps across updates); otherwise
    /// return it unchanged. Extracted from <see cref="CanonicalExePath"/> so the rewrite is
    /// unit-testable without a real process path.
    /// </summary>
    public static string CanonicalExePathFor(string current)
    {
        var dir = Path.GetDirectoryName(current);
        var fileName = Path.GetFileName(current);
        if (dir is null || fileName.Length == 0)
        {
            return current;
        }

        // If we are inside a versioned "app-X.Y.Z" folder, point at the sibling "current" launcher
        // instead so the value survives updates.
        var folderName = Path.GetFileName(dir);
        if (folderName.StartsWith("app-", StringComparison.OrdinalIgnoreCase))
        {
            var parent = Path.GetDirectoryName(dir);
            if (parent is not null)
            {
                return Path.Combine(parent, "current", fileName);
            }
        }

        return current;
    }

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[AutostartService] {message}");
}

/// <summary>
/// The minimal registry surface the autostart service needs: read, write, and delete a single named
/// value under the Run key. Injected so <see cref="AutostartService"/> is unit-testable against an
/// in-memory fake without touching the real <c>HKCU</c> hive. Production is
/// <see cref="HkcuRunKey"/>.
/// </summary>
public interface IRunKey
{
    /// Return the value (string) or null when absent.
    object? GetValue(string name);

    /// Create or overwrite the value as a string (REG_SZ).
    void SetValue(string name, string value);

    /// Remove the value; a no-op when it does not exist.
    void DeleteValue(string name);
}

/// <summary>
/// Production <see cref="IRunKey"/> over the real
/// <c>HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run</c> key. Opens the key
/// per-operation (cheap; avoids holding a handle for the app lifetime). Not unit-tested.
/// </summary>
public sealed class HkcuRunKey : IRunKey
{
    public object? GetValue(string name)
    {
        using RegistryKey? key = Registry.CurrentUser.OpenSubKey(AutostartService.RunKeyPath, writable: false);
        return key?.GetValue(name);
    }

    public void SetValue(string name, string value)
    {
        // CreateSubKey returns the existing key when present, so this both creates Run (it always
        // exists on a real Windows profile) and opens it writable.
        using RegistryKey key = Registry.CurrentUser.CreateSubKey(AutostartService.RunKeyPath, writable: true)
            ?? throw new InvalidOperationException("Could not open the HKCU Run key for writing.");
        key.SetValue(name, value, RegistryValueKind.String);
    }

    public void DeleteValue(string name)
    {
        using RegistryKey? key = Registry.CurrentUser.OpenSubKey(AutostartService.RunKeyPath, writable: true);
        // throwOnMissingValue: false -> disabling when already disabled is a no-op.
        key?.DeleteValue(name, throwOnMissingValue: false);
    }
}
