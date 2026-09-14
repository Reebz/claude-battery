using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The opt-in diagnostics sink (U2, KD7, KTD5). Ported from the Mac <c>DiagnosticsLogger</c>.
///
/// It does nothing at all until the user turns logging on in Settings: no file, no directory, not
/// even a built payload. That is why <see cref="EmitMilestone"/> takes a delegate rather than a
/// dictionary - the plan-sample producer runs every couple of minutes for every user, and almost
/// nobody has logging on, so the payload must not be built when the gate is shut.
///
/// Every line is written through <see cref="SecretRedactor"/>, with no per-kind exemption. One file
/// per launch under <c>%LocalAppData%\ClaudeBatteryWin\Logs</c>, named
/// <c>diag-&lt;utc date&gt;-&lt;launch token&gt;.jsonl</c>, so two launches on the same day never
/// share a file. Files older than the retention window are removed when a new session opens.
/// </summary>
public interface IDiagnosticsLogger
{
    /// <summary>
    /// Record one milestone. The payload delegate is only invoked when logging is on.
    /// </summary>
    void EmitMilestone(string kind, Func<IDictionary<string, object?>> payload);

    /// <summary>Write a final session-end record. Called at app shutdown.</summary>
    void Flush();

    /// <summary>The file this launch is writing to, or null if nothing has been written.</summary>
    string? CurrentSessionFilePath { get; }
}

/// <inheritdoc />
public sealed class DiagnosticsLogger : IDiagnosticsLogger, IDisposable
{
    /// <summary>Log files older than this are removed when a new session opens.</summary>
    internal const int RetentionDays = 7;

    /// <summary>What the diagnostics record calls the log directory. The resolved absolute path is
    /// never written: on Windows it contains the account name, and these files are meant to be
    /// attached to a public issue.</summary>
    internal const string LogDirectoryLabel = @"%LOCALAPPDATA%\ClaudeBatteryWin\Logs";

    private readonly IAppSettings? _settings;
    private readonly bool? _enabledOverride;
    private readonly string? _directoryOverride;
    private readonly string _launchToken = Guid.NewGuid().ToString("N")[..8];

    private readonly object _gate = new();
    private bool _didStartSession;
    private bool _loggedOpenFailure;
    private FileStream? _file;
    private string? _filePath;

    /// <summary>
    /// Production callers pass only the settings. The two overrides exist so tests can run against a
    /// temp directory with the gate forced open, without touching the real settings file or the real
    /// log directory.
    /// </summary>
    public DiagnosticsLogger(IAppSettings? settings, string? directoryOverride = null, bool? enabledOverride = null)
    {
        _settings = settings;
        _directoryOverride = directoryOverride;
        _enabledOverride = enabledOverride;
    }

    /// <summary>The app-wide instance. Producers that are not constructor-injected use this.</summary>
    public static IDiagnosticsLogger Shared { get; private set; } = new DiagnosticsLogger(settings: null);

    /// <summary>Called once from the composition root, after settings exist. Null restores the
    /// inert default, which is what a test wants when it is done with its own logger.</summary>
    public static void SetShared(IDiagnosticsLogger? logger) =>
        Shared = logger ?? new DiagnosticsLogger(settings: null);

    public string? CurrentSessionFilePath
    {
        get { lock (_gate) { return _filePath; } }
    }

    /// <summary>The opt-in gate. False when no settings are wired and no override is set, so a
    /// logger constructed before the composition root is inert rather than chatty.</summary>
    public bool Enabled => _enabledOverride ?? _settings?.DiagnosticsEnabled ?? false;

