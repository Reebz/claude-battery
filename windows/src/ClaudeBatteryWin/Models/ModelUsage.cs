namespace ClaudeBatteryWin.Models;

/// <summary>
/// One model's weekly usage, derived from a <c>weekly_scoped</c> limit (or the legacy
/// <c>seven_day_*</c> fields). Mirrors the Mac <c>ModelUsage</c> (Services/UsageService.swift).
/// Absence of data means no entry, never a fabricated 100% bar (KTD3).
/// </summary>
public sealed record ModelUsage
{
    public required string DisplayName { get; init; }

    /// Remaining percentage, clamped 0-100.
    public required double RemainingPercent { get; init; }

    public DateTimeOffset? ResetDate { get; init; }

    /// API model id when present; identity prefers it over the human label so two scoped limits
    /// sharing a display name do not collide.
    public string? ModelId { get; init; }

    /// Stable identity: the model id when present, else the display name.
    public string Id => ModelId ?? DisplayName;
}
