using ClaudeBatteryWin;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Icons;
using ClaudeBatteryWin.ViewModels;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U4: the Session dial, the tray icon and the tooltip all show the same number, and that number
/// accounts for the weekly quota when the week is what is actually stopping the user (R10, R11, R12,
/// R42). Every value asserted here is the Mac's own test value, under the Mac's scenario name.
///
/// The failure this closes: a user with six percent of the week left and a fresh five-hour window
/// saw a Session dial near full, which is the reading that made them think nothing was wrong.
/// </summary>
public class SessionConversionTests
{
    private static UsageSnapshot Snapshot(double session, double weekly) =>
        new() { SessionRemaining = session, WeeklyRemaining = weekly };

    private static UsageReading Reading(double session, double weekly, string? tier) =>
        new(Snapshot(session, weekly), PlanRatio.Resolve(measured: null, tier: tier));

    private static UsageReading WithRatio(double session, double weekly, double? ratio) =>
        new(Snapshot(session, weekly), ratio);

    // --- The published table -------------------------------------------------------------------

    [Fact]
    public void PlanRatio_ThreeKnownTiers_HaveTheirPublishedValues()
    {
        Assert.Equal(0.1100, PlanRatio.ForTier("default_claude_pro")!.Value, 5);
        Assert.Equal(0.0792, PlanRatio.ForTier("default_claude_max_5x")!.Value, 5);
        Assert.Equal(0.1320, PlanRatio.ForTier("default_claude_max_20x")!.Value, 5);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("default_claude_free")]
    [InlineData("free")]
    [InlineData("auto_prepaid_tier_3")]
    [InlineData("")]
    [InlineData("DEFAULT_CLAUDE_PRO")]
    [InlineData("default_claude_max_50x")]
    public void PlanRatio_EverythingElse_IsNone(string? tier) => Assert.Null(PlanRatio.ForTier(tier));

    // --- Which ratio wins ----------------------------------------------------------------------

    [Fact]
    public void Resolve_MeasurementWins_WhenItAgreesWithTheTable() =>
        Assert.Equal(0.10, PlanRatio.Resolve(measured: 0.10, tier: "default_claude_max_5x")!.Value, 5);

    [Fact]
    public void Resolve_NoMeasurement_FallsBackToTheTable()
    {
        Assert.Equal(PlanRatio.Pro, PlanRatio.Resolve(measured: null, tier: "default_claude_pro")!.Value, 5);
        Assert.Null(PlanRatio.Resolve(measured: null, tier: "auto_prepaid_tier_3"));
    }

    [Theory]
    [InlineData("auto_prepaid_tier_3")]
    [InlineData(null)]
    public void Resolve_UnrecognisedTier_TakesTheMeasurementWhateverItSays(string? tier) =>
        Assert.Equal(0.40, PlanRatio.Resolve(measured: 0.40, tier: tier)!.Value, 5);

    [Fact]
    public void Resolve_MeasurementThatContradictsAKnownTier_IsRefused()
    {
        const string tier = "default_claude_max_5x";
        var table = PlanRatio.Max5x;

        Assert.Equal(table, PlanRatio.Resolve(table * 2.5, tier)!.Value, 5);   // too high, refused
        Assert.Equal(table, PlanRatio.Resolve(table / 2.5, tier)!.Value, 5);   // too low, refused
        Assert.Equal(table * 2, PlanRatio.Resolve(table * 2, tier)!.Value, 5); // the band is inclusive
        Assert.Equal(table / 2, PlanRatio.Resolve(table / 2, tier)!.Value, 5);
    }

    [Fact]
    public void AgreementBand_IsWiderThanAnyCorrectionTheTableCouldNeed()
    {
        Assert.True(PlanRatio.AgreementFactor > 12.63 / 9.09);
        Assert.True(PlanRatio.AgreementFactor > PlanRatio.Max20x / PlanRatio.Max5x);
    }

    // --- The reporter's numbers ----------------------------------------------------------------

    [Fact]
    public void Gauge_ReportersNumbers_Max5xSessionFullWeeklySix_Reads76()
    {
        // Covers AE1.
        var reading = Reading(session: 100, weekly: 6, tier: "default_claude_max_5x");

        Assert.Equal(75.76, reading.SessionDisplayRemaining, 2);
        Assert.Equal("76", $"{Math.Round(reading.SessionDisplayRemaining):0}");
        Assert.True(reading.IsSessionWeeklyLimited);
    }

    [Theory]
    [InlineData("default_claude_max_20x", 45.45)]
    [InlineData("default_claude_pro", 54.55)]
    public void Gauge_ReportersNumbers_OtherTiers(string tier, double expected) =>
        Assert.Equal(expected, Reading(session: 100, weekly: 6, tier: tier).SessionDisplayRemaining, 2);

    [Fact]
    public void Gauge_UnknownTier_ShowsTheTrueSessionValue()
    {
        // Covers AE3: an unrecognised plan is not a licence to guess.
        var reading = Reading(session: 100, weekly: 6, tier: "auto_prepaid_tier_3");

        Assert.Equal(100, reading.SessionDisplayRemaining);
        Assert.False(reading.IsSessionWeeklyLimited);
    }

    [Fact]
    public void Gauge_WeeklyExhausted_ReadsZeroWithNoRatioEither()
    {
        // Covers AE2: zero divided by any capacity is zero, so this needs no plan at all.
        var reading = Reading(session: 100, weekly: 0, tier: null);

        Assert.Null(reading.PlanRatio);
        Assert.Equal(0, reading.SessionDisplayRemaining);
        Assert.True(reading.IsSessionWeeklyLimited);
    }

