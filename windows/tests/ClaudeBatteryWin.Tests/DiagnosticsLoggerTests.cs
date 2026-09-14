using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// The opt-in diagnostics logger (U2). The first thing proven here is that it does nothing at all
/// when the toggle is off: no file, no directory, not even a built payload. Everything after that
/// covers the file lifecycle - one file per launch, two preamble records, retention, and the
/// degrade-to-nothing behaviour when the directory cannot be opened.
/// </summary>
public class DiagnosticsLoggerTests : IDisposable
{
    private readonly string _dir = Path.Combine(
        Path.GetTempPath(), "cbw-diag-tests-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_dir))
            {
                Directory.Delete(_dir, recursive: true);
            }
        }
        catch (IOException)
        {
        }
    }

    private DiagnosticsLogger EnabledLogger() => new(settings: null, directoryOverride: _dir, enabledOverride: true);

    private DiagnosticsLogger DisabledLogger() => new(settings: null, directoryOverride: _dir, enabledOverride: false);

    private static Func<IDictionary<string, object?>> Payload(params (string Key, object? Value)[] pairs) =>
        () => pairs.ToDictionary(p => p.Key, p => p.Value);

    /// <summary>
    /// Reads a log file the logger still has open for append. Windows refuses the plain read helpers
    /// against a file another handle is writing, so the share flags have to say so explicitly.
    /// </summary>
    private static string ReadWhileOpen(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    private static string[] LinesOf(string path) =>
        ReadWhileOpen(path).Split('\n', StringSplitOptions.RemoveEmptyEntries);

    private string[] Lines()
    {
        var files = Directory.GetFiles(_dir, "diag-*.jsonl");
        Assert.Single(files);
        return LinesOf(files[0]);
    }

    private static JsonNode Parse(string line) => JsonNode.Parse(line)!;

    // --- The gate ------------------------------------------------------------------------------

    [Fact]
    public void Disabled_WritesNothingAndCreatesNoDirectory()
    {
        var logger = DisabledLogger();
        var built = 0;

        for (var i = 0; i < 5; i++)
        {
            logger.EmitMilestone("plan-sample", () =>
            {
                built++;
                return new Dictionary<string, object?> { ["x"] = 1 };
            });
        }

        Assert.False(Directory.Exists(_dir));
        Assert.Null(logger.CurrentSessionFilePath);
        Assert.Equal(0, built); // the payload delegate is never even invoked
        Assert.Empty(LogsExporter.EligibleLogFiles(_dir, DateTimeOffset.MinValue));
    }

    [Fact]
    public void Enabled_CreatesMissingDirectoryOnFirstEmit()
    {
        Assert.False(Directory.Exists(_dir));
        EnabledLogger().EmitMilestone("probe", Payload(("x", 1)));
        Assert.True(Directory.Exists(_dir));
    }

    // --- Preamble records ----------------------------------------------------------------------

    [Fact]
    public void FirstEmit_WritesPathResolvedThenSessionStartThenTheProducersRecord()
    {
        EnabledLogger().EmitMilestone("probe", Payload(("x", 1)));

        var lines = Lines();
        Assert.Equal("path-resolved", (string?)Parse(lines[0])["kind"]);
        Assert.Equal("session-start", (string?)Parse(lines[1])["kind"]);
        Assert.Equal("probe", (string?)Parse(lines[2])["kind"]);
    }

    [Fact]
    public void PathResolved_NamesTheFileWithoutTheAbsolutePath()
    {
        var logger = EnabledLogger();
        logger.EmitMilestone("probe", Payload(("x", 1)));

        var lines = Lines();
        var payload = Parse(lines[0])["payload"]!;

        Assert.Null(payload["path"]);
        Assert.Equal(Path.GetFileName(logger.CurrentSessionFilePath!), (string?)payload["file"]);
        Assert.Equal("(set)", (string?)payload["directoryOverride"]);
        Assert.Equal(DiagnosticsLogger.LogDirectoryLabel, (string?)payload["dir"]);

        // The resolved directory names the Windows account, so it is never written.
        Assert.DoesNotContain(_dir, lines[0], StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SessionStart_IsWrittenOnlyOnce()
    {
        var logger = EnabledLogger();
        for (var i = 0; i < 5; i++)
        {
            logger.EmitMilestone("probe", Payload(("i", i)));
        }

        Assert.Single(Lines().Where(l => (string?)Parse(l)["kind"] == "session-start"));
    }

    [Fact]
    public void EachLaunchWritesItsOwnFile_NoCrossLaunchAppend()
    {
        var first = EnabledLogger();
        first.EmitMilestone("first-launch", Payload(("x", 1)));
        var second = EnabledLogger();
        second.EmitMilestone("second-launch", Payload(("x", 2)));

        Assert.NotEqual(first.CurrentSessionFilePath, second.CurrentSessionFilePath);
        Assert.DoesNotContain("first-launch", ReadWhileOpen(second.CurrentSessionFilePath!), StringComparison.Ordinal);
        Assert.Equal(2, LogsExporter.EligibleLogFiles(_dir, DateTimeOffset.MinValue).Count);
    }

    // --- Redaction at the chokepoint -----------------------------------------------------------

    [Fact]
    public void Emit_RedactsSecretValuesBeforeWrite()
    {
        EnabledLogger().EmitMilestone("planted", Payload(
            ("sessionKey", "sk-ant-LOGGERSECRET"),
            ("note", "account for victim@example.com"),
            ("__cf_bm", "cfbmRAWVALUE")));

        var text = ReadWhileOpen(Directory.GetFiles(_dir, "diag-*.jsonl")[0]);
        Assert.DoesNotContain("sk-ant-LOGGERSECRET", text, StringComparison.Ordinal);
        Assert.DoesNotContain("victim@example.com", text, StringComparison.Ordinal);
        Assert.DoesNotContain("cfbmRAWVALUE", text, StringComparison.Ordinal);
        Assert.Contains("REDACTED_LEN_", text, StringComparison.Ordinal);
    }

    [Fact]
    public void ExceptionMessageWithUserPath_HasItsAccountNameReplaced()
    {
        EnabledLogger().EmitMilestone("io-failed", Payload(
            ("message", "Could not find C:\\Users\\someone\\AppData\\Local\\ClaudeBatteryWin\\x.json")));

        var text = ReadWhileOpen(Directory.GetFiles(_dir, "diag-*.jsonl")[0]);
        Assert.DoesNotContain("someone", text, StringComparison.Ordinal);
        Assert.Contains("[USER]", text, StringComparison.Ordinal);
    }

    // --- Serialization -------------------------------------------------------------------------

    [Fact]
    public void Serialize_ProducesTheEnvelopeShape()
    {
        var node = Parse(DiagnosticsLogger.Serialize("probe", new Dictionary<string, object?> { ["a"] = 1 }));

        Assert.Equal("probe", (string?)node["kind"]);
        Assert.NotNull(node["ts"]);
        Assert.Equal(1, (int?)node["payload"]!["a"]);
    }

    [Fact]
    public void SerializeFailed_PreservesKindAndKeysButNoValues()
    {
        // A value the JSON writer cannot handle: this object refers to itself.
        var cyclic = new Dictionary<string, object?>();
        cyclic["self"] = cyclic;

        var line = DiagnosticsLogger.Serialize("original-kind", new Dictionary<string, object?>
        {
            ["count"] = cyclic,
            ["when"] = "SENSITIVEVALUE"
        });

        var node = Parse(line);
        Assert.Equal("serialize-failed", (string?)node["kind"]);
        Assert.Equal("original-kind", (string?)node["payload"]!["failed_kind"]);
        Assert.Equal("count,when", (string?)node["payload"]!["keys"]);
        Assert.DoesNotContain("SENSITIVEVALUE", line, StringComparison.Ordinal);
    }

    [Fact]
    public void SerializeFailed_WithControlCharsInKindAndKeys_IsValidJson()
    {
        var cyclic = new Dictionary<string, object?>();
        cyclic["self"] = cyclic;

        var line = DiagnosticsLogger.Serialize("ki\tnd\u0001", new Dictionary<string, object?>
        {
            ["ke\ty"] = cyclic
        });

        var node = JsonNode.Parse(line);
        Assert.NotNull(node);
        Assert.Equal("serialize-failed", (string?)node!["kind"]);
        Assert.NotNull(node["payload"]!["failed_kind"]);
        Assert.NotNull(node["payload"]!["keys"]);
    }

    [Fact]
    public void EveryLine_IsValidJson()
    {
        var logger = EnabledLogger();
        for (var i = 0; i < 100; i++)
        {
            logger.EmitMilestone("bulk", Payload(("i", i)));
        }

        var lines = Lines();
        Assert.Equal(102, lines.Length); // two preamble records plus one hundred milestones
        foreach (var line in lines)
        {
            Assert.NotNull(JsonNode.Parse(line));
        }
    }

    [Fact]
    public void ConcurrentEmits_ProduceWellFormedLines()
    {
        var logger = EnabledLogger();
        Parallel.For(0, 50, i => logger.EmitMilestone("concurrent", Payload(("i", i))));

        foreach (var line in Lines())
        {
            Assert.NotNull(JsonNode.Parse(line));
        }
    }

    // --- Session end ---------------------------------------------------------------------------

    [Fact]
    public void Flush_WritesSessionEndWithAnEmptyPayload()
    {
        var logger = EnabledLogger();
        logger.EmitMilestone("probe", Payload(("x", 1)));
        logger.Flush();

        var last = Parse(Lines()[^1]);
        Assert.Equal("session-end", (string?)last["kind"]);
        Assert.Empty(last["payload"]!.AsObject());
    }

    [Fact]
    public void Flush_WhenDisabled_WritesNothing()
    {
        DisabledLogger().Flush();
        Assert.False(Directory.Exists(_dir));
    }

    // --- Retention -----------------------------------------------------------------------------

    [Fact]
    public void OldDiagFiles_ArePrunedWhenASessionStarts()
    {
        Directory.CreateDirectory(_dir);
        var stale = Path.Combine(_dir, "diag-2000-01-01-oldtoken.jsonl");
        File.WriteAllText(stale, "{}\n");
        File.SetLastWriteTimeUtc(stale, new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc));

        var recent = Path.Combine(_dir, "diag-2000-01-02-recent.jsonl");
        File.WriteAllText(recent, "{}\n");

        var stray = Path.Combine(_dir, "notes.txt");
        File.WriteAllText(stray, "keep me");
        File.SetLastWriteTimeUtc(stray, new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc));

        var logger = EnabledLogger();
        logger.EmitMilestone("probe", Payload(("x", 1)));

        Assert.False(File.Exists(stale));
        Assert.True(File.Exists(recent));       // inside the retention window
        Assert.True(File.Exists(stray));        // not a diag file, never touched
        Assert.True(File.Exists(logger.CurrentSessionFilePath!));
    }

    [Fact]
    public void Retention_LeavesTheCurrentFileAloneWhileItIsOpen()
    {
        Directory.CreateDirectory(_dir);
        var logger = EnabledLogger();
        logger.EmitMilestone("probe", Payload(("x", 1)));
        var current = logger.CurrentSessionFilePath!;

        // Backdate the current file past the retention window, then prune with it as the keeper.
        File.SetLastWriteTimeUtc(current, new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc));
        DiagnosticsLogger.PruneOldLogs(_dir, keeping: current);

        Assert.True(File.Exists(current));
    }

    [Fact]
    public void Retention_OneUndeletableFileDoesNotStopTheRest()
    {
        Directory.CreateDirectory(_dir);
        var epoch = new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        var locked = Path.Combine(_dir, "diag-2000-01-01-locked.jsonl");
        File.WriteAllText(locked, "{}\n");
        File.SetLastWriteTimeUtc(locked, epoch);

        var deletable = Path.Combine(_dir, "diag-2000-01-01-other.jsonl");
        File.WriteAllText(deletable, "{}\n");
        File.SetLastWriteTimeUtc(deletable, epoch);

        using (var hold = new FileStream(locked, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            DiagnosticsLogger.PruneOldLogs(_dir, keeping: Path.Combine(_dir, "diag-current.jsonl"));
        }

        Assert.False(File.Exists(deletable));
    }

    // --- Failure to open -----------------------------------------------------------------------

    [Fact]
    public void OpenFailure_DoesNotCrashAndRetriesOnALaterEmit()
    {
        // The parent of the log directory is a regular file, so creating the directory must fail.
        var blocker = Path.Combine(Path.GetTempPath(), "cbw-diag-blocker-" + Guid.NewGuid().ToString("N"));
        File.WriteAllText(blocker, "not a directory");
        try
        {
            var logger = new DiagnosticsLogger(
                settings: null,
                directoryOverride: Path.Combine(blocker, "Logs"),
                enabledOverride: true);

            logger.EmitMilestone("probe", Payload(("x", 1)));
            Assert.Null(logger.CurrentSessionFilePath);

            logger.EmitMilestone("probe", Payload(("x", 2)));
            Assert.Null(logger.CurrentSessionFilePath); // still no false path, never latched off
        }
        finally
        {
            File.Delete(blocker);
        }
    }

    // --- accounts.json is never a diagnostics artifact -----------------------------------------

    [Fact]
    public void AccountsFileInTheLogDirectory_IsNeverEligible()
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(Path.Combine(_dir, "accounts.json"), "[{\"sessionKey\":\"sk-ant-ACCOUNTSSECRET\"}]");
        File.WriteAllText(Path.Combine(_dir, "crash.log"), "sessionKey=sk-ant-CRASHSECRET");

        Assert.Empty(LogsExporter.EligibleLogFiles(_dir, DateTimeOffset.MinValue));
    }
}
