using ClaudeBatteryWin.Models;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Anchors the shared Models contract the test project depends on. The standalone
/// <c>Scaffold_Compiles</c> no-op was removed - the real assertion below proves the test project
/// compiles and sees the app project just as well, without inflating the count with empty coverage.
/// </summary>
public class ScaffoldSmokeTests
{
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
