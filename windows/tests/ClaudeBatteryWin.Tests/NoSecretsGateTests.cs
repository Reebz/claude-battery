using System.Collections.Generic;
using System.IO;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Build-failing redaction gate (U19/#17), the Windows analog of the Mac NoSecretsExportGateTests.
/// Source-scans every production .cs file and fails if any logging/diagnostics sink line interpolates
/// a secret-bearing value (a sessionKey, the full cookie header, or a captured cookie value). This is
/// the cross-sink safety net: the per-class runtime test only proves ClaudeApi does not leak, whereas
/// a future DEBUG-build leak in ANY service (AccountStore, AuthManager, LoginWindow, ...) would fail
/// CI here. Cheap, runs without WinRT, and is itself tested (the detector flags planted leaks).
/// </summary>
public class NoSecretsGateTests
{
    [Fact]
    public void NoLogSinkInterpolatesASecret_AcrossAllProductionSources()
    {
        var srcDir = FindSourceDir();
        var offenders = new List<string>();

        foreach (var file in Directory.EnumerateFiles(srcDir, "*.cs", SearchOption.AllDirectories))
        {
            var lines = File.ReadAllLines(file);
            for (var i = 0; i < lines.Length; i++)
            {
                if (LineLogsSecret(lines[i]))
                {
                    offenders.Add($"{Path.GetFileName(file)}:{i + 1}: {lines[i].Trim()}");
                }
            }
        }

        Assert.True(
            offenders.Count == 0,
            "A logging sink interpolates a secret. Log a status/shape, never the value:\n"
                + string.Join("\n", offenders));
    }

    [Fact]
    public void Detector_FlagsPlantedLeaks_AndPassesRedactedLogs()
    {
        // Obvious leak forms MUST be flagged.
        Assert.True(LineLogsSecret("Debug.WriteLine($\"cookie={cookie.Value}\");"));
        Assert.True(LineLogsSecret("DebugLog($\"sessionKey={key}\");"));
        Assert.True(LineLogsSecret("Debug.WriteLine($\"header={account.AllCookieHeader}\");"));

        // Redacted status logs and non-sink lines MUST NOT be flagged.
        Assert.False(LineLogsSecret("DebugLog($\"Unexpected HTTP status: {status}\");"));
        Assert.False(LineLogsSecret("Debug.WriteLine(\"Session cookie captured\");"));
        Assert.False(LineLogsSecret("// the cookie.Value is never logged"));
        Assert.False(LineLogsSecret("_pendingSessionKey = sessionCookie.Value;")); // assignment, not a sink
    }

    /// <summary>
    /// True when <paramref name="line"/> is a logging/diagnostics sink call that also references a
    /// secret-bearing value. Comments are excluded (they cannot emit at runtime). Conservative by
    /// design: a sink line that mentions a cookie value or session key fails the gate.
    /// </summary>
    private static bool LineLogsSecret(string line)
    {
        var trimmed = line.TrimStart();
        if (trimmed.StartsWith("//", StringComparison.Ordinal)
            || trimmed.StartsWith("*", StringComparison.Ordinal))
        {
            return false;
        }

        var isSink = line.Contains("Debug.WriteLine", StringComparison.Ordinal)
            || line.Contains("DebugLog(", StringComparison.Ordinal)
            || line.Contains("Trace.Write", StringComparison.Ordinal)
            || line.Contains("Console.Write", StringComparison.Ordinal)
            || line.Contains("logger.", StringComparison.OrdinalIgnoreCase);
        if (!isSink)
        {
            return false;
        }

        var lower = line.ToLowerInvariant();
        return lower.Contains("sessionkey")
            || lower.Contains("cookieheader")
            || lower.Contains("capturedcookie")
            || (lower.Contains("cookie") && lower.Contains(".value"));
    }

    /// <summary>
    /// Locate <c>src/ClaudeBatteryWin</c> by walking up from the test output directory. Works on the CI
    /// runner (the repo is checked out) and a dev box; throws a clear error if the layout changed.
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
