using ClaudeBatteryWin.Icons;

namespace ClaudeBatteryWin.ViewModels;

/// <summary>
/// How fast usage is going compared with the clock (R27).
///
/// A percentage on its own does not answer the question a user actually has. Forty percent left
/// sounds bad with six hours of the window to go and is fine with twenty minutes. This grades the
/// gap between the two, which is exactly the gap between the two rings on the dial.
/// </summary>
public enum PaceStatus
{
    /// <summary>Using no faster than the clock, or slower. Includes being ahead.</summary>
    OnTrack,

    /// <summary>Running ahead of the clock, enough to be worth noticing.</summary>
    Caution,

    /// <summary>Well ahead of the clock, or nothing left at all.</summary>
    Danger,

    /// <summary>The weekly quota is the binding limit, so the session window has no pace to grade.</summary>
    WeeklyLimited,

    /// <summary>No reset time, so there is nothing to compare against. The caption is hidden.</summary>
    Unknown,
}

/// <summary>
/// The rules behind what a dial says: the pace word, the colours, the run-out estimate, and the
/// three lines underneath (R27, R28, R51, R52, R53). Ported from the Mac rule for rule.
///
/// Everything here is a pure function of one snapshot plus the current time, so the panel can
/// re-print on a one-minute clock without re-polling, and every value is testable without a window.
/// </summary>
public static class DialForecast
{
    /// <summary>Session window: five hours, which is why the session dial has five notches.</summary>
    public const double SessionWindowSeconds = 5 * 3600;

    /// <summary>Weekly window: seven days.</summary>
    public const double WeeklyWindowSeconds = 7 * 24 * 3600;

    /// <summary>At or above this many points ahead of the clock, the pace is Caution.</summary>
    public const double CautionDelta = 10;

    /// <summary>At or above this many points ahead of the clock, the pace is Danger.</summary>
    public const double DangerDelta = 25;

    /// <summary>Below this much remaining, the ring is red whatever the pace says. The tray icon
    /// goes red at the same number, so the icon and the panel agree about "nearly empty".</summary>
    public const double LowRemainingThreshold = 20;

    /// <summary>
    /// Below this fraction of the window elapsed, no run-out is projected. A burst of use in the
    /// first minutes of a fresh window divides by almost no elapsed time and projects a run-out
    /// minutes away, which is alarming and wrong.
    /// </summary>
    public const double MinElapsedFraction = 0.10;

    /// <summary>The line a dial shows instead of a countdown when it has no reset time.</summary>
    public const string ResetUnavailableLine = "Reset time unavailable";

    // --- Time and pace --------------------------------------------------------------------------

    /// <summary>
    /// How much of the window is left, as a percentage counting down to zero. The response gives
    /// only the reset time, so the window start is that minus the window length.
    /// </summary>
    public static double? TimeRemainingPercent(DateTimeOffset? resetsAt, double windowSeconds, DateTimeOffset now)
    {
        if (resetsAt is not { } reset || CountdownFormat.RemainingSeconds(reset, now) is not { } remaining)
        {
            return null;
        }

        return Math.Max(0, Math.Min(100, remaining / windowSeconds * 100));
    }

    /// <summary>
    /// The pace for one window. The delta is how much longer the inner time ring is than the outer
    /// usage ring, so the word names a gap the user can see. Nothing left is Danger whatever the
    /// clock says; being ahead of pace is always On Track.
    /// </summary>
    public static PaceStatus Pace(double remainingPercent, DateTimeOffset? resetsAt, double windowSeconds, DateTimeOffset now)
    {
        if (resetsAt is not { } reset || CountdownFormat.RemainingSeconds(reset, now) is not { } remaining)
        {
            return PaceStatus.Unknown;
        }
        if (remainingPercent <= 0)
        {
            return PaceStatus.Danger;
        }

        var timeRemaining = Math.Min(100, remaining / windowSeconds * 100);
        var delta = timeRemaining - remainingPercent;

        if (delta >= DangerDelta)
        {
            return PaceStatus.Danger;
        }
        return delta >= CautionDelta ? PaceStatus.Caution : PaceStatus.OnTrack;
    }

