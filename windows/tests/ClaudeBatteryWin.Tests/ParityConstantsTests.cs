using System.Text.Json;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.ViewModels;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// The numbers both apps have to agree on, checked against the one file that holds them
/// (<c>ClaudeBattery/ClaudeBatteryTests/Fixtures/parity-constants.json</c>, KTD2, R14).
///
/// Each app compiles in its own copy of these values. Without this test a change on one side would
/// silently put the two dials out of step, and the only way anyone would find out is a user noticing
/// that the Mac and the Windows app disagree about the same account. Here, that change fails a build.
///
/// The same file is what the Mac test will read once it is wired up; today only Windows reads it.
/// </summary>
public class ParityConstantsTests
{
    private static JsonElement Constants()
    {
        Assert.True(RepoFixtures.Available, "the Mac fixtures are part of this repository");
        return JsonDocument.Parse(RepoFixtures.Read("parity-constants.json")).RootElement;
    }

    [Fact]
    public void PlanRatios_MatchTheSharedFile()
    {
        var ratios = Constants().GetProperty("planRatios");

        Assert.Equal(ratios.GetProperty("default_claude_pro").GetDouble(), PlanRatio.Pro, 6);
        Assert.Equal(ratios.GetProperty("default_claude_max_5x").GetDouble(), PlanRatio.Max5x, 6);
        Assert.Equal(ratios.GetProperty("default_claude_max_20x").GetDouble(), PlanRatio.Max20x, 6);
    }

    [Fact]
    public void AgreementFactor_MatchesTheSharedFile() =>
        Assert.Equal(Constants().GetProperty("agreementFactor").GetDouble(), PlanRatio.AgreementFactor, 6);

    [Fact]
    public void MeasurementConstants_MatchTheSharedFile()
    {
        var measurement = Constants().GetProperty("ratioMeasurement");

        Assert.Equal(measurement.GetProperty("confidenceBar").GetDouble(), RatioMeasurement.ConfidenceBar, 6);
        Assert.Equal(measurement.GetProperty("plausibleMin").GetDouble(), RatioMeasurement.PlausibleMin, 6);
        Assert.Equal(measurement.GetProperty("plausibleMax").GetDouble(), RatioMeasurement.PlausibleMax, 6);

        // The tolerance is not a named constant; it is the literal in SameWindow, so it is checked by
        // behaviour instead: just inside matches, just outside does not.
        var tolerance = measurement.GetProperty("sameWindowToleranceSeconds").GetDouble();
        var moment = new DateTimeOffset(2026, 6, 17, 7, 40, 0, TimeSpan.Zero);
        Assert.True(RatioMeasurement.SameWindow(moment, moment.AddSeconds(tolerance * 0.9)));
        Assert.False(RatioMeasurement.SameWindow(moment, moment.AddSeconds(tolerance * 1.1)));
    }

    [Fact]
    public void WindowLengthsAndTickCounts_MatchTheSharedFile()
    {
        var root = Constants();

        Assert.Equal(root.GetProperty("windowSeconds").GetProperty("session").GetDouble(), FlyoutViewModel.SessionWindowSeconds, 6);
        Assert.Equal(root.GetProperty("windowSeconds").GetProperty("weekly").GetDouble(), FlyoutViewModel.WeeklyWindowSeconds, 6);
        Assert.Equal(root.GetProperty("tickCounts").GetProperty("session").GetInt32(), FlyoutViewModel.SessionTickCount);
        Assert.Equal(root.GetProperty("tickCounts").GetProperty("weekly").GetInt32(), FlyoutViewModel.WeeklyTickCount);
    }

    // --- The Mac usage fixtures parse to the Mac's own numbers ---------------------------------

    [Fact]
    public void MacUsageFixture_ParsesToTheNumbersTheMacTestsAssert()
    {
        var response = JsonSerializer.Deserialize<UsageApiResponse>(
            RepoFixtures.Read("usage_full.json"), ApiOptions)!;

        var snapshot = ClaudeBatteryWin.Services.UsageSnapshotResolver.Resolve(response, credits: null);

        Assert.Equal(65.0, snapshot.SessionRemaining, 6);
        Assert.Equal(40.0, snapshot.WeeklyRemaining, 6);
        Assert.NotNull(snapshot.SessionResetDate);
        Assert.NotNull(snapshot.WeeklyResetDate);
        Assert.Collection(snapshot.ModelUsages,
            opus =>
            {
                Assert.Equal("Opus", opus.DisplayName);
                Assert.Equal(20.0, opus.RemainingPercent, 6);
            },
            sonnet =>
            {
                Assert.Equal("Sonnet", sonnet.DisplayName);
                Assert.Equal(90.0, sonnet.RemainingPercent, 6);
            });
    }

    [Fact]
    public void MacLimitsFixture_ParsesToTheNumbersTheMacTestsAssert()
    {
        var response = JsonSerializer.Deserialize<UsageApiResponse>(
            RepoFixtures.Read("usage_limits_spend.json"), ApiOptions)!;

        var snapshot = ClaudeBatteryWin.Services.UsageSnapshotResolver.Resolve(response, credits: null);

        Assert.Equal(94.0, snapshot.SessionRemaining, 6);
        Assert.Equal(63.0, snapshot.WeeklyRemaining, 6);

        // A healthy week never down-rates the session reading, whatever the plan.
        var reading = new UsageReading(snapshot, PlanRatio.Max5x);
        Assert.Equal(94.0, reading.SessionDisplayRemaining, 6);
    }

    [Fact]
    public void MacNilFieldsFixture_DefaultsToFullRemaining()
    {
        var response = JsonSerializer.Deserialize<UsageApiResponse>(
            RepoFixtures.Read("usage_nil_fields.json"), ApiOptions)!;

        var snapshot = ClaudeBatteryWin.Services.UsageSnapshotResolver.Resolve(response, credits: null);

        Assert.Equal(100.0, snapshot.SessionRemaining, 6);
        Assert.Equal(100.0, snapshot.WeeklyRemaining, 6);

        // Nothing was actually read, so no interval built from this reading may be accumulated.
        Assert.False(snapshot.SessionPercentWasRead);
        Assert.False(snapshot.WeeklyPercentWasRead);
    }

    /// The transport's own decoding options, so these tests parse what production parses.
    private static readonly JsonSerializerOptions ApiOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
        NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowReadingFromString,
    };
}