    /// <summary>The default per-user log directory.</summary>
    public static string DefaultLogDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ClaudeBatteryWin",
        "Logs");

    public void EmitMilestone(string kind, Func<IDictionary<string, object?>> payload)
    {
        if (!Enabled)
        {
            return;
        }

        string line;
        try
        {
            line = SecretRedactor.Redact(Serialize(kind, payload()));
        }
        catch (Exception ex)
        {
            // A producer's payload delegate itself threw. Record that it happened, never the reason,
            // which could quote a value.
            DebugLog($"[payload-failed] {kind}: {ex.GetType().Name}");
            line = SecretRedactor.Redact(Serialize("payload-failed", new Dictionary<string, object?>
            {
                ["failed_kind"] = kind
            }));
        }

        lock (_gate)
        {
            EnsureSessionStartedLocked();
            WriteLineLocked(line);
        }
    }

    public void Flush()
    {
        if (!Enabled)
        {
            return;
        }

        EmitMilestone("session-end", () => new Dictionary<string, object?>());

        lock (_gate)
        {
            try
            {
                _file?.Flush(flushToDisk: true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ObjectDisposedException)
            {
                DebugLog("[flush-failed] final flush skipped");
            }
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            try
            {
                _file?.Dispose();
            }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException)
            {
            }
            _file = null;
        }
    }

    // --- File lifecycle ------------------------------------------------------------------------

    private void EnsureSessionStartedLocked()
    {
        if (_didStartSession)
        {
            return;
        }

        var dir = _directoryOverride ?? DefaultLogDirectory;
        try
        {
            Directory.CreateDirectory(dir);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            // Log once, leave the session unstarted: a transient failure must never latch logging
            // off for the rest of the launch.
            if (!_loggedOpenFailure)
            {
                _loggedOpenFailure = true;
                DebugLog($"[open-failed] diagnostic log file could not be opened under {LogDirectoryLabel}");
            }
            return;
        }

        var name = $"diag-{DateTime.UtcNow.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)}-{_launchToken}.jsonl";
        var path = Path.Combine(dir, name);

        try
        {
            _file = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            if (!_loggedOpenFailure)
            {
                _loggedOpenFailure = true;
                DebugLog($"[open-failed] diagnostic log file could not be opened under {LogDirectoryLabel}");
            }
            return;
        }

        _didStartSession = true;
        _loggedOpenFailure = false;
        _filePath = path;

        PruneOldLogs(dir, keeping: path, retentionDays: RetentionDays);

        WriteLineLocked(SecretRedactor.Redact(Serialize("path-resolved", new Dictionary<string, object?>
        {
            ["file"] = name,
            ["dir"] = LogDirectoryLabel,
            ["directoryOverride"] = _directoryOverride is null ? "(none)" : "(set)"
        })));

        WriteLineLocked(SecretRedactor.Redact(Serialize("session-start", new Dictionary<string, object?>
        {
            ["version"] = AppVersionInfo.Version,
            ["build"] = AppVersionInfo.Build,
            ["windows"] = SafeOsDescription(),
            ["locale"] = CultureInfo.CurrentCulture.Name,
            ["appId"] = "com.reebz.claudebatterywin"
        })));
    }

    private static string SafeOsDescription()
    {
        try
        {
            return RuntimeInformation.OSDescription;
        }
        catch (Exception)
        {
            return "(unknown)";
        }
    }

    /// <summary>
    /// Removes log files older than the retention window. The file this launch just opened is
    /// excluded by path, and each delete is caught on its own so one locked file cannot stop the
    /// rest.
    /// </summary>
    internal static void PruneOldLogs(string directory, string keeping, int retentionDays = RetentionDays)
    {
        string[] entries;
        try
        {
            entries = Directory.GetFiles(directory);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or DirectoryNotFoundException)
        {
            return;
        }

        var cutoff = DateTime.UtcNow.AddDays(-retentionDays);
        var keepFull = SafeFullPath(keeping);

        foreach (var entry in entries)
        {
            var name = Path.GetFileName(entry);
            if (!name.StartsWith("diag-", StringComparison.Ordinal) || !name.EndsWith(".jsonl", StringComparison.Ordinal))
            {
                continue;
            }
            if (string.Equals(SafeFullPath(entry), keepFull, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            try
            {
                if (File.GetLastWriteTimeUtc(entry) < cutoff)
                {
                    File.Delete(entry);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    private static string SafeFullPath(string path)
    {
        try
        {
            return Path.GetFullPath(path);
        }
        catch (Exception)
        {
            return path;
        }
    }

    /// <summary>
    /// Appends one line and forces it to disk, so a crash immediately after a write still keeps that
    /// line. A failed write drops the handle: later milestones degrade to the debug sink rather than
    /// hammering a broken file every time.
    /// </summary>
    private void WriteLineLocked(string line)
    {
        if (_file is null)
        {
            DebugLog($"[file-unavailable] {line}");
            return;
        }

        try
        {
            var bytes = Encoding.UTF8.GetBytes(line + "\n");
            _file.Write(bytes, 0, bytes.Length);
            _file.Flush(flushToDisk: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ObjectDisposedException)
        {
            DebugLog($"[write-failed] {ex.GetType().Name}");
            try
            {
                _file.Dispose();
            }
            catch (Exception disposeEx) when (disposeEx is IOException or ObjectDisposedException)
            {
            }
            _file = null;
        }
    }

    // --- Serialization -------------------------------------------------------------------------

    /// <summary>
    /// Builds the line: <c>{"ts":...,"kind":...,"payload":{...}}</c>. A payload the JSON writer
    /// cannot handle falls back to a record that keeps the original kind and the payload's key names
    /// but none of its values, because a key name is safe by the producer contract and a value is not.
    /// </summary>
    internal static string Serialize(string kind, IDictionary<string, object?> payload)
    {
        try
        {
            var entry = new JsonObject
            {
                ["ts"] = Timestamp(),
                ["kind"] = kind,
                ["payload"] = ToNode(payload)
            };
            return entry.ToJsonString();
        }
        catch (Exception ex) when (ex is JsonException or NotSupportedException or InvalidOperationException or ArgumentException)
        {
            try
            {
                var keys = string.Join(",", payload.Keys.OrderBy(k => k, StringComparer.Ordinal));
                var fallback = new JsonObject
                {
                    ["ts"] = Timestamp(),
                    ["kind"] = "serialize-failed",
                    ["payload"] = new JsonObject
                    {
                        ["failed_kind"] = kind,
                        ["keys"] = keys
                    }
                };
                return fallback.ToJsonString();
            }
            catch (Exception)
            {
                return "{\"kind\":\"serialize-failed\"}";
            }
        }
    }

    private static string Timestamp() =>
        DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fffK", CultureInfo.InvariantCulture);

    /// <summary>How deep a payload may nest. A payload that refers to itself would otherwise
    /// recurse until the process dies, which a try/catch cannot save; past this depth the build
    /// throws and the caller falls back to the keys-only record.</summary>
    private const int MaxPayloadDepth = 32;

    private static JsonNode? ToNode(object? value, int depth = 0)
    {
        if (depth > MaxPayloadDepth)
        {
            throw new JsonException("payload nests deeper than the diagnostics envelope allows");
        }

        return value switch
        {
            null => null,
            JsonNode node => node.DeepClone(),
            IDictionary<string, object?> dict => DictionaryNode(dict, depth + 1),
            string s => JsonValue.Create(s),
            bool b => JsonValue.Create(b),
            int i => JsonValue.Create(i),
            long l => JsonValue.Create(l),
            double d => JsonValue.Create(d),
            decimal m => JsonValue.Create(m),
            System.Collections.IEnumerable list => ArrayNode(list, depth + 1),
            _ => JsonSerializer.SerializeToNode(value)
        };
    }

    private static JsonNode DictionaryNode(IDictionary<string, object?> dict, int depth)
    {
        var obj = new JsonObject();
        foreach (var pair in dict)
        {
            obj[pair.Key] = ToNode(pair.Value, depth);
        }
        return obj;
    }

    private static JsonNode ArrayNode(System.Collections.IEnumerable list, int depth)
    {
        var array = new JsonArray();
        foreach (var element in list)
        {
            array.Add(ToNode(element, depth));
        }
        return array;
    }

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[DiagnosticsLogger] {message}");
}
