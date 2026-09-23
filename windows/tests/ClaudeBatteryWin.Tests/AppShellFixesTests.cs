using System.IO;
using System.Net;
using System.Windows.Threading;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// The composition-root helpers behind the app-shell review fixes: the poller's measurement write
/// hops to the UI thread (F1), an unchanged User-Agent keeps the transport (F2), the previous
/// version's crash log survives an update (F3) redacted again (review F2), and a long stack trace
/// keeps its frames while still being redacted, a key and its value on neighbouring lines included
/// (F4, review F3).
///
/// Each test that touches the disk gets its own temp directory. The AccountStore test uses real
/// DPAPI, so like AccountStoreTests it runs on the Windows CI host.
/// </summary>
public sealed class AppShellFixesTests : IDisposable
{
    private readonly string _root;

    public AppShellFixesTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "cbw-appshell-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_root))
            {
                Directory.Delete(_root, recursive: true);
            }
        }
        catch (IOException)
        {
            // Best-effort temp cleanup.
        }
    }

    // --- F1: off-thread AccountStore writes --------------------------------------------------------

    [WpfFact]
    public async Task PostToUiThread_FromAPoolThread_RunsOnTheDispatcherThread()
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        var uiThread = Environment.CurrentManagedThreadId;
        var ranOn = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);

        var posted = await Task.Run(() =>
            App.PostToUiThread(dispatcher, () => ranOn.TrySetResult(Environment.CurrentManagedThreadId)));

        Assert.True(posted);
        Assert.Equal(uiThread, await ranOn.Task.WaitAsync(TimeSpan.FromSeconds(10)));
    }

    [Fact]
    public void PostToUiThread_AfterDispatcherShutdown_DropsTheAction()
    {
        Dispatcher? dispatcher = null;
        using var ready = new ManualResetEventSlim();
        var thread = new Thread(() =>
        {
            dispatcher = Dispatcher.CurrentDispatcher;
            ready.Set();
            Dispatcher.Run();
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(ready.Wait(TimeSpan.FromSeconds(10)));

        var shutDown = dispatcher!;
        shutDown.InvokeShutdown();
        Assert.True(thread.Join(TimeSpan.FromSeconds(10)));

        var ran = false;
        Assert.False(App.PostToUiThread(shutDown, () => ran = true));
        Assert.False(ran);
    }

    [WpfFact]
    public async Task PersistMeasurement_FromAPoolThread_WritesTheStoreOnTheUiThread()
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        var uiThread = Environment.CurrentManagedThreadId;
        var store = new AccountStore(
            new CookieContainer(), new SecretStore(Path.Combine(_root, "secrets")), Path.Combine(_root, "accounts.json"));
        Assert.True(store.UpsertAccount(new Account
        {
            Email = "user-org-1@example.com",
            SessionKey = "sk-org-1",
            OrganizationId = "org-1",
        }));
        var id = store.Accounts[0].Id;
        var measurement = RatioMeasurement.Updated(null, 100, null, 63, null);

        var afterWriteThread = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        var persist = App.PersistMeasurementOnUiThread(
            dispatcher, () => store, () => afterWriteThread.TrySetResult(Environment.CurrentManagedThreadId));

        // The poller calls this from a pool thread, as UsageService does after a successful poll.
        await Task.Run(() => persist(id, measurement));

        Assert.Equal(uiThread, await afterWriteThread.Task.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(measurement, store.Accounts[0].RatioMeasurement);
    }

    [WpfFact]
    public async Task PersistMeasurement_WithTheStoreGone_DoesNothingAndDoesNotThrow()
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        var afterWrite = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var persist = App.PersistMeasurementOnUiThread(dispatcher, () => null, () => afterWrite.TrySetResult());

        await Task.Run(() => persist(Guid.NewGuid(), RatioMeasurement.Updated(null, 100, null, 63, null)));

        await afterWrite.Task.WaitAsync(TimeSpan.FromSeconds(10));
    }

    // --- F2: the transport is rebuilt only when the User-Agent changes -----------------------------

    [Fact]
    public void ShouldRebuildTransport_SameUserAgent_KeepsTheTransport()
    {
        const string ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Edg/124.0.0.0";
        Assert.False(App.ShouldRebuildTransport(ua, ua));
    }

    [Theory]
    [InlineData("Mozilla/5.0 Edg/124.0.0.0", "Mozilla/5.0 Edg/125.0.0.0")]
    [InlineData("Mozilla/5.0 Edg/124.0.0.0", "mozilla/5.0 edg/124.0.0.0")] // ordinal: case counts
    [InlineData(null, "Mozilla/5.0 Edg/124.0.0.0")]
    public void ShouldRebuildTransport_DifferentUserAgent_Rebuilds(string? current, string next)
    {
        Assert.True(App.ShouldRebuildTransport(current, next));
    }

    // --- F3: the previous version's crash log survives an update -----------------------------------

    private string CrashLog => Path.Combine(_root, "crash.log");
    private string PreviousCrashLog => Path.Combine(_root, App.PreviousCrashLogFileName);
    private string Marker => Path.Combine(_root, "crash-log-redacted.marker");

    [Fact]
    public void PrepareCrashLog_AfterAnUpdate_KeepsThePreviousVersionsLog()
    {
        File.WriteAllText(Marker, "1.71.0");
        File.WriteAllText(CrashLog, "==== old crash ====\r\nat Frame()\r\n\r\n");

        App.PrepareCrashLog(_root, "1.72.0");

        Assert.Equal("==== old crash ====\r\nat Frame()\r\n\r\n", File.ReadAllText(PreviousCrashLog));
        Assert.False(File.Exists(CrashLog)); // the smoke job fails on a crash.log that exists
        Assert.Equal("1.72.0", File.ReadAllText(Marker));
    }

    [Fact]
    public void PrepareCrashLog_AfterAnUpdate_TheNewestPreviousLogReplacesTheOlderOne()
    {
        File.WriteAllText(Marker, "1.71.0");
        File.WriteAllText(PreviousCrashLog, "from 1.70");
        File.WriteAllText(CrashLog, "from 1.71");

        App.PrepareCrashLog(_root, "1.72.0");

        // One generation is kept, so the pair of files stays bounded.
        Assert.Equal("from 1.71", File.ReadAllText(PreviousCrashLog));
    }

    [Fact]
    public void PrepareCrashLog_AfterAnUpdate_RedactsRawTextAnOlderBetaAddedToTheKeptLog()
    {
        // Review F2: 1.72.0 ran (marker "1.72.0"), then an old pre-redaction beta crashed and
        // appended a raw block without touching the marker. Keeping the log across the next update
        // must not keep that raw text.
        var redactedBlock = App.FormatCrashEntry(
            DateTimeOffset.UnixEpoch, "1.72.0", "dispatcher",
            new LongTraceException("System.Exception: boom sessionKey=abc123\r\n   at A()"));
        const string rawHeader = "==== 2026-09-01T10:00:00.0000000+10:00 ClaudeBatteryWin v1.50.4-beta [dispatcher] ====";
        var rawBlock = rawHeader + "\r\n"
            + "System.IO.IOException: C:\\Users\\alice\\AppData\\Local\\x.json is locked\r\n"
            + "   org 3f2a8c1e-1234-4abc-9def-0123456789ab sessionKey=rawsecret99\r\n\r\n";
        File.WriteAllText(Marker, "1.72.0");
        File.WriteAllText(CrashLog, redactedBlock + rawBlock);

        App.PrepareCrashLog(_root, "1.72.1");

        var kept = File.ReadAllText(PreviousCrashLog);
        Assert.DoesNotContain("alice", kept);
        Assert.DoesNotContain("3f2a8c1e-1234-4abc-9def-0123456789ab", kept);
        Assert.DoesNotContain("rawsecret99", kept);
        Assert.StartsWith(redactedBlock, kept); // already-redacted text comes through unchanged
        Assert.Contains(rawHeader, kept);
        Assert.False(File.Exists(CrashLog));
        Assert.Equal("1.72.1", File.ReadAllText(Marker));
    }

    [Fact]
    public void PrepareCrashLog_AfterAnUpdate_KeepsAFullLogWithoutCuttingIt()
    {
        // The per-block total cap must not apply to the kept file: a full log is well over 32 KB.
        var blocks = new System.Text.StringBuilder();
        for (var i = 0; i < App.MaxCrashEntries; i++)
        {
            blocks.Append($"==== block {i:D2} ====\r\n")
                .Append(LongTrace(frames: 30, secretLine: "   plain line", secretAtFrame: 0))
                .Append("\r\n\r\n");
        }
        Assert.True(blocks.Length > App.MaxCrashTextLength);
        File.WriteAllText(Marker, "1.72.0");
        File.WriteAllText(CrashLog, blocks.ToString());

        App.PrepareCrashLog(_root, "1.72.1");

        var kept = File.ReadAllText(PreviousCrashLog);
        Assert.DoesNotContain("TRUNCATED", kept);
        Assert.Equal(blocks.ToString(), kept);
    }

    [Fact]
    public void PrepareCrashLog_AnEmptyLog_DoesNotReplaceTheKeptOne()
    {
        File.WriteAllText(Marker, "1.71.0");
        File.WriteAllText(PreviousCrashLog, "from 1.70");
        File.WriteAllText(CrashLog, string.Empty);

        App.PrepareCrashLog(_root, "1.72.0");

        Assert.Equal("from 1.70", File.ReadAllText(PreviousCrashLog));
    }

    [Fact]
    public void PrepareCrashLog_NoMarker_ClearsTheUnredactedLogAndKeepsNothing()
    {
        // No marker means a beta from before redaction wrote this log (U2): it must not be kept.
        File.WriteAllText(CrashLog, "Cookie: sessionKey=sk-ant-raw");

        App.PrepareCrashLog(_root, "1.72.0");

        Assert.Equal(string.Empty, File.ReadAllText(CrashLog));
        Assert.False(File.Exists(PreviousCrashLog));
        Assert.Equal("1.72.0", File.ReadAllText(Marker));
    }

    [Fact]
    public void PrepareCrashLog_SameVersion_LeavesEverythingAlone()
    {
        File.WriteAllText(Marker, "1.72.0");
        File.WriteAllText(CrashLog, "this version's crash");

        App.PrepareCrashLog(_root, "1.72.0");

        Assert.Equal("this version's crash", File.ReadAllText(CrashLog));
        Assert.False(File.Exists(PreviousCrashLog));
    }

    [Fact]
    public void PrepareCrashLog_FreshMachine_CreatesNoCrashLog()
    {
        App.PrepareCrashLog(_root, "1.72.0");

        Assert.False(File.Exists(CrashLog));
        Assert.False(File.Exists(PreviousCrashLog));
        Assert.Equal("1.72.0", File.ReadAllText(Marker));
    }

    // --- F4: a long stack trace keeps its frames and is still redacted -----------------------------

    /// <summary>An exception whose text is a long multi-line trace, as a deep async stack produces.</summary>
    private sealed class LongTraceException : Exception
    {
        private readonly string _text;

        public LongTraceException(string text) => _text = text;

        public override string ToString() => _text;
    }

    private static string LongTrace(int frames, string secretLine, int secretAtFrame)
    {
        var lines = new List<string> { "System.InvalidOperationException: poll failed" };
        for (var i = 0; i < frames; i++)
        {
            if (i == secretAtFrame)
            {
                lines.Add(secretLine);
            }
            lines.Add($"   at ClaudeBatteryWin.Services.UsageService.Frame{i:D4}() in UsageService.cs:line {i}");
        }
        return string.Join("\r\n", lines);
    }

    [Fact]
    public void FormatCrashEntry_LongMultiLineTrace_KeepsLateFramesAndRedactsTheSessionKey()
    {
        // Well past the redactor's 4,096-character per-call cap, with the secret past it too.
        var text = LongTrace(frames: 200, secretLine: "Cookie: sessionKey=sk-ant-sid01-NEEDLEVALUE; theme=dark", secretAtFrame: 150);
        Assert.True(text.Length > 4096 * 2);

        var entry = App.FormatCrashEntry(DateTimeOffset.UnixEpoch, "1.72.0", "dispatcher", new LongTraceException(text));

        Assert.Contains("Frame0000()", entry);
        Assert.Contains("Frame0199()", entry); // the last frame survives
        Assert.DoesNotContain("TRUNCATED", entry);
        Assert.DoesNotContain("NEEDLEVALUE", entry);
        Assert.DoesNotContain("sk-ant-sid01", entry);
        Assert.Contains("theme=dark", entry); // a non-secret cookie on the same line is kept
    }

    [Fact]
    public void RedactCrashText_KeepsCrLfLineEndings()
    {
        var text = "line one\r\n   at Frame()\r\nlast";
        Assert.Equal(text, App.RedactCrashText(text));
    }

    [Fact]
    public void RedactCrashText_MatchesTheSingleCallOnAShortTrace()
    {
        // Under the per-call cap, chunked redaction gives the same result as one call.
        var text = "System.Exception: boom sessionKey=abc123\n   at A()\n   at B() in C:\\Users\\someone\\x.cs";
        Assert.Equal(SecretRedactor.Redact(text), App.RedactCrashText(text));
    }

    [Theory]
    [InlineData("token:\nsecretvalue1", "secretvalue1")]
    [InlineData("Bearer\nsecretvalue2", "secretvalue2")]
    [InlineData("password:\r\nhunter2secret", "hunter2secret")]
    [InlineData("token =\r\nabc123def", "abc123def")]
    [InlineData("Authorization:\nBasic Zm9vOmJhcg==", "Zm9vOmJhcg")]
    public void RedactCrashText_AKeyAndItsValueOnNeighbouringLines_IsRedacted(string pair, string secret)
    {
        // Review F3: these patterns match across a line break, so the key and the value must reach
        // the redactor in the same call. The result matches the single call the text replaced.
        var text = "System.Exception: dump\r\n" + pair + "\r\n   at A()";

        var redacted = App.RedactCrashText(text);

        Assert.DoesNotContain(secret, redacted);
        Assert.Contains("at A()", redacted);
        Assert.Equal(SecretRedactor.Redact(text), redacted);
    }

    [Fact]
    public void RedactCrashText_AKeyAtTheEndOfAChunk_TravelsWithItsValue()
    {
        // Review F3: "password:" is the last line that fits under the per-call cap and its value is
        // the first line past it. The key line is handed on to the next chunk with its value.
        const string keyLine = "password:\r\n";
        var filler = new string('x', SecretRedactor.MaxRedactInputLength - keyLine.Length - 2) + "\r\n";
        var text = filler + keyLine + "hunter2secret\r\n   at A()";
        Assert.Equal(SecretRedactor.MaxRedactInputLength, filler.Length + keyLine.Length);

        var redacted = App.RedactCrashText(text);

        Assert.DoesNotContain("hunter2secret", redacted);
        Assert.DoesNotContain("TRUNCATED", redacted);
        Assert.StartsWith(filler + keyLine, redacted);
        Assert.EndsWith("   at A()", redacted);
    }

    [Fact]
    public void RedactCrashText_HugeTrace_IsBoundedAndMarked()
    {
        var text = LongTrace(frames: 5000, secretLine: "sessionKey=hidden", secretAtFrame: 10);

        var redacted = App.RedactCrashText(text);

        Assert.True(redacted.Length < App.MaxCrashTextLength + 4096 + 64, $"{redacted.Length} chars");
        Assert.EndsWith(App.CrashTextTruncatedMarker, redacted);
        Assert.DoesNotContain("sessionKey=hidden", redacted);
    }
}
