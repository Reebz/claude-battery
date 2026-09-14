using System.IO;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Reads the Mac test suite's fixture files straight out of the repository (KTD2).
///
/// The point is that both suites assert against the same bytes. A Windows copy of these files would
/// drift the first time the Mac side changed one, and nothing would say so; reading the originals
/// means a Mac change that breaks the shared contract fails the Windows build too.
///
/// The repository root is found by walking up from the test binary, the same way
/// <see cref="NoSecretsGateTests"/> locates the production source tree.
/// </summary>
internal static class RepoFixtures
{
    /// <summary>The Mac fixtures directory.</summary>
    public static string Directory => Path.Combine(RepoRoot(), "ClaudeBattery", "ClaudeBatteryTests", "Fixtures");

    /// <summary>Reads one Mac fixture by file name, e.g. "orgs_multiple.json".</summary>
    public static string Read(string name) => File.ReadAllText(Path.Combine(Directory, name));

    /// <summary>True when the Mac tree is present in this checkout.</summary>
    public static bool Available => System.IO.Directory.Exists(Directory);

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (System.IO.Directory.Exists(Path.Combine(dir.FullName, "windows", "src", "ClaudeBatteryWin")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }

        throw new DirectoryNotFoundException(
            "Could not locate the repository root from " + AppContext.BaseDirectory);
    }
}
