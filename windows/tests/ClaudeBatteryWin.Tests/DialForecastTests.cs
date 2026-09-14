using ClaudeBatteryWin.Icons;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.ViewModels;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U11 and U12: what a dial says beyond the percentage (R27, R28, R51, R52, R53, R37).
///
/// A percentage on its own does not answer the question. Forty percent left sounds bad with six
/// hours of the window to go and is fine with twenty minutes. The pace grades the gap between the
/// two rings, the run-out turns that gap into a time, and the countdown says when it resets. Every
/// value here is the Mac's.
/// </summary>
public class DialForecastTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 14, 12, 0, 0, TimeSpan.Zero);

    private static DateTimeOffset SessionResetWith(double timeRemainingPercent) =>
        Now.AddSeconds(DialForecast.SessionWindowSeconds * timeRemainingPercent / 100);

    private static UsageReading Reading(double session, double weekly, double? ratio, DateTimeOffset? sessionReset = null) =>
        new(new UsageSnapshot
        {
            SessionRemaining = session,
            WeeklyRemaining = weekly,
            SessionResetDate = sessionReset,
        }, ratio);

    // --- Pace ------------------------------------------------------------------------------------

    [Theory]
    // Ahead of the clock, or level with it: on track.
    [InlineData(100, 100, PaceStatus.OnTrack)]
    [InlineData(80, 60, PaceStatus.OnTrack)]   // ahead of pace: a negative delta
    [InlineData(50, 50, PaceStatus.OnTrack)]
    [InlineData(50, 59, PaceStatus.OnTrack)]   // delta 9, just inside
    // The caution band, inclusive at ten.
    [InlineData(50, 60, PaceStatus.Caution)]   // delta 10 exactly
    [InlineData(50, 70, PaceStatus.Caution)]   // delta 20
    [InlineData(50, 74, PaceStatus.Caution)]   // delta 24, just inside
    // The danger band, inclusive at twenty-five.
    [InlineData(50, 75, PaceStatus.Danger)]    // delta 25 exactly
    [InlineData(10, 90, PaceStatus.Danger)]
    [InlineData(1, 100, PaceStatus.Danger)]
    // Nothing left is Danger whatever the clock says.
    [InlineData(0, 100, PaceStatus.Danger)]
    [InlineData(0, 1, PaceStatus.Danger)]
    public void Pace_BucketsTheGapBetweenUsageAndTheClock(double remaining, double timeRemaining, PaceStatus expected) =>
        Assert.Equal(expected, DialForecast.Pace(remaining, SessionResetWith(timeRemaining), DialForecast.SessionWindowSeconds, Now));

    [Fact]
    public void Pace_WithNoResetTime_IsUnknown() =>
        Assert.Equal(PaceStatus.Unknown, DialForecast.Pace(50, null, DialForecast.SessionWindowSeconds, Now));

    [Fact]
    public void Pace_WithAPastResetTime_IsUnknown() =>
        Assert.Equal(PaceStatus.Unknown, DialForecast.Pace(50, Now.AddHours(-1), DialForecast.SessionWindowSeconds, Now));

    [Fact]
    public void Pace_WithAResetBeyondTheWindow_ClampsTheClockAtFull()
    {
        // Clock skew can put the reset further out than the window is long; the time remaining is
        // capped at 100 rather than producing a delta above 100.
        var reset = Now.AddSeconds(DialForecast.SessionWindowSeconds * 3);
        Assert.Equal(PaceStatus.Danger, DialForecast.Pace(50, reset, DialForecast.SessionWindowSeconds, Now));
    }

    [Fact]
    public void Pace_FortyUsedWithSixtyElapsed_IsOnTrack()
    {
        // Covers AE8: sixty percent of the window gone, sixty percent of the quota left.
        var reset = SessionResetWith(40);
        Assert.Equal(PaceStatus.OnTrack, DialForecast.Pace(60, reset, DialForecast.SessionWindowSeconds, Now));
    }

    // --- The Session dial defers to the week, unless the session itself is the nearer wall ------

    [Fact]
    public void SessionPace_WhenTheWeekBinds_DefersToIt()
    {
        var reading = Reading(session: 100, weekly: 6, ratio: PlanRatio.Max5x, sessionReset: SessionResetWith(80));
        Assert.True(reading.IsSessionWeeklyLimited);
        Assert.Equal(PaceStatus.WeeklyLimited, DialForecast.SessionPace(reading, Now));
    }

    [Fact]
    public void SessionPace_WhenTheRawSessionIsInDanger_SaysSoInsteadOfDeferring()
    {
        // A nearer concrete wall must not be hidden behind "Limited by weekly".
        var reading = Reading(session: 5, weekly: 6, ratio: PlanRatio.Max5x, sessionReset: SessionResetWith(90));
        Assert.Equal(PaceStatus.Danger, DialForecast.SessionPace(reading, Now));
    }

    [Fact]
    public void SessionPace_GradesTheRawSessionValue_NotTheWeeklyCappedOne()
    {
        // The display value is a weekly percentage on a weekly clock; grading it over the five-hour
        // window would invent a pace that means nothing.
        var reading = Reading(session: 100, weekly: 6, ratio: PlanRatio.Max5x, sessionReset: SessionResetWith(100));
        Assert.Equal(75.76, reading.SessionDisplayRemaining, 2);
        Assert.Equal(PaceStatus.WeeklyLimited, DialForecast.SessionPace(reading, Now));
    }

    // --- The words -------------------------------------------------------------------------------

    [Theory]
    [InlineData(PaceStatus.OnTrack, "On Track")]
    [InlineData(PaceStatus.Caution, "Caution")]
    [InlineData(PaceStatus.Danger, "Danger")]
    [InlineData(PaceStatus.WeeklyLimited, "Limited by weekly")]
    [InlineData(PaceStatus.Unknown, null)]
    public void PaceCaption_IsTheMacsWording(PaceStatus status, string? expected) =>
        Assert.Equal(expected, DialForecast.PaceCaption(status));

    // --- Colours ---------------------------------------------------------------------------------

    [Theory]
    [InlineData(19.9, PaceStatus.OnTrack, UsageColor.Red)]    // the red floor beats the pace
    [InlineData(0, PaceStatus.OnTrack, UsageColor.Red)]
    [InlineData(20, PaceStatus.OnTrack, UsageColor.Green)]    // exactly at the floor is not below it
    [InlineData(50, PaceStatus.Caution, UsageColor.Orange)]
    [InlineData(50, PaceStatus.Danger, UsageColor.Red)]
    [InlineData(50, PaceStatus.WeeklyLimited, UsageColor.Green)] // no pace to follow: the level colour
    [InlineData(30, PaceStatus.Unknown, UsageColor.Orange)]
    public void RingColor_HasARedFloorThenFollowsThePace(double remaining, PaceStatus pace, UsageColor expected) =>
        Assert.Equal(expected, DialForecast.RingColor(remaining, pace));

    [Theory]
    [InlineData(19.9, PaceStatus.WeeklyLimited, UsageColor.Red)]
    [InlineData(50, PaceStatus.WeeklyLimited, UsageColor.Muted)]
    [InlineData(50, PaceStatus.OnTrack, UsageColor.Green)]
    public void PaceCaptionColor_SharesTheRingsRedFloor(double remaining, PaceStatus pace, UsageColor expected) =>
        Assert.Equal(expected, DialForecast.PaceCaptionColor(remaining, pace));

    // --- Notches ---------------------------------------------------------------------------------

    [Theory]
    [InlineData(5, 4)]
    [InlineData(7, 6)]
    public void TicksAreInteriorOnly(int tickCount, int expectedNotches)
    {
        // An N-segment dial has N-1 dividers: the ends of the arc are where it starts and stops.
        var card = new GaugeCard
        {
            Title = "Session",
            RemainingPercent = 50,
            Color = UsageColor.Green,
            TickCount = tickCount,
            Pace = PaceStatus.OnTrack,
        };

        var geometry = (System.Windows.Media.GeometryGroup)new ClaudeBatteryWin.Views.GaugeTicksConverter()
            .Convert(card, typeof(System.Windows.Media.Geometry), null, System.Globalization.CultureInfo.InvariantCulture)!;

        Assert.Equal(expectedNotches, geometry.Children.Count);
    }

    // --- Run-out ---------------------------------------------------------------------------------

    [Fact]
    public void RunOut_TenPercentLeftWithThreeHoursToGo_ProjectsSoonerThanTheReset()
    {
        // Covers AE12.
        var reset = Now.AddHours(3);
        var pace = DialForecast.Pace(10, reset, DialForecast.SessionWindowSeconds, Now);
        Assert.Equal(PaceStatus.Danger, pace);

        var seconds = DialForecast.RunOutSeconds(10, reset, DialForecast.SessionWindowSeconds, pace, Now);
        Assert.NotNull(seconds);
        Assert.True(seconds < 3 * 3600, $"projected {seconds} seconds, which is not before the reset");

        var quantised = DialForecast.QuantiseRunOut(seconds!.Value, DialForecast.SessionWindowSeconds);
        Assert.Equal(0, quantised % 300); // five-minute steps on the session window
        Assert.StartsWith("Out in ~", DialForecast.RunOutLine(quantised), StringComparison.Ordinal);
    }

    [Fact]
    public void RunOut_OnTheWeeklyWindow_QuantisesToTheHour()
    {
        var quantised = DialForecast.QuantiseRunOut(7300, DialForecast.WeeklyWindowSeconds);
        Assert.Equal(7200, quantised);
    }

    [Fact]
    public void RunOut_NeverRoundsAwayToNothing()
    {
        Assert.Equal(300, DialForecast.QuantiseRunOut(10, DialForecast.SessionWindowSeconds));
        Assert.Equal(3600, DialForecast.QuantiseRunOut(10, DialForecast.WeeklyWindowSeconds));
    }

    [Fact]
    public void RunOut_HiddenWhenThePaceIsOnTrack() =>
        Assert.Null(DialForecast.RunOutSeconds(
            80, Now.AddHours(1), DialForecast.SessionWindowSeconds, PaceStatus.OnTrack, Now));

    [Fact]
    public void RunOut_HiddenEarlyInTheWindow()
    {
        // A burst of use in the first minutes divides by almost no elapsed time.
        var reset = SessionResetWith(95); // only five percent elapsed
        Assert.Null(DialForecast.RunOutSeconds(
            50, reset, DialForecast.SessionWindowSeconds, PaceStatus.Danger, Now));
    }

    [Fact]
    public void RunOut_HiddenWhenNothingIsLeft() =>
        Assert.Null(DialForecast.RunOutSeconds(
            0, SessionResetWith(50), DialForecast.SessionWindowSeconds, PaceStatus.Danger, Now));

    [Fact]
    public void RunOut_HiddenWhenTheResetIsPastOrAbsent()
    {
        Assert.Null(DialForecast.RunOutSeconds(50, null, DialForecast.SessionWindowSeconds, PaceStatus.Danger, Now));
        Assert.Null(DialForecast.RunOutSeconds(50, Now.AddHours(-1), DialForecast.SessionWindowSeconds, PaceStatus.Danger, Now));
    }

    [Fact]
    public void RunOut_HiddenWhenTheResetIsFurtherOutThanTheWindowIsLong() =>
        Assert.Null(DialForecast.RunOutSeconds(
            50, Now.AddSeconds(DialForecast.SessionWindowSeconds * 2), DialForecast.SessionWindowSeconds,
            PaceStatus.Danger, Now));

    // --- The three lines -------------------------------------------------------------------------

    [Fact]
    public void DialLines_WithNoResetTime_SayOnlyThat()
    {
        var lines = DialForecast.DialLines(PaceStatus.Danger, 10, null, DialForecast.SessionWindowSeconds, Now);

        Assert.Equal("Reset time unavailable", lines.Countdown);
        Assert.Null(lines.Caption);
        Assert.Null(lines.RunOut);
        Assert.Null(lines.ResetSeconds);
    }

    [Fact]
    public void DialLines_CountdownIsAlwaysPresent()
    {
        var lines = DialForecast.DialLines(
            PaceStatus.OnTrack, 80, Now.AddHours(2).AddMinutes(14), DialForecast.SessionWindowSeconds, Now);

        Assert.Equal("Resets in 2h 14m", lines.Countdown);
        Assert.Equal("On Track", lines.Caption);
        Assert.Null(lines.RunOut);
    }

    [Fact]
    public void DialLines_DropARunOutThatWouldLandAfterTheReset()
    {
        // The pace is graded when a poll returns, while these lines re-print every minute, so a stale
        // verdict could otherwise project past a reset the countdown says is nearer.
        var reset = Now.AddMinutes(2);
        var lines = DialForecast.DialLines(PaceStatus.Danger, 90, reset, DialForecast.SessionWindowSeconds, Now);

        Assert.Null(lines.RunOut);
    }

    // --- The countdown format --------------------------------------------------------------------

    [Theory]
    [InlineData(3 * 86400 + 30, "3d 00h")]
    [InlineData(2 * 3600 + 14 * 60, "2h 14m")]
    [InlineData(5 * 60, "5m")]
    [InlineData(59, "<1m")]
    [InlineData(0, "<1m")]
    public void MinuteResolution_MatchesTheMacsShapes(double seconds, string expected) =>
        Assert.Equal(expected, CountdownFormat.MinuteResolution(seconds));

    // --- What a screen reader says ----------------------------------------------------------------

    [Theory]
    [InlineData(90, "1 minute")]
    [InlineData(2 * 3600 + 30 * 60, "2 hours 30 minutes")]
    [InlineData(3 * 86400, "3 days")]
    [InlineData(30, "less than a minute")]
    public void SpokenDuration_IsInWordsAndTruncatesLikeThePrintedLine(double seconds, string expected) =>
        Assert.Equal(expected, DialForecast.SpokenDuration(seconds));

    [Fact]
    public void AccessibilityLabel_SaysTheWholeDialInOneSentence()
    {
        var reset = Now.AddHours(2);
        var lines = DialForecast.DialLines(PaceStatus.OnTrack, 76, reset, DialForecast.SessionWindowSeconds, Now);

        var label = DialForecast.GaugeAccessibilityLabel("Session", 76, 40, PaceStatus.OnTrack, lines);

        Assert.Equal("Session usage 76 percent, time remaining 40 percent, on track, resets in 2 hours", label);
    }

    [Fact]
    public void AccessibilityLabel_WithNoResetTime_SaysSo()
    {
        var lines = DialForecast.DialLines(PaceStatus.Unknown, 76, null, DialForecast.SessionWindowSeconds, Now);
        var label = DialForecast.GaugeAccessibilityLabel("Weekly", 76, null, PaceStatus.Unknown, lines);

        Assert.Equal("Weekly usage 76 percent, reset time unavailable", label);
    }

    [Fact]
    public void AccessibilityLabel_IncludesTheRunOutWhenThereIsOne()
    {
        var reset = Now.AddHours(3);
        var pace = DialForecast.Pace(10, reset, DialForecast.SessionWindowSeconds, Now);
        var lines = DialForecast.DialLines(pace, 10, reset, DialForecast.SessionWindowSeconds, Now);

        var label = DialForecast.GaugeAccessibilityLabel("Session", 10, 60, pace, lines);

        Assert.Contains("projected to run out in about", label, StringComparison.Ordinal);
        Assert.Contains("danger, over pace", label, StringComparison.Ordinal);
    }

    // --- The assembled card ------------------------------------------------------------------------

    [Fact]
    public void GaugeCard_CarriesBothRingsAndAllThreeLines()
    {
        var reset = Now.AddHours(2);
        var card = FlyoutViewModel.MakeGaugeCard(
            title: "Session",
            remaining: 76,
            rawRemaining: 76,
            resetsAt: reset,
            windowSeconds: DialForecast.SessionWindowSeconds,
            tickCount: 5,
            pace: DialForecast.Pace(76, reset, DialForecast.SessionWindowSeconds, Now),
            isWeeklyLimited: false,
            now: Now);

        Assert.Equal("76%", card.PercentLabel);
        Assert.True(card.HasTimeRing);
        Assert.Equal("40%", card.TimeRemainingLabel);
        Assert.Equal("On Track", card.PaceCaption);
        Assert.Equal("Resets in 2h 00m", card.Countdown);
        Assert.False(card.HasRunOutLine);
        Assert.Contains("Session usage 76 percent", card.AccessibilityLabel, StringComparison.Ordinal);
    }

    [Fact]
    public void GaugeCard_WithNoResetTime_HasNoInnerRingAndNoPaceWord()
    {
        var card = FlyoutViewModel.MakeGaugeCard(
            title: "Weekly",
            remaining: 60,
            rawRemaining: 60,
            resetsAt: null,
            windowSeconds: DialForecast.WeeklyWindowSeconds,
            tickCount: 7,
            pace: PaceStatus.Unknown,
            isWeeklyLimited: false,
            now: Now);

        Assert.False(card.HasTimeRing);
        Assert.False(card.HasPaceCaption);
        Assert.Equal("Reset time unavailable", card.Countdown);
    }
}
