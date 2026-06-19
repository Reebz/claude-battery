namespace ClaudeBatteryWin.Models;

/// <summary>
/// The resolved usage picture for one account at one point in time. This is the shared
/// contract every consumer (icon renderer U9, flyout view-model U10, notifier U11) reads from;
/// the polling/parsing layer (U4) produces it from the raw <c>/usage</c> + <c>/credits</c>
/// responses, preferring the newer <c>limits[]</c>/<c>spend</c> shape over the legacy tier
/// fields. Mirrors the Mac <c>UsageData</c> (Services/UsageService.swift).
///
/// Remaining values are stored as remaining percentages (100 - utilization), clamped 0-100,
/// matching the Mac. Reset dates are tolerantly parsed and may be null ("reset times
/// unavailable").
/// </summary>
public sealed record UsageSnapshot
{
    /// Weekly (all-model) remaining percentage, 0-100.
    public required double WeeklyRemaining { get; init; }
    public DateTimeOffset? WeeklyResetDate { get; init; }

    /// Session (five-hour) remaining percentage, 0-100.
    public required double SessionRemaining { get; init; }
    public DateTimeOffset? SessionResetDate { get; init; }

    /// Per-model weekly bars ("All Models"). Empty when no per-model limits are present, in
    /// which case the flyout omits the Models card and Resets spans full width.
    public IReadOnlyList<ModelUsage> ModelUsages { get; init; } = Array.Empty<ModelUsage>();

    /// Credits/spend line. Null when neither a spend object nor a positive prepaid balance exists.
    public UsageCredits? Credits { get; init; }
}
