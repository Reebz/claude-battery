using ClaudeBatteryWin.Models;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U5: each account works out its own weekly-to-session conversion by watching what it actually
/// spends (R13). Every value here is the Mac's own test value.
///
/// Two rules do the work. An interval only counts when both windows are the same ones as last time
/// and neither remainder went up, because anything else is not consumption. And the running totals
/// have to get past a confidence bar before the measurement is believed at all, because a small
/// sample divided into another small sample is noise.
/// </summary>
public class RatioMeasurementTests
{
    private static readonly DateTimeOffset SessionResets = new(2026, 6, 17, 7, 40, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset WeeklyResets = new(2026, 6, 21, 23, 0, 0, TimeSpan.Zero);

    private static RatioMeasurement Fold(
        RatioMeasurement? previous,
        double session,
        double weekly,
        DateTimeOffset? sessionResets = null,
        DateTimeOffset? weeklyResets = null) =>
        RatioMeasurement.Updated(
            previous,
            session,
            sessionResets ?? SessionResets,
            weekly,
            weeklyResets ?? WeeklyResets);

    /// A measurement that has already accumulated the given totals.
    private static RatioMeasurement Accumulated(double session, double weekly) => new()
    {
        SessionPointsConsumed = session,
        WeeklyPointsConsumed = weekly,
    };

    // --- Accumulation --------------------------------------------------------------------------

    [Fact]
    public void FirstSample_RecordsTheReadingAndAccumulatesNothing()
    {
        var measurement = Fold(null, session: 100, weekly: 63);

        Assert.Equal(100, measurement.LastSessionRemaining);
        Assert.Equal(63, measurement.LastWeeklyRemaining);
        Assert.Equal(0, measurement.SessionPointsConsumed);
        Assert.Equal(0, measurement.WeeklyPointsConsumed);
        Assert.Null(measurement.Ratio);
    }

    [Fact]
    public void CleanInterval_AccumulatesBothDeltas()
    {
        var measurement = Fold(Fold(null, 100, 63), session: 92, weekly: 62);

        Assert.Equal(8, measurement.SessionPointsConsumed);
        Assert.Equal(1, measurement.WeeklyPointsConsumed);
        Assert.Equal(92, measurement.LastSessionRemaining);
    }

    [Fact]
    public void ConsecutiveCleanIntervals_AddUp()
    {
        var measurement = Fold(Fold(Fold(Fold(null, 100, 63), 92, 62), 84, 62), 76, 61);

        Assert.Equal(24, measurement.SessionPointsConsumed);
        Assert.Equal(2, measurement.WeeklyPointsConsumed);
    }

    [Fact]
    public void IdleInterval_IsCleanAndAddsZero()
    {
        var measurement = Fold(Fold(null, 92, 62), 92, 62);

        Assert.Equal(0, measurement.SessionPointsConsumed);
        Assert.Equal(0, measurement.WeeklyPointsConsumed);
    }

    [Fact]
    public void SessionRollover_AddsNothingAndKeepsTheTotals()
    {
        // An interval that straddles a reset is not consumption, so it is dropped whole - both
        // sides, because one guard covers both.
        var before = Fold(Fold(null, 100, 63), 20, 55);
        Assert.Equal(80, before.SessionPointsConsumed);

        var after = Fold(before, session: 100, weekly: 54, sessionResets: SessionResets.AddHours(5));

        Assert.Equal(80, after.SessionPointsConsumed);
        Assert.Equal(8, after.WeeklyPointsConsumed);
    }

    [Fact]
    public void WeeklyRollover_AddsNothingAndKeepsTheTotals()
    {
        var before = Fold(Fold(null, 100, 63), 60, 55);
        Assert.Equal(40, before.SessionPointsConsumed);
        Assert.Equal(8, before.WeeklyPointsConsumed);

        var after = Fold(before, session: 59, weekly: 100, weeklyResets: WeeklyResets.AddDays(7));

        Assert.Equal(40, after.SessionPointsConsumed);
        Assert.Equal(8, after.WeeklyPointsConsumed);
    }

    [Fact]
    public void Rollover_StillReplacesTheSample_SoTheNextIntervalMeasuresFromTheNewWindow()
    {
        var before = Fold(Fold(null, 100, 63), 20, 55);
        var newSessionWindow = SessionResets.AddHours(5);

        var rolled = Fold(before, session: 100, weekly: 54, sessionResets: newSessionWindow);
        var next = Fold(rolled, session: 90, weekly: 53, sessionResets: newSessionWindow);

        // Ten more session points and one more weekly point, measured from the new window's reading.
        Assert.Equal(90, next.SessionPointsConsumed);
        Assert.Equal(9, next.WeeklyPointsConsumed);
    }

    [Fact]
    public void SessionRemainingWentUp_IsNeverAccumulated()
    {
        var measurement = Fold(Fold(null, 60, 50), session: 65, weekly: 49);

        Assert.Equal(0, measurement.SessionPointsConsumed);
        Assert.Equal(0, measurement.WeeklyPointsConsumed);
        Assert.Equal(65, measurement.LastSessionRemaining); // the sample still moves on
    }

    [Fact]
    public void WeeklyRemainingWentUp_IsNeverAccumulated()
    {
        var measurement = Fold(Fold(null, 60, 50), session: 55, weekly: 52);

        Assert.Equal(0, measurement.SessionPointsConsumed);
        Assert.Equal(0, measurement.WeeklyPointsConsumed);
    }

    [Fact]
    public void MissingResetTimes_NeverAccumulate()
    {
        var first = RatioMeasurement.Updated(null, 100, null, 63, null);
        var second = RatioMeasurement.Updated(first, 92, null, 62, null);

        Assert.Equal(0, second.SessionPointsConsumed);
        Assert.Equal(0, second.WeeklyPointsConsumed);
    }

    [Fact]
    public void OneMissingResetTime_AlsoBlocksTheInterval()
    {
        var first = Fold(null, 100, 63);
        var second = RatioMeasurement.Updated(first, 92, null, 62, WeeklyResets);

        Assert.Equal(0, second.SessionPointsConsumed);
    }

    [Fact]
    public void SubSecondJitterInAResetTime_IsStillTheSameWindow()
    {
        // The same instant arrives in several wire shapes; a fraction of a second between two of
        // them is not a new window.
        var measurement = Fold(Fold(null, 100, 63), 92, 62, sessionResets: SessionResets.AddSeconds(0.4));

        Assert.Equal(8, measurement.SessionPointsConsumed);
    }

    [Theory]
    [InlineData(0.9, true)]
    [InlineData(1.1, false)]
    public void SameWindow_HasAOneSecondTolerance(double offsetSeconds, bool expected) =>
        Assert.Equal(expected, RatioMeasurement.SameWindow(SessionResets, SessionResets.AddSeconds(offsetSeconds)));

    [Fact]
    public void SameWindow_TreatsAMissingTimeAsNeverMatching()
    {
        Assert.False(RatioMeasurement.SameWindow(null, SessionResets));
        Assert.False(RatioMeasurement.SameWindow(SessionResets, null));
        Assert.False(RatioMeasurement.SameWindow(null, null));
    }

    // --- When the measurement is believed -------------------------------------------------------

    [Fact]
    public void ConfidenceBar_IsTheNumberTheArithmeticGives() =>
        Assert.Equal(30, RatioMeasurement.ConfidenceBar);

    [Fact]
    public void AnAfternoonOfUse_IsNotYetAMeasurement() =>
        Assert.Null(Accumulated(session: 38, weekly: 3).Ratio);

    [Fact]
    public void BelowTheConfidenceBar_ThereIsNoMeasuredRatio() =>
        Assert.Null(Accumulated(session: 366, weekly: 29).Ratio);

    [Fact]
    public void AtTheConfidenceBar_TheMeasuredRatioIsAvailable() =>
        Assert.Equal(PlanRatio.Max5x, Accumulated(session: 379, weekly: 30).Ratio!.Value, PlanRatio.Max5x / 30);

    [Fact]
    public void ImplausiblyHighRatio_IsRejected()
    {
        Assert.Null(Accumulated(session: 50, weekly: 30).Ratio);                    // 0.60, above the band
        Assert.Equal(0.5, Accumulated(session: 60, weekly: 30).Ratio!.Value, 4);    // exactly the edge
    }

    [Fact]
    public void ImplausiblyLowRatio_IsRejected()
    {
        Assert.Null(Accumulated(session: 4000, weekly: 30).Ratio);                  // 0.0075, below the band
        Assert.Equal(0.01, Accumulated(session: 3000, weekly: 30).Ratio!.Value, 4); // exactly the edge
    }

    [Fact]
    public void NothingMeasuredYet_HasNoRatioAndDoesNotDivideByZero() =>
        Assert.Null(Accumulated(session: 0, weekly: 0).Ratio);

    [Fact]
    public void AWeeklyThatNeverMoved_NeverReachesTheBandAtAll() =>
        Assert.Null(Accumulated(session: 400, weekly: 0).Ratio);
}
