namespace ClaudeBatteryWin.Models;

/// <summary>
/// Raw decoded body of <c>GET /api/organizations/{orgId}/usage</c>. Mirrors the Mac
/// <c>UsageResponse</c> (Services/UsageService.swift). Carries both the legacy per-tier fields
/// and the newer <c>limits[]</c>/<c>spend</c> shape; the resolver (U4) prefers the newer shape
/// and falls back to the legacy tiers (KTD1). Every field is optional so a shape drift degrades
/// rather than throwing the whole decode.
///
/// The transport (U3) decodes this; the resolver (U4) turns it into a <see cref="UsageSnapshot"/>.
/// </summary>
public sealed record UsageApiResponse
{
    // Legacy per-tier fields (snake_case in JSON: five_hour, seven_day, seven_day_opus, ...).
    public UsageTier? FiveHour { get; init; }
    public UsageTier? SevenDay { get; init; }
    public UsageTier? SevenDayOpus { get; init; }
    public UsageTier? SevenDaySonnet { get; init; }
    public ExtraUsageTier? ExtraUsage { get; init; }

    // Newer shape. Absent on legacy bodies; the resolver prefers these.
    public IReadOnlyList<UsageLimit>? Limits { get; init; }
    public SpendInfo? Spend { get; init; }
}

/// <summary>
/// A legacy per-tier usage entry. Mirrors the Mac <c>UsageTier</c>. <see cref="Utilization"/>
/// is a used percentage (the resolver computes remaining as 100 - utilization).
/// </summary>
public sealed record UsageTier
{
    public double? Utilization { get; init; }

    /// Tolerantly parsed across ISO8601 and UNIX-epoch forms (KTD2).
    public DateTimeOffset? ResetsAt { get; init; }
}

/// <summary>Legacy extra-usage tier. Mirrors the Mac <c>ExtraUsageTier</c>.</summary>
public sealed record ExtraUsageTier
{
    public bool? IsEnabled { get; init; }
    public double? MonthlyLimit { get; init; }
    public double? UsedCredits { get; init; }
    public double? Utilization { get; init; }
}
