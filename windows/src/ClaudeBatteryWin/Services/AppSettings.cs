using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The app-global preference flags the Mac kept in <c>UserDefaults</c> / <c>@AppStorage</c>
/// (SettingsView.swift): the low-usage notifications master switch, the menu-bar session-countdown
/// toggle, and the opt-in diagnostics logging gate. The per-account notification threshold and nickname live on the
/// <see cref="Models.Account"/> via the AccountStore (U5); these two are app-wide, not per-account.
///
/// Defaults match the Mac verbatim: notifications OFF, countdown OFF.
///
/// Injected behind <see cref="IAppSettings"/> so the Notifier's enable gate and the Settings
/// bindings are testable without disk. The default implementation persists to a small JSON file
/// under <c>%APPDATA%\ClaudeBatteryWin\settings.json</c>.
/// </summary>
public interface IAppSettings
{
    /// Master switch for low-usage toasts (Mac "notificationsEnabled"). Default false.
    bool NotificationsEnabled { get; set; }

    /// Show the compact session countdown to the left of the tray icon (Mac
    /// "showSessionCountdown"). Default false.
    bool ShowSessionCountdown { get; set; }

    /// Opt-in diagnostics logging (Mac "diagnosticLoggingEnabled"). Default false: the logger writes
    /// nothing at all, not even a directory, until this is on.
    bool DiagnosticsEnabled { get; set; }

    /// Whether the first-run "Windows may be hiding this icon" notice has been shown (R44, KTD13).
    /// Per Windows profile, once, and never again on update: the settings file already lives in the
    /// per-profile roaming folder, and re-nagging on every release is the failure to avoid.
    bool HasShownTrayNotice { get; set; }

    /// Which tray icon style to draw (R39). Stored as the display string so a settings file written
    /// by an older build, or edited by hand, still reads back as something; anything unrecognised
    /// falls back to Stacked Bars, the style the beta shipped.
    Icons.TrayIconStyle IconStyle { get; set; }

    /// Raised whenever a flag changes, so the tray renderer / poller can react (e.g. the icon
    /// re-composes the countdown cell when <see cref="ShowSessionCountdown"/> flips).
    event EventHandler? Changed;
}

/// <summary>
/// JSON-file-backed <see cref="IAppSettings"/>. Reads on construction, writes on every set. A
/// read/write failure degrades to defaults rather than throwing (a settings file is never
/// load-bearing for sign-in or polling).
/// </summary>
public sealed class AppSettings : IAppSettings
{
    private readonly string _path;
    private readonly object _gate = new();
    private State _state;

    public AppSettings(string? path = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "ClaudeBatteryWin",
            "settings.json");
        _state = Read();
    }

    public event EventHandler? Changed;

    public bool NotificationsEnabled
    {
        get { lock (_gate) { return _state.NotificationsEnabled; } }
        set => Update(s => s with { NotificationsEnabled = value });
    }

    public bool ShowSessionCountdown
    {
        get { lock (_gate) { return _state.ShowSessionCountdown; } }
        set => Update(s => s with { ShowSessionCountdown = value });
    }

    public bool DiagnosticsEnabled
    {
        get { lock (_gate) { return _state.DiagnosticsEnabled; } }
        set => Update(s => s with { DiagnosticsEnabled = value });
    }

    public bool HasShownTrayNotice
    {
        get { lock (_gate) { return _state.HasShownTrayNotice; } }
        set => Update(s => s with { HasShownTrayNotice = value });
    }

    public Icons.TrayIconStyle IconStyle
    {
        get { lock (_gate) { return Icons.TrayIconStyles.Parse(_state.IconStyle); } }
        set => Update(s => s with { IconStyle = Icons.TrayIconStyles.NameOf(value) });
    }

    private void Update(Func<State, State> mutate)
    {
        bool changed;
        lock (_gate)
        {
            var next = mutate(_state);
            changed = next != _state;
            if (changed)
            {
                _state = next;
                Write(next);
            }
        }
        if (changed)
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    private State Read()
    {
        try
        {
            if (!File.Exists(_path))
            {
                return new State();
            }
            var json = File.ReadAllBytes(_path);
            return JsonSerializer.Deserialize<State>(json) ?? new State();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            DebugLog("Failed to read settings (using defaults)");
            return new State();
        }
    }

    private void Write(State state)
    {
        var temp = _path + ".tmp";
        try
        {
            var dir = Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            var json = JsonSerializer.SerializeToUtf8Bytes(state);
            File.WriteAllBytes(temp, json);
            File.Move(temp, _path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            DebugLog("Failed to persist settings (ignored)");
            // A failed write (e.g. the rename step threw) must not leave an orphaned .tmp behind (U24).
            try
            {
                if (File.Exists(temp))
                {
                    File.Delete(temp);
                }
            }
            catch (Exception cleanupEx) when (cleanupEx is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[AppSettings] {message}");

    private sealed record State
    {
        public bool NotificationsEnabled { get; init; }
        public bool ShowSessionCountdown { get; init; }
        public bool DiagnosticsEnabled { get; init; }
        public string? IconStyle { get; init; }
        public bool HasShownTrayNotice { get; init; }
    }
}