    [Fact]
    public void Gauge_WeeklyExhausted_GaugeReadsZero()
    {
        var reading = Reading(session: 80, weekly: 0, tier: "default_claude_max_5x");
        Assert.Equal(0, reading.SessionDisplayRemaining);
        Assert.True(reading.IsSessionWeeklyLimited);
    }

    [Fact]
    public void Gauge_SessionIsTighterLimit_ShowsSessionNotWeekly()
    {
        var reading = Reading(session: 40, weekly: 80, tier: "default_claude_max_5x");
        Assert.Equal(40, reading.SessionDisplayRemaining);
        Assert.False(reading.IsSessionWeeklyLimited);
    }

    [Fact]
    public void Gauge_ConversionAbove100_ClampsRatherThanOverfilling()
    {
        var reading = Reading(session: 100, weekly: 20, tier: "default_claude_max_5x");
        Assert.Equal(100, reading.WeeklyRemainingInSessionUnits);
        Assert.Equal(100, reading.SessionDisplayRemaining);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("default_claude_max_5x")]
    public void Gauge_WeeklyAndSessionBothEmpty_IsNotClaimedAsWeeklyLimited(string? tier)
    {
        var reading = Reading(session: 0, weekly: 0, tier: tier);
        Assert.Equal(0, reading.SessionDisplayRemaining);
        Assert.False(reading.IsSessionWeeklyLimited); // nothing is limiting anything
    }

    [Theory]
    [InlineData(0.0)]
    [InlineData(-0.08)]
    public void Gauge_NonPositiveRatio_IsTreatedAsUnknown(double ratio)
    {
        var reading = WithRatio(session: 40, weekly: 6, ratio: ratio);
        Assert.Null(reading.WeeklyRemainingInSessionUnits);
        Assert.Equal(40, reading.SessionDisplayRemaining);
    }

    [Fact]
    public void Gauge_HealthyWeek_DoesNotDownRateSession()
    {
        // The regression lock against an unconditional min(session, weekly).
        Assert.Equal(94, Reading(session: 94, weekly: 63, tier: "default_claude_max_5x").SessionDisplayRemaining);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("default_claude_pro")]
    [InlineData("default_claude_max_5x")]
    [InlineData("default_claude_max_20x")]
    public void Gauge_RawSessionSurvivesEveryConversion(string? tier)
    {
        var reading = Reading(session: 94, weekly: 2, tier: tier);
        Assert.Equal(94, reading.Snapshot.SessionRemaining);
        Assert.Equal(2, reading.Snapshot.WeeklyRemaining);
    }

    [Fact]
    public void Gauge_RawSessionSurvives_AndTheDisplayValueIsTheConvertedOne() =>
        Assert.Equal(25.25, Reading(session: 94, weekly: 2, tier: "default_claude_max_5x").SessionDisplayRemaining, 2);

    [Theory]
    [InlineData(null)]
    [InlineData("default_claude_max_5x")]
    [InlineData("default_claude_max_20x")]
    public void Gauge_OldTwentyPointFloor_NoLongerChangesAnything(string? tier)
    {
        // There must be no threshold anywhere at the value 20.
        var below = Reading(session: 90, weekly: 19.99, tier: tier);
        var at = Reading(session: 90, weekly: 20, tier: tier);

        Assert.Equal(below.SessionDisplayRemaining, at.SessionDisplayRemaining, 6);
        Assert.Equal(90, at.SessionDisplayRemaining);
        Assert.False(below.IsSessionWeeklyLimited);
        Assert.False(at.IsSessionWeeklyLimited);
    }

    [Fact]
    public void Gauge_ConversionIsMonotonicInTheWeekly()
    {
        // No step, no cliff: the displayed value only ever rises as the week's remainder rises.
        double previous = double.NegativeInfinity;
        for (var weekly = 0.0; weekly <= 100.0; weekly += 0.1)
        {
            var value = Reading(session: 100, weekly: weekly, tier: "default_claude_max_5x").SessionDisplayRemaining;
            Assert.True(value >= previous - 0.0001, $"dropped at weekly={weekly}");
            if (previous > double.NegativeInfinity)
            {
                Assert.True(value - previous <= 1.5, $"jumped at weekly={weekly}");
            }
            previous = value;
        }
    }

    // --- The three surfaces agree --------------------------------------------------------------

    [Fact]
    public void TrayIcon_Tooltip_AndPanel_AgreeForTheSameReading()
    {
        // Covers R42, which used to hold only because no conversion existed.
        var reading = Reading(session: 100, weekly: 6, tier: "default_claude_max_5x");

        var tooltip = App.BuildTooltip(reading, "");
        var card = BuildSessionCard(reading);
        var trayState = (TrayRenderState.Battery)TrayRenderState.Resolve(
            isAuthenticated: true, serviceReady: true, authFailed: false,
            latestUsage: reading, consecutiveFailures: 0, isStale: false);

        Assert.Contains("Session 76%", tooltip, StringComparison.Ordinal);
        Assert.Equal("76%", card.PercentLabel);
        Assert.True(card.IsWeeklyLimited);
        Assert.Equal(76, (int)Math.Round(trayState.Reading.SessionDisplayRemaining));
    }

    private static GaugeCard BuildSessionCard(UsageReading reading)
    {
        var vm = new FlyoutViewModel(() => DateTimeOffset.UtcNow)
        {
            IsAuthenticated = true,
            LatestReading = reading,
        };
        return vm.SessionCard!;
    }
}
