using System.IO;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// AppSettings error-path tests (U24/#26). The default/persist/Changed behavior is covered by
/// NotifierTests; these cover the failure paths a settings file is never load-bearing for: a corrupt
/// JSON read degrades to defaults rather than throwing, and a failed write leaves no orphaned .tmp.
/// </summary>
public sealed class AppSettingsTests
{
    [Fact]
    public void Read_CorruptJson_ReturnsDefaults_NotThrow()
    {
        using var temp = new TempDir();
        var path = Path.Combine(temp.Dir, "settings.json");
        File.WriteAllText(path, "{ this is not valid json ]");

        var settings = new AppSettings(path); // Read catches JsonException and falls back

        Assert.False(settings.NotificationsEnabled);
        Assert.False(settings.ShowSessionCountdown);
    }

    [Fact]
    public void Read_MissingFile_ReturnsDefaults()
    {
        using var temp = new TempDir();
        var settings = new AppSettings(Path.Combine(temp.Dir, "does-not-exist.json"));

        Assert.False(settings.NotificationsEnabled);
        Assert.False(settings.ShowSessionCountdown);
    }

    [Fact]
    public void Write_Failure_LeavesNoTempFileBehind()
    {
        using var temp = new TempDir();
        // Make the settings PATH a directory so the File.Move rename step fails while the temp write
        // itself succeeds - the exact case where an orphaned .tmp could be left behind.
        var settingsPath = Path.Combine(temp.Dir, "settings.json");
        Directory.CreateDirectory(settingsPath);

        var settings = new AppSettings(settingsPath);
        settings.NotificationsEnabled = true; // triggers Write, which fails at the rename

        Assert.False(File.Exists(settingsPath + ".tmp")); // no orphaned temp
    }

    [Fact]
    public void Write_Failure_DoesNotThrow_FromTheSetter()
    {
        using var temp = new TempDir();
        var settingsPath = Path.Combine(temp.Dir, "settings.json");
        Directory.CreateDirectory(settingsPath);

        var settings = new AppSettings(settingsPath);

        // A persist failure is swallowed (a settings file is never load-bearing); the setter returns.
        var ex = Record.Exception(() => settings.ShowSessionCountdown = true);
        Assert.Null(ex);
    }

    private sealed class TempDir : IDisposable
    {
        public string Dir { get; } =
            Path.Combine(Path.GetTempPath(), "cbw-appsettings-tests", Guid.NewGuid().ToString("N"));

        public TempDir() => Directory.CreateDirectory(Dir);

        public void Dispose()
        {
            try
            {
                if (Directory.Exists(Dir))
                {
                    Directory.Delete(Dir, recursive: true);
                }
            }
            catch (IOException)
            {
            }
        }
    }
}
