using System.IO;
using System.Text.RegularExpressions;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Tray-icon identity tests: the NIF_GUID is derived from the exe path (Windows binds an unsigned
/// exe's tray GUID to the path that first registered it, so a fixed literal makes NIM_ADD fail after
/// any move/rename/re-download and the process dies before any UI exists). Pins that the mapping is
/// deterministic, path-sensitive and case-insensitive, and that App.xaml no longer carries a literal
/// Id that would override it.
/// </summary>
public class TrayIconIdentityTests
{
    [Fact]
    public void ForPath_SamePath_SameGuid()
    {
        const string path = @"C:\Users\tester\Downloads\ClaudeBatteryWin.exe";
        Assert.Equal(TrayIconIdentity.ForPath(path), TrayIconIdentity.ForPath(path));
        Assert.NotEqual(Guid.Empty, TrayIconIdentity.ForPath(path));
    }

    [Fact]
    public void ForPath_DifferentPath_DifferentGuid()
    {
        // The re-download case: the browser saves the second build as "ClaudeBatteryWin (1).exe".
        Guid first = TrayIconIdentity.ForPath(@"C:\Users\tester\Downloads\ClaudeBatteryWin.exe");
        Guid second = TrayIconIdentity.ForPath(@"C:\Users\tester\Downloads\ClaudeBatteryWin (1).exe");
        Guid moved = TrayIconIdentity.ForPath(@"C:\Tools\ClaudeBatteryWin.exe");

        Assert.NotEqual(first, second);
        Assert.NotEqual(first, moved);
        Assert.NotEqual(second, moved);
    }

    [Fact]
    public void ForPath_IsCaseInsensitive_AndTrimsWhitespace()
    {
        // Windows paths are case-insensitive; the two spellings are one file and must share a GUID.
        Guid lower = TrayIconIdentity.ForPath(@"c:\users\tester\downloads\claudebatterywin.exe");
        Guid mixed = TrayIconIdentity.ForPath(@"C:\Users\Tester\Downloads\ClaudeBatteryWin.EXE");
        Guid padded = TrayIconIdentity.ForPath("  C:\\Users\\Tester\\Downloads\\ClaudeBatteryWin.EXE \n");

        Assert.Equal(lower, mixed);
        Assert.Equal(lower, padded);
    }

    [Fact]
    public void Current_IsStableWithinAProcess()
    {
        Assert.Equal(TrayIconIdentity.Current, TrayIconIdentity.Current);
        Assert.NotEqual(Guid.Empty, TrayIconIdentity.Current);
    }

    [Fact]
    public void AppXaml_TaskbarIcon_CarriesNoLiteralId()
    {
        // A literal Id="..." on the TaskbarIcon would override the path-derived Id assigned in code
        // and bring the path-bound NIM_ADD failure back. Read the XAML as text, like the redaction
        // gate reads sources, and inspect the TaskbarIcon start tag only.
        string xamlPath = Path.Combine(FindSourceDir(), "App.xaml");
        string xaml = File.ReadAllText(xamlPath);

        int start = xaml.IndexOf("<tb:TaskbarIcon", StringComparison.Ordinal);
        Assert.True(start >= 0, "App.xaml has no <tb:TaskbarIcon element");
        int end = xaml.IndexOf('>', start);
        Assert.True(end > start, "unterminated <tb:TaskbarIcon start tag");
        string startTag = xaml.Substring(start, end - start);

        // Matches " Id=" / newline+"Id=" but not x:Key= or any attribute merely ending in Id.
        Assert.False(
            Regex.IsMatch(startTag, @"(?<![\w:.])Id\s*="),
            "App.xaml's TaskbarIcon must not set a literal Id; the Id comes from TrayIconIdentity:\n" + startTag);
    }

    /// <summary>
    /// Locate <c>src/ClaudeBatteryWin</c> by walking up from the test output directory, the same way
    /// <c>NoSecretsGateTests</c> finds its scan root.
    /// </summary>
    private static string FindSourceDir()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "src", "ClaudeBatteryWin");
            if (Directory.Exists(candidate))
            {
                return candidate;
            }
            dir = dir.Parent;
        }

        throw new DirectoryNotFoundException(
            "Could not locate src/ClaudeBatteryWin from " + AppContext.BaseDirectory);
    }
}
