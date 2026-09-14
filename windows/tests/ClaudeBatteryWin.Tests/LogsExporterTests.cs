using System.IO;
using System.IO.Compression;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// The diagnostics export (U2, R57). Two rules carry the safety and both are checked here: only
/// <c>diag-*.jsonl</c> is ever eligible, whatever a neighbouring file contains, and a file already at
/// the destination is either fully replaced or left exactly as it was.
/// </summary>
public class LogsExporterTests : IDisposable
{
    private readonly string _dir = Path.Combine(
        Path.GetTempPath(), "cbw-export-tests-" + Guid.NewGuid().ToString("N"));

    private static readonly DateTimeOffset Install = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset Now = new(2026, 9, 14, 10, 30, 0, TimeSpan.Zero);

    public LogsExporterTests() => Directory.CreateDirectory(_dir);

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

    private string WriteFile(string name, string content, DateTimeOffset? modified = null)
    {
        var path = Path.Combine(_dir, name);
        File.WriteAllText(path, content);
        File.SetLastWriteTimeUtc(path, (modified ?? Install.AddDays(1)).UtcDateTime);
        return path;
    }

    // --- Eligibility ---------------------------------------------------------------------------

    [Theory]
    [InlineData("diag-2026-09-14-abcd1234.jsonl", true)]
    [InlineData("diag-backup.zip", false)]
    [InlineData("notes.txt", false)]
    [InlineData("crash.log", false)]
    [InlineData("accounts.json", false)]
    [InlineData("oslogstore-2026-06-03T00-00-00Z.txt", false)]
    public void IsEligibleName_AcceptsOnlyDiagJsonl(string name, bool expected) =>
        Assert.Equal(expected, LogsExporter.IsEligibleName(name));

    [Fact]
    public void Eligible_IncludesOnlyPostInstallDiagJsonl()
    {
        WriteFile("diag-2026-09-13-aaaa.jsonl", "{}");
        WriteFile("diag-2026-09-14-bbbb.jsonl", "{}");
        WriteFile("diag-2025-01-01-old.jsonl", "{}", Install.AddDays(-5));
        WriteFile("notes.txt", "x");
        WriteFile("diag-backup.zip", "x");

        var eligible = LogsExporter.EligibleLogFiles(_dir, Install);

        Assert.Equal(
            new[] { "diag-2026-09-13-aaaa.jsonl", "diag-2026-09-14-bbbb.jsonl" },
            eligible.Select(Path.GetFileName).ToArray());
    }

    [Fact]
    public void Eligible_AlwaysExcludesUncontrolledDumps_EvenPostInstall()
    {
        // Name alone decides. A dump of uncontrolled log content is excluded whatever its age and
        // whatever it holds, rather than being trusted to the redactor.
        WriteFile("oslogstore-2026-09-14T00-00-00Z.txt", "sessionKey=sk-ant-DUMPSECRET");
        Assert.Empty(LogsExporter.EligibleLogFiles(_dir, Install));
    }

    [Fact]
    public void Eligible_SameDayPriorLaunchFile_ExcludedByModificationTime()
    {
        WriteFile("diag-2026-01-01-priorbld.jsonl", "{}", Install.AddDays(-1));
        WriteFile("diag-2026-01-01-currbld.jsonl", "{}", Install.AddDays(1));

        var eligible = LogsExporter.EligibleLogFiles(_dir, Install);
        Assert.Equal(new[] { "diag-2026-01-01-currbld.jsonl" }, eligible.Select(Path.GetFileName).ToArray());
    }

    [Fact]
    public void Eligible_MissingDirectory_ReturnsEmptyWithoutThrowing() =>
        Assert.Empty(LogsExporter.EligibleLogFiles(Path.Combine(_dir, "nope"), Install));

    [Fact]
    public void Eligible_FailsClosed_WhenTheInstallDateIsUnreadable()
    {
        WriteFile("diag-2026-09-14-aaaa.jsonl", "{}");
        Assert.Empty(LogsExporter.EligibleLogFiles(_dir, DateTimeOffset.MaxValue));
    }

    // --- Archive build -------------------------------------------------------------------------

    [Fact]
    public void BuildArchive_ShipsOnlyTheCuratedList()
    {
        var eligible = WriteFile("diag-2026-09-14-aaaa.jsonl", "{\"kind\":\"probe\"}");
        WriteFile("oslogstore-2026-09-14T00-00-00Z.txt", "sessionKey=sk-ant-DUMPSECRET");

        var archive = LogsExporter.BuildArchive(new[] { eligible }, Now);
        try
        {
            using var zip = ZipFile.OpenRead(archive);
            Assert.Equal(new[] { "diag-2026-09-14-aaaa.jsonl" }, zip.Entries.Select(e => e.Name).ToArray());

            using var reader = new StreamReader(zip.Entries[0].Open());
            Assert.Equal("{\"kind\":\"probe\"}", reader.ReadToEnd());
        }
        finally
        {
            File.Delete(archive);
        }
    }

