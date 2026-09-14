namespace ClaudeBatteryWin.Models;

/// <summary>
/// One poll's numbers together with the conversion factor that applies to them (KTD9).
///
/// The problem this solves: a user whose week is nearly gone still has a full five-hour session
/// window, so the Session dial reads 100 while the thing actually stopping them is the week. Every
/// surface that shows a session number - the panel dial, the tray icon, the tooltip - has to show the
/// same corrected figure, or the app contradicts itself.
///
/// So the correction is computed once, here, and all three read it from the same object.
/// <see cref="UsageSnapshot"/> stays exactly what the server said; nothing overwrites the raw session
/// value, which is what the pace verdict and the run-out estimate read.
/// </summary>
/// <param name="Snapshot">What the server returned.</param>
/// <param name="PlanRatio">
/// How much session capacity a point of weekly capacity is worth for this account, or null when the
/// plan is unknown and no conversion is possible.
/// </param>
public sealed record UsageReading(UsageSnapshot Snapshot, double? PlanRatio)
{
    /// <summary>
    /// What the remaining week is worth in session units, or null when it cannot be told.
    ///
    /// An exhausted week converts to zero on every plan, so that case is answered before the plan is
    /// even consulted: a user with no week left should see zero whether or not the app knows which
    /// plan they are on.
    /// </summary>
    public double? WeeklyRemainingInSessionUnits
    {
        get
        {
            if (Snapshot.WeeklyRemaining <= 0)
            {
                return 0;
            }
            if (PlanRatio is not { } ratio || ratio <= 0)
            {
                return null;
            }
            return Clamp(Snapshot.WeeklyRemaining / ratio);
        }
    }

    /// <summary>
    /// True when the week is the binding limit rather than the session window. False whenever it
    /// cannot be told, so this is never a guess - and false when both are already empty, because
    /// nothing is limiting anything at that point.
    /// </summary>
    public bool IsSessionWeeklyLimited =>
        WeeklyRemainingInSessionUnits is { } converted && converted < Snapshot.SessionRemaining;

    /// <summary>
    /// The session number every surface displays: the smaller of the true session reading and what
    /// the week converts to. With no usable conversion this is simply the true reading.
    /// </summary>
    public double SessionDisplayRemaining =>
        WeeklyRemainingInSessionUnits is { } converted
            ? Math.Min(Snapshot.SessionRemaining, converted)
            : Snapshot.SessionRemaining;

    private static double Clamp(double value) => Math.Max(0, Math.Min(100, value));
}
