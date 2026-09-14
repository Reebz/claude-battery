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
}