    [Fact]
    public void BuildArchive_ThrowsWhenASourceFileIsMissing() =>
        Assert.ThrowsAny<Exception>(() =>
            LogsExporter.BuildArchive(new[] { Path.Combine(_dir, "diag-missing.jsonl") }, Now));

    [Fact]
    public void ArchiveFileName_IsFilesystemSafe()
    {
        var name = LogsExporter.ArchiveFileName(Now);
        Assert.StartsWith("claudebattery-diag-", name, StringComparison.Ordinal);
        Assert.EndsWith(".zip", name, StringComparison.Ordinal);
        Assert.DoesNotContain(':', name);
    }

    // --- Atomic save ---------------------------------------------------------------------------

    [Fact]
    public void WriteArchive_ToNewPath_CopiesContent()
    {
        var source = WriteFile("source.bin", "new bytes");
        var destination = Path.Combine(_dir, "out", "archive.zip");
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);

        LogsExporter.WriteArchive(source, destination);

        Assert.Equal("new bytes", File.ReadAllText(destination));
    }

    [Fact]
    public void WriteArchive_OverExistingFile_ReplacesAndLeavesNoTempBehind()
    {
        var source = WriteFile("source.bin", "new bytes");
        var destination = WriteFile("archive.zip", "old bytes");

        LogsExporter.WriteArchive(source, destination);

        Assert.Equal("new bytes", File.ReadAllText(destination));
        Assert.Empty(Directory.GetFiles(_dir, ".archive.zip.tmp-*"));
    }

    [Fact]
    public void WriteArchive_OverExisting_OriginalSurvivesWhenTheSourceIsMissing()
    {
        // Covers AE14: an export that fails part way never destroys what was already there.
        var destination = WriteFile("archive.zip", "original bytes");
        var missing = Path.Combine(_dir, "not-there.bin");

        Assert.ThrowsAny<Exception>(() => LogsExporter.WriteArchive(missing, destination));

        Assert.Equal("original bytes", File.ReadAllText(destination));
        Assert.Empty(Directory.GetFiles(_dir, ".archive.zip.tmp-*"));
    }

    // --- The five outcomes ---------------------------------------------------------------------

    [Fact]
    public void Export_InstallDateUnreadable_NeverAsksWhereToSave()
    {
        WriteFile("diag-2026-09-14-aaaa.jsonl", "{}");
        var asked = false;

        var result = LogsExporter.Export(_dir, DateTimeOffset.MaxValue, _ => { asked = true; return null; }, Now);

        Assert.IsType<ExportResult.InstallDateUnreadable>(result);
        Assert.False(asked);
    }

    [Fact]
    public void Export_NothingToExport_NeverAsksWhereToSave()
    {
        var asked = false;
        var result = LogsExporter.Export(_dir, Install, _ => { asked = true; return null; }, Now);

        Assert.IsType<ExportResult.NothingToExport>(result);
        Assert.False(asked);
    }

    [Fact]
    public void Export_Cancelled_WhenNoDestinationIsChosen()
    {
        WriteFile("diag-2026-09-14-aaaa.jsonl", "{}");
        var result = LogsExporter.Export(_dir, Install, _ => null, Now);
        Assert.IsType<ExportResult.Cancelled>(result);
    }

    [Fact]
    public void Export_Success_ReturnsTheSavedPathAndTheIssuesUrl()
    {
        WriteFile("diag-2026-09-14-aaaa.jsonl", "{\"kind\":\"probe\"}");
        var destination = Path.Combine(_dir, "saved.zip");

        var result = LogsExporter.Export(_dir, Install, _ => destination, Now);

        var success = Assert.IsType<ExportResult.Success>(result);
        Assert.Equal(destination, success.SavedPath);
        Assert.Equal(LogsExporter.IssuesUrl, success.IssuesUrl);
        Assert.True(File.Exists(destination));
    }

    [Fact]
    public void Export_Failure_WhenTheDestinationCannotBeWritten()
    {
        WriteFile("diag-2026-09-14-aaaa.jsonl", "{}");

        // A directory path cannot be a file destination.
        var result = LogsExporter.Export(_dir, Install, _ => _dir, Now);

        var failure = Assert.IsType<ExportResult.Failure>(result);
        Assert.StartsWith("Could not save the archive:", failure.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Export_LeavesNoTempArchiveBehind()
    {
        WriteFile("diag-2026-09-14-aaaa.jsonl", "{}");
        var destination = Path.Combine(_dir, "saved.zip");

        LogsExporter.Export(_dir, Install, _ => destination, Now);

        Assert.Empty(Directory.GetFiles(Path.GetTempPath(), "claudebattery-diag-" + Now.Year + "*"));
        Assert.Empty(Directory.GetDirectories(Path.GetTempPath(), "claudebattery-diag-stage-*"));
    }
}
