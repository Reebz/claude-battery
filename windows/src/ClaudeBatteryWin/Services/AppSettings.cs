using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The two app-global UI preference flags the Mac kept in <c>UserDefaults</c> / <c>@AppStorage</c>
/// (SettingsView.swift): the low-usage notifications master switch and the menu-bar
/// session-countdown toggle. The per-account notification threshold and nickname live on the
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
        try
        {
            var dir = Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            var json = JsonSerializer.SerializeToUtf8Bytes(state);
            var temp = _path + ".tmp";
            File.WriteAllBytes(temp, json);
            File.Move(temp, _path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            DebugLog("Failed to persist settings (ignored)");
        }
    }

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[AppSettings] {message}");

    private sealed record State
    {
        public bool NotificationsEnabled { get; init; }
        public bool ShowSessionCountdown { get; init; }
    }
}