    /// <summary>
    /// The Session dial's pace. When the week is the binding limit the session defers to it, unless
    /// the true five-hour window is itself in Danger: that is a nearer wall and must not be hidden
    /// behind "Limited by weekly".
    ///
    /// The pace always grades the raw session value over the five-hour window, never the
    /// weekly-capped display value, which is a weekly percentage on a weekly clock and would invent
    /// a pace that means nothing.
    /// </summary>
    public static PaceStatus SessionPace(Models.UsageReading reading, DateTimeOffset now)
    {
        var raw = Pace(reading.Snapshot.SessionRemaining, reading.Snapshot.SessionResetDate, SessionWindowSeconds, now);
        if (reading.IsSessionWeeklyLimited)
        {
            return raw == PaceStatus.Danger ? raw : PaceStatus.WeeklyLimited;
        }
        return raw;
    }

    /// <summary>The word under the dial. Null hides the line.</summary>
    public static string? PaceCaption(PaceStatus status) => status switch
    {
        PaceStatus.OnTrack => "On Track",
        PaceStatus.Caution => "Caution",
        PaceStatus.Danger => "Danger",
        PaceStatus.WeeklyLimited => "Limited by weekly",
        _ => null
    };

    // --- Colours --------------------------------------------------------------------------------

    /// <summary>The plain level scale: red, orange, green by how much is left.</summary>
    public static UsageColor BatteryColor(double remainingPercent)
    {
        var clamped = Math.Max(0, Math.Min(100, remainingPercent));
        if (clamped < LowRemainingThreshold)
        {
            return UsageColor.Red;
        }
        return clamped < 45 ? UsageColor.Orange : UsageColor.Green;
    }

    /// <summary>The colour of the pace word.</summary>
    public static UsageColor PaceColor(PaceStatus status) => status switch
    {
        PaceStatus.OnTrack => UsageColor.Green,
        PaceStatus.Caution => UsageColor.Orange,
        PaceStatus.Danger => UsageColor.Red,
        _ => UsageColor.Muted
    };

    /// <summary>
    /// The outer ring's colour (R53): red below the low threshold whatever the pace says, otherwise
    /// the pace colour so the ring and the word agree, and the level colour when there is no pace to
    /// follow.
    /// </summary>
    public static UsageColor RingColor(double remaining, PaceStatus pace)
    {
        if (remaining < LowRemainingThreshold)
        {
            return UsageColor.Red;
        }

        return pace switch
        {
            PaceStatus.OnTrack or PaceStatus.Caution or PaceStatus.Danger => PaceColor(pace),
            _ => BatteryColor(remaining)
        };
    }

    /// <summary>
    /// The pace word's colour: the ring's red floor first, so the word can never disagree with the
    /// ring, and "Limited by weekly" keeps its muted colour above the floor.
    /// </summary>
    public static UsageColor PaceCaptionColor(double remaining, PaceStatus pace) =>
        remaining < LowRemainingThreshold ? UsageColor.Red : PaceColor(pace);

    // --- Run-out --------------------------------------------------------------------------------

    /// <summary>
    /// Seconds until usage runs out at the current rate, or null when there is nothing sound to
    /// project (R51). It reads the pace rather than re-deriving it, so the word and the estimate
    /// cannot drift apart, and it only projects when the pace already says usage is ahead of the
    /// clock, which is what makes the estimate land before the reset.
    /// </summary>
    public static double? RunOutSeconds(
        double remainingPercent, DateTimeOffset? resetsAt, double windowSeconds, PaceStatus pace, DateTimeOffset now)
    {
        if (pace is not (PaceStatus.Caution or PaceStatus.Danger))
        {
            return null;
        }
        if (resetsAt is not { } reset || CountdownFormat.RemainingSeconds(reset, now) is not { } remaining)
        {
            return null;
        }
        if (remainingPercent <= 0 || remaining > windowSeconds)
        {
            return null;
        }

        var elapsedFraction = 1 - remaining / windowSeconds;
        if (elapsedFraction < MinElapsedFraction)
        {
            return null;
        }

        return (windowSeconds - remaining) * remainingPercent / (100 - remainingPercent);
    }

    /// <summary>
    /// Rounds a run-out to five minutes on the session window and an hour on the weekly one, never
    /// below one of those, so the shown value does not jitter with each poll's integer percentages.
    /// </summary>
    public static double QuantiseRunOut(double seconds, double windowSeconds)
    {
        var quantum = windowSeconds == WeeklyWindowSeconds ? 3600.0 : 300.0;
        return Math.Max(1, Math.Round(seconds / quantum, MidpointRounding.ToEven)) * quantum;
    }

