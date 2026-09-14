using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// What a user gets back when they press Export in Settings. Five distinct outcomes, because
/// "nothing happened" has three different causes and the message has to say which (R57).
/// </summary>
public abstract record ExportResult
{
    private ExportResult() { }

    /// <summary>The archive was written. <paramref name="SavedPath"/> is where it landed.</summary>
    public sealed record Success(string SavedPath, string IssuesUrl) : ExportResult;

    /// <summary>The user dismissed the save dialog. Not an error, and the status line is left alone.</summary>
    public sealed record Cancelled : ExportResult;

    /// <summary>There are no eligible log files yet.</summary>
    public sealed record NothingToExport : ExportResult;

    /// <summary>The install date could not be read, so every file fails the floor and export is
    /// refused rather than silently shipping records an older, less redacted build wrote.</summary>
    public sealed record InstallDateUnreadable : ExportResult;

    /// <summary>Something went wrong; the message is shown verbatim.</summary>
    public sealed record Failure(string Message) : ExportResult;
}

/// <summary>
/// Builds the redacted diagnostics archive a user attaches to a bug report (U2, KD7, KTD5).
///
/// Two rules carry the safety here, and neither of them is redaction. First, only files named
/// <c>diag-*.jsonl</c> are ever eligible, so <c>crash.log</c> and <c>accounts.json</c> cannot enter an
/// archive whatever they contain. Second, the archive is built from a staged copy of exactly that
/// list, never by pointing a zipper at the live directory, so a stray file sitting next to the logs
/// cannot ride along.
///
/// The save is atomic. A file already at the destination is either fully replaced or left exactly as
/// it was; a failure half way through never destroys it and never leaves a temp file behind.
/// </summary>
public static class LogsExporter
{
    public const string IssuesUrl = "https://github.com/Reebz/claude-battery/issues";

    /// <summary>The only name shape that can ever be exported.</summary>
    public static bool IsEligibleName(string name) =>
        name.StartsWith("diag-", StringComparison.Ordinal) && name.EndsWith(".jsonl", StringComparison.Ordinal);

    /// <summary>
    /// The eligible files in a directory, oldest name first. A file written before this build was
    /// installed is excluded: its records came from a build whose redaction rules are not the ones
    /// this build guarantees.
    /// </summary>
    public static IReadOnlyList<string> EligibleLogFiles(string directory, DateTimeOffset installDate)
    {
        string[] entries;
        try
        {
            entries = Directory.GetFiles(directory);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or DirectoryNotFoundException or ArgumentException)
        {
            return Array.Empty<string>();
        }

        // One second of slack absorbs clock granularity around the moment of install. Both ends of
        // the range are reachable in tests, so the subtraction is clamped rather than allowed to
        // overflow.
        var floor = installDate;
        if (installDate < DateTimeOffset.MaxValue && installDate > DateTimeOffset.MinValue.AddSeconds(1))
        {
            floor = installDate.AddSeconds(-1);
        }

        var result = new List<string>();
        foreach (var entry in entries)
        {
            var name = Path.GetFileName(entry);
            if (!IsEligibleName(name))
            {
                continue;
            }

            try
            {
                var info = new FileInfo(entry);
                if (!info.Exists || info.Attributes.HasFlag(FileAttributes.Directory))
                {
                    continue;
                }
                if (new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero) < floor)
                {
                    continue;
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                continue;
            }

            result.Add(entry);
        }

        result.Sort((a, b) => string.CompareOrdinal(Path.GetFileName(a), Path.GetFileName(b)));
        return result;
    }

    /// <summary>
    /// When this build was installed, used as the floor above. Unreadable reads as the far future,
    /// which excludes everything: failing closed is the whole point, because failing open would admit
    /// records written by a build whose redaction was weaker.
    /// </summary>
    public static DateTimeOffset ProductionInstallDate()
    {
        try
        {
            var path = Environment.ProcessPath;
            if (string.IsNullOrEmpty(path) || !File.Exists(path))
            {
                return DateTimeOffset.MaxValue;
            }
            return new DateTimeOffset(File.GetCreationTimeUtc(path), TimeSpan.Zero);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            return DateTimeOffset.MaxValue;
        }
    }

    /// <summary>The name the save dialog offers.</summary>
    public static string ArchiveFileName(DateTimeOffset now) =>
        "claudebattery-diag-" + now.ToString("yyyy-MM-dd'T'HH:mm:ssK", CultureInfo.InvariantCulture).Replace(':', '-') + ".zip";

