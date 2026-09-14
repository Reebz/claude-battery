using System.Globalization;
using ClaudeBatteryWin;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.ViewModels;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U13: the panel's smaller wrongs (R32, R33, R34, R35, R36, R54).
///
/// Each of these is the kind of thing a user notices once and then stops trusting the panel over: a
/// freshness line that vanishes exactly when an update is available, a credits reset date that only
/// appears with a spend cap, US date order in front of a British reader, a static row that says
/// nothing, and no way to tell which build is running.
/// </summary>
public class PanelHousekeepingTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 14, 12, 0, 0, TimeSpan.Zero);

    private static FlyoutViewModel NewViewModel() => new(() => Now);

    /// A reading, so the panel is in its authenticated state and the account rows are built.
    private static UsageReading Authenticated() =>
        new(new UsageSnapshot { SessionRemaining = 50, WeeklyRemaining = 50 }, null);

    // --- The update notice no longer hides the freshness line (R32) -----------------------------

    [Fact]
    public void WithAnUpdateAvailable_BothTheNoticeAndTheFreshnessLineAreThere()
    {
        var vm = NewViewModel();
        vm.IsAuthenticated = true;
        vm.LastSuccessfulFetch = Now.AddSeconds(-30);
        vm.AvailableUpdateVersion = "1.73";

        Assert.True(vm.HasUpdate);
        Assert.Contains("1.73", vm.UpdateLinkText, StringComparison.Ordinal);
        Assert.Contains("Updated just now", vm.FooterText, StringComparison.Ordinal);
    }

    // --- The version is in the footer and in the tray menu (R54) --------------------------------

    [Fact]
    public void FooterCarriesTheRunningVersionBesideTheFreshnessLine()
    {
        var vm = NewViewModel();
        vm.LastSuccessfulFetch = Now.AddMinutes(-5);

        Assert.Contains("Updated 5 minutes ago", vm.FooterText, StringComparison.Ordinal);
        Assert.Contains(ClaudeBatteryWin.Services.AppVersionInfo.Version, vm.FooterText, StringComparison.Ordinal);
        Assert.StartsWith("v", vm.FooterText, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(0, "Updated just now")]
    [InlineData(60, "Updated 1 minute ago")]
    [InlineData(300, "Updated 5 minutes ago")]
    public void FreshnessWording_IsTheMacs(int secondsAgo, string expected)
    {
        var vm = NewViewModel();
        vm.LastSuccessfulFetch = Now.AddSeconds(-secondsAgo);
        Assert.Equal(expected, vm.LastUpdatedText);
    }

    [Fact]
    public void TrayMenusFirstRow_NamesTheVersion()
    {
        var title = App.VersionMenuTitle();
        Assert.StartsWith("Claude Battery v", title, StringComparison.Ordinal);
        Assert.Contains(ClaudeBatteryWin.Services.AppVersionInfo.Version, title, StringComparison.Ordinal);
    }

    // --- The credits reset date does not depend on a spend cap (R33) ----------------------------

    [Fact]
    public void CreditsWithNoMonthlyCap_StillShowAResetDate()
    {
        var credits = new UsageCredits
        {
            StateKind = CreditsStateKind.Enabled,
            Spent = 12.5,
            SpendPercent = 25,
            SpendCurrency = "USD",
            SpendLimit = null,
            StateResetDate = new DateTimeOffset(2026, 10, 1, 0, 0, 0, TimeSpan.Zero),
        };

        var row = FlyoutViewModel.MakeCreditsRow(credits, Now);

        Assert.False(row.HasMonthlySpendLimit);
        Assert.True(row.HasResetsText);
        Assert.NotEqual(string.Empty, row.ResetsText);
    }

    // --- Money and dates follow the user's region (R34) ------------------------------------------

    [Fact]
    public void ADateRendersInTheUsersOwnOrder()
    {
        var date = new DateTimeOffset(2026, 3, 4, 0, 0, 0, TimeSpan.Zero);

        var british = WithCulture("en-GB", () => FlyoutViewModel.ShortDate(date));
        var american = WithCulture("en-US", () => FlyoutViewModel.ShortDate(date));

        Assert.StartsWith("04/03", british, StringComparison.Ordinal);  // day first
        Assert.StartsWith("3/4", american, StringComparison.Ordinal);   // month first
    }

    [Fact]
    public void AnAustralianBalance_KeepsItsOwnSymbolUnderAnyRegion()
    {
        var australian = WithCulture("en-AU", () => FlyoutViewModel.FormatCurrency(1234.5, "AUD"));
        var german = WithCulture("de-DE", () => FlyoutViewModel.FormatCurrency(1234.5, "AUD"));

        // The amount's currency decides the symbol; the reader's region decides the grouping.
        Assert.Contains("$", australian, StringComparison.Ordinal);
        Assert.Contains("1,234.50", australian, StringComparison.Ordinal);
        Assert.Contains("1.234,50", german, StringComparison.Ordinal);
    }

    [Fact]
    public void ADollarBalance_ShowsADollarSymbolEvenUnderARussianRegion()
    {
        var russian = WithCulture("ru-RU", () => FlyoutViewModel.FormatCurrency(10, "USD"));
        Assert.Contains("$", russian, StringComparison.Ordinal);
    }

    [Fact]
    public void AnUnfamiliarCurrencyCode_StillFindsItsSymbol()
    {
        // Looked up from whichever region publishes the code, rather than printed as bare letters.
        var symbol = FlyoutViewModel.CurrencySymbol("SEK");
        Assert.NotEqual("SEK ", symbol);
    }

    private static T WithCulture<T>(string name, Func<T> body)
    {
        var previous = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = new CultureInfo(name);
            return body();
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    // --- Renaming from the panel (R36) -------------------------------------------------------------

    [Fact]
    public void RenamingFromThePanel_RaisesTheRequestAndLeavesEditMode()
    {
        var vm = NewViewModel();
        var id = Guid.NewGuid();
        vm.IsAuthenticated = true;
        vm.LatestReading = Authenticated();
        vm.Accounts = new[]
        {
            new Account { Id = id, Email = "me@x.com", SessionKey = "sk", OrganizationId = "org-1" },
            new Account { Email = "other@x.com", SessionKey = "sk", OrganizationId = "org-2" },
        };
        vm.ActiveAccountId = id;

        (Guid Id, string Name)? renamed = null;
        vm.RenameAccountRequested += (accountId, name) => renamed = (accountId, name);

        vm.BeginRename(id);
        Assert.True(vm.AccountRows.Single(r => r.Id == id).IsEditing);

        vm.CommitRename(id, "Work");

        Assert.Equal((id, "Work"), renamed);
        Assert.False(vm.AccountRows.Single(r => r.Id == id).IsEditing);
    }

    [Fact]
    public void CancellingARename_ChangesNothing()
    {
        var vm = NewViewModel();
        var id = Guid.NewGuid();
        vm.IsAuthenticated = true;
        vm.LatestReading = Authenticated();
        vm.Accounts = new[]
        {
            new Account { Id = id, Email = "me@x.com", SessionKey = "sk", OrganizationId = "org-1" },
            new Account { Email = "other@x.com", SessionKey = "sk", OrganizationId = "org-2" },
        };

        var raised = false;
        vm.RenameAccountRequested += (_, _) => raised = true;

        vm.BeginRename(id);
        vm.CancelRename();

        Assert.False(raised);
        Assert.False(vm.AccountRows.Single(r => r.Id == id).IsEditing);
    }
}
