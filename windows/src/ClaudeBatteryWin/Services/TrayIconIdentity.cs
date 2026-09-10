using H.NotifyIcon.Core;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The tray icon's NIF_GUID identity, derived from the executable path instead of a fixed literal.
///
/// Windows stores the path of the binary inside an unsigned exe's tray-GUID registration, so a
/// fixed GUID makes <c>Shell_NotifyIcon(NIM_ADD)</c> fail the moment the same exe runs from a
/// different path (a re-download saved as "ClaudeBatteryWin (1).exe", a rename, a move out of
/// Downloads, a new tester build extracted into a new folder). H.NotifyIcon then throws from
/// <c>ForceCreate</c> before any UI exists and the process exits silently. Hashing the path into the
/// GUID gives every path its own registration, which is the same workaround the library uses for its
/// default Id. The only cost is that pinning is lost when the exe moves, which is exactly when a
/// fixed GUID would have failed outright. Revisit a fixed GUID only once the exe is
/// Authenticode-signed (Windows exempts same-publisher signed binaries from the path binding).
///
/// Pure and deterministic: the same path always yields the same GUID, so the flyout's
/// <c>Shell_NotifyIconGetRect</c> lookup and the tray registration agree, and the mapping is
/// unit-testable without a tray.
/// </summary>
internal static class TrayIconIdentity
{
    private const string Prefix = "com.reebz.claudebattery.tray|";

    /// <summary>
    /// The GUID for a given executable path. Trimmed and lower-cased first so the two spellings
    /// Windows treats as the same file (case-insensitive paths) map to one GUID.
    /// </summary>
    public static Guid ForPath(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        return TrayIcon.CreateUniqueGuidFromString(Prefix + path.Trim().ToLowerInvariant());
    }

    /// <summary>
    /// The GUID for this process's executable. <see cref="Environment.ProcessPath"/> is the
    /// single-file host exe; the base directory is the fallback when the runtime cannot report it.
    /// </summary>
    public static Guid Current => ForPath(Environment.ProcessPath ?? AppContext.BaseDirectory);
}