    /// <summary>
    /// Zips exactly the given files, through a staging directory so nothing else can be picked up.
    /// Returns the path of the temp archive; the caller deletes it.
    /// </summary>
    public static string BuildArchive(IReadOnlyList<string> files, DateTimeOffset now)
    {
        var stage = Path.Combine(Path.GetTempPath(), "claudebattery-diag-stage-" + Guid.NewGuid().ToString("N"));
        var archive = Path.Combine(Path.GetTempPath(), ArchiveFileName(now));

        try
        {
            Directory.CreateDirectory(stage);
            foreach (var file in files)
            {
                CopyEvenWhileOpen(file, Path.Combine(stage, Path.GetFileName(file)));
            }

            if (File.Exists(archive))
            {
                File.Delete(archive);
            }
            ZipFile.CreateFromDirectory(stage, archive, CompressionLevel.Optimal, includeBaseDirectory: false);
            return archive;
        }
        finally
        {
            try
            {
                if (Directory.Exists(stage))
                {
                    Directory.Delete(stage, recursive: true);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    /// <summary>
    /// Copies a file that something else may still be writing to. The current launch's own log is
    /// open for append the whole time the app runs, and <c>File.Copy</c> asks for exclusive-enough
    /// access to fail against it, which would make export throw for the one user who has logging on
    /// right now - the only user who ever exports.
    /// </summary>
    private static void CopyEvenWhileOpen(string source, string destination)
    {
        using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None);
        input.CopyTo(output);
    }

    /// <summary>
    /// Puts the archive at the destination without ever destroying what is already there. A new path
    /// is a plain copy. An existing file is replaced atomically through a temp sibling in the same
    /// directory, so a failure part way leaves the original bytes untouched.
    /// </summary>
    public static void WriteArchive(string source, string destination)
    {
        if (!File.Exists(destination))
        {
            File.Copy(source, destination, overwrite: false);
            return;
        }

        var parent = Path.GetDirectoryName(destination);
        if (string.IsNullOrEmpty(parent))
        {
            throw new IOException("Could not resolve the destination directory.");
        }

        var temp = Path.Combine(parent, "." + Path.GetFileName(destination) + ".tmp-" + Guid.NewGuid().ToString("N"));
        try
        {
            File.Copy(source, temp, overwrite: false);

            // A reparse point cannot be handed to the atomic replace, so it is unlinked first. The
            // link is what gets removed; whatever it pointed at is left alone.
            if (IsReparsePoint(destination))
            {
                File.Delete(destination);
                File.Move(temp, destination);
                return;
            }

            File.Replace(temp, destination, destinationBackupFileName: null);
        }
        catch (Exception)
        {
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
            throw;
        }
    }

    private static bool IsReparsePoint(string path)
    {
        try
        {
            return new FileInfo(path).Attributes.HasFlag(FileAttributes.ReparsePoint);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>
    /// The whole export. <paramref name="chooseDestination"/> is handed the suggested file name and
    /// returns where to save, or null if the user cancelled; the Settings window passes a save
    /// dialog, tests pass a lambda.
    /// </summary>
    public static ExportResult Export(
        string logsDirectory,
        DateTimeOffset installDate,
        Func<string, string?> chooseDestination,
        DateTimeOffset? now = null)
    {
        if (installDate == DateTimeOffset.MaxValue)
        {
            return new ExportResult.InstallDateUnreadable();
        }

        var eligible = EligibleLogFiles(logsDirectory, installDate);
        if (eligible.Count == 0)
        {
            return new ExportResult.NothingToExport();
        }

        var stamp = now ?? DateTimeOffset.Now;
        string archive;
        try
        {
            archive = BuildArchive(eligible, stamp);
        }
        catch (Exception ex)
        {
            return new ExportResult.Failure("Could not build the diagnostic archive: " + ex.Message);
        }

        try
        {
            var destination = chooseDestination(Path.GetFileName(archive));
            if (string.IsNullOrEmpty(destination))
            {
                return new ExportResult.Cancelled();
            }

            try
            {
                WriteArchive(archive, destination);
            }
            catch (Exception ex)
            {
                return new ExportResult.Failure("Could not save the archive: " + ex.Message);
            }

            return new ExportResult.Success(destination, IssuesUrl);
        }
        finally
        {
            try
            {
                if (File.Exists(archive))
                {
                    File.Delete(archive);
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                DebugLog("temp archive could not be removed");
            }
        }
    }

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[LogsExporter] {message}");
}
