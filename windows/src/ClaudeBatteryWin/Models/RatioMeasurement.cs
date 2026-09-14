namespace ClaudeBatteryWin.Models;

/// <summary>
/// What one account has learned about its own weekly-to-session conversion, by watching how much of
/// each limit it actually spends over time (R13).
///
/// The published ratio for a plan is a starting point, not the truth: the real figure differs per
/// account and the published ones can go stale. So each account keeps a running count of how much
/// session capacity and how much weekly capacity it has consumed, and once there is enough of it the
/// measured ratio replaces the published one.
///
/// Persisted on the account as plain metadata. It is null for every account stored before this
/// existed, and starts accumulating from that account's next poll. U5 adds the accumulation and the
/// trust rules; this record is the shape they write into, and the field the plan-change rule in
/// <c>AccountStore.UpdatePlan</c> clears.
/// </summary>
public sealed record RatioMeasurement
{
    /// <summary>Session percentage remaining at the last reading.</summary>
    public double LastSessionRemaining { get; init; }

    /// <summary>When the session window at the last reading was due to reset. Null when the response
    /// carried no reset time, which is what stops a fabricated reading from being accumulated.</summary>
    public DateTimeOffset? LastSessionResetsAt { get; init; }

    /// <summary>Weekly percentage remaining at the last reading.</summary>
    public double LastWeeklyRemaining { get; init; }

    /// <summary>When the weekly window at the last reading was due to reset.</summary>
    public DateTimeOffset? LastWeeklyResetsAt { get; init; }

    /// <summary>Running total of session percentage consumed across clean intervals.</summary>
    public double SessionPointsConsumed { get; init; }

    /// <summary>Running total of weekly percentage consumed across clean intervals.</summary>
    public double WeeklyPointsConsumed { get; init; }

    /// <summary>
    /// How much weekly capacity has to be watched before a measured ratio is believed at all. Below
    /// this the published figure for the plan is the better number.
    /// </summary>
    public const double ConfidenceBar = 30;

    /// <summary>
    /// The band a measured ratio has to land in. Easiest to read as how many five-hour windows a
    /// week's capacity would hold: the upper end is two a week, the lower end a hundred. It is
    /// deliberately far wider than the published table, because it is not a second opinion on the
    /// table - it is there to catch a measurement that is not measuring anything.
    /// </summary>
    public const double PlausibleMin = 0.01;

    /// <inheritdoc cref="PlausibleMin"/>
    public const double PlausibleMax = 0.5;

    /// <summary>
    /// The measured ratio, or null while there is no reason to trust one. Null is the normal state
    /// for a long time after install, and the caller falls back to the published figure.
    /// </summary>
    public double? Ratio
    {
        get
        {
            // The session total is guarded only because this is a division: the same spend drives
            // both percentages, so a weekly total past the bar with nothing on the session side is
            // not a state real usage produces.
            if (WeeklyPointsConsumed < ConfidenceBar || SessionPointsConsumed <= 0)
            {
                return null;
            }

            var measured = WeeklyPointsConsumed / SessionPointsConsumed;
            return measured >= PlausibleMin && measured <= PlausibleMax ? measured : null;
        }
    }

    /// <summary>
    /// Folds one poll's reading in and hands back the new state.
    ///
    /// An interval only counts when both windows are the same ones as last time and neither
    /// remainder went up. A window that rolled over spans two windows, so the difference across it
    /// is not consumption; a remainder that rose means the server corrected something. Either way
    /// that one interval is dropped rather than repaired, because a bad interval corrupts the totals
    /// permanently.
    ///
    /// Replacing the stored reading matters as much as not accumulating: without it the next poll
    /// would be measured against a reading from the window before last.
    /// </summary>
    public static RatioMeasurement Updated(
        RatioMeasurement? previous,
        double sessionRemaining,
        DateTimeOffset? sessionResetsAt,
        double weeklyRemaining,
        DateTimeOffset? weeklyResetsAt)
    {
        var sample = new RatioMeasurement
        {
            LastSessionRemaining = sessionRemaining,
            LastSessionResetsAt = sessionResetsAt,
            LastWeeklyRemaining = weeklyRemaining,
            LastWeeklyResetsAt = weeklyResetsAt,
            SessionPointsConsumed = previous?.SessionPointsConsumed ?? 0,
            WeeklyPointsConsumed = previous?.WeeklyPointsConsumed ?? 0,
        };

        if (previous is null
            || !SameWindow(previous.LastSessionResetsAt, sessionResetsAt)
            || !SameWindow(previous.LastWeeklyResetsAt, weeklyResetsAt))
        {
            return sample;
        }

        var sessionConsumed = previous.LastSessionRemaining - sessionRemaining;
        var weeklyConsumed = previous.LastWeeklyRemaining - weeklyRemaining;
        if (sessionConsumed < 0 || weeklyConsumed < 0)
        {
            return sample;
        }

        return sample with
        {
            SessionPointsConsumed = sample.SessionPointsConsumed + sessionConsumed,
            WeeklyPointsConsumed = sample.WeeklyPointsConsumed + weeklyConsumed,
        };
    }

    /// <summary>
    /// Whether two reset times describe the same window.
    ///
    /// A missing time is never a match. With no reset time there is no way to tell a rollover from
    /// ordinary use, so an account whose responses carry none accumulates nothing and keeps the
    /// published figure.
    ///
    /// Compared with a one-second tolerance rather than exactly, because the same instant reaches
    /// the app in four different shapes and a sub-second difference between two of them is not a new
    /// window. A real rollover moves this by hours.
    /// </summary>
    public static bool SameWindow(DateTimeOffset? a, DateTimeOffset? b) =>
        a is { } first && b is { } second && Math.Abs((first - second).TotalSeconds) < 1;
}