    /// <summary>The run-out line, relative so it cannot be mistaken for a reset time.</summary>
    public static string? RunOutLine(double? seconds) =>
        seconds is { } value ? "Out in ~" + CountdownFormat.MinuteResolution(value) : null;

    // --- The three lines under a dial -----------------------------------------------------------

    /// <summary>
    /// What a dial says underneath: the pace word, the run-out estimate, and the reset countdown.
    /// The first two hide themselves when they have nothing to say; the countdown is always there.
    /// The durations ride along so the spoken sentence says the same numbers the lines print.
    /// </summary>
    public sealed record Lines
    {
        public string? Caption { get; init; }
        public string? RunOut { get; init; }
        public required string Countdown { get; init; }
        public double? ResetSeconds { get; init; }
        public double? RunOutSeconds { get; init; }
    }

    /// <summary>
    /// The lines for one dial. A dial with no usable reset time says only that, whatever the pace
    /// thinks, matching the missing inner ring.
    ///
    /// The run-out is dropped unless it still lands before the reset: the pace is graded when a poll
    /// returns while these lines re-print every minute, so a stale Caution could otherwise project
    /// past a reset the countdown says is nearer.
    /// </summary>
    public static Lines DialLines(
        PaceStatus pace, double rawRemaining, DateTimeOffset? resetsAt, double windowSeconds, DateTimeOffset now)
    {
        if (resetsAt is not { } reset || CountdownFormat.RemainingSeconds(reset, now) is not { } resetSeconds)
        {
            return new Lines { Countdown = ResetUnavailableLine };
        }

        double? runOut = RunOutSeconds(rawRemaining, resetsAt, windowSeconds, pace, now);
        if (runOut is { } raw)
        {
            var quantised = QuantiseRunOut(raw, windowSeconds);
            runOut = quantised < resetSeconds ? quantised : null;
        }

        return new Lines
        {
            Caption = PaceCaption(pace),
            RunOut = RunOutLine(runOut),
            Countdown = "Resets in " + CountdownFormat.MinuteResolution(resetSeconds),
            ResetSeconds = resetSeconds,
            RunOutSeconds = runOut,
        };
    }

    // --- What a screen reader says ---------------------------------------------------------------

    /// <summary>
    /// A duration in words, truncated to whole units exactly like the printed countdown, so the
    /// voice never says a number the line does not show.
    /// </summary>
    public static string SpokenDuration(double seconds)
    {
        var (days, hours, minutes) = CountdownFormat.Components(seconds);
        var parts = new List<string>();
        foreach (var (value, unit) in new[] { (days, "day"), (hours, "hour"), (minutes, "minute") })
        {
            if (value > 0)
            {
                parts.Add($"{value} {unit}{(value == 1 ? string.Empty : "s")}");
            }
        }
        return parts.Count == 0 ? "less than a minute" : string.Join(" ", parts);
    }

    /// <summary>
    /// One sentence per dial (R37). Each dial is spoken once, covering how much is left, how much of
    /// the window is left, the pace, and the two lines underneath, so the text lines themselves can
    /// stay out of the accessibility tree instead of being read as four disconnected fragments.
    ///
    /// The percentages round the way the dial's own label rounds, so the voice never says a number
    /// different from the one on screen.
    /// </summary>
    public static string GaugeAccessibilityLabel(
        string name, double usage, double? timeRemaining, PaceStatus pace, Lines? lines = null)
    {
        var parts = new List<string> { $"{name} usage {(int)Math.Round(usage, MidpointRounding.ToEven)} percent" };

        if (timeRemaining is { } time)
        {
            parts.Add($"time remaining {(int)Math.Round(time, MidpointRounding.ToEven)} percent");
        }

        switch (pace)
        {
            case PaceStatus.OnTrack: parts.Add("on track"); break;
            case PaceStatus.Caution: parts.Add("caution, over pace"); break;
            case PaceStatus.Danger: parts.Add("danger, over pace"); break;
            case PaceStatus.WeeklyLimited: parts.Add("limited by weekly"); break;
        }

        if (lines is not null)
        {
            if (lines.RunOutSeconds is { } runOut)
            {
                parts.Add($"projected to run out in about {SpokenDuration(runOut)}");
            }
            parts.Add(lines.ResetSeconds is { } reset
                ? $"resets in {SpokenDuration(reset)}"
                : ResetUnavailableLine.ToLowerInvariant());
        }

        return string.Join(", ", parts);
    }
}
