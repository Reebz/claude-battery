using ClaudeBatteryWin.Models;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Scaffold smoke test (U1). Proves the test project compiles, references the app project, and
/// can see the shared Models contract. Downstream units add real per-unit test files.
/// </summary>
public class ScaffoldSmokeTests
{
    [Fact]
    public void Scaffold_Compiles()
    {
        Assert.True(true);
    }

    [Fact]
    public void Account_DisplayName_PrefersNicknameOverEmail()
    {
        // Anchors the shared contract: DisplayName falls back to email, nickname wins.
        var withEmailOnly = new Account
        {
            Email = "user@example.com",
            SessionKey = "sk",
            OrganizationId = "org-1"
        };
        Assert.Equal("user@example.com", withEmailOnly.DisplayName);

        var withNickname = withEmailOnly with { Nickname = "Work" };
        Assert.Equal("Work", withNickname.DisplayName);
    }
}
