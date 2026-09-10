namespace ClaudeBatteryWin.Models;

/// <summary>
/// Raw response from <c>GET /api/organizations/{orgId}/prepaid/credits</c>. Mirrors the Mac
/// <c>PrepaidCreditsResponse</c> (Services/UsageService.swift). <see cref="Amount"/> is the
/// balance in minor units (cents); <see cref="Currency"/> drives currency-aware formatting
/// (KTD6). Unknown keys (auto-reload settings, pending invoice, etc.) are ignored by the
/// lenient decode. This fetch degrades silently to null on failure (R13).
/// </summary>
public sealed record Credits
{
    /// Balance in minor units. The Mac divides by 100 to derive the major-unit balance.
    public double? Amount { get; init; }
    public string? Currency { get; init; }
}

/// <summary>
/// State of the credits/spend display, mirroring the Mac <c>UsageCreditsData.State</c>: either
/// an enabled spend line, or a disabled/paused reason.
/// </summary>
public enum CreditsStateKind
{
    None,
    Enabled,
    Disabled
}

/// <summary>
/// Unified credits display model, mirroring the Mac <c>UsageCreditsData</c> (KTD5).
/// <see cref="StateKind"/> reflects the <c>spend</c> object; <see cref="BalanceMajor"/> is the
/// prepaid balance, shown whenever positive, independent of state.
///
/// For <see cref="CreditsStateKind.Enabled"/>: <see cref="Spent"/>, <see cref="SpendLimit"/>,
/// <see cref="SpendPercent"/> (uncapped, KTD7), and <see cref="SpendCurrency"/> are populated.
/// For <see cref="CreditsStateKind.Disabled"/>: <see cref="DisabledReason"/> is populated.
/// </summary>
public sealed record UsageCredits
{
    public CreditsStateKind StateKind { get; init; } = CreditsStateKind.None;

    // Enabled-state fields.
    public double Spent { get; init; }
    public double? SpendLimit { get; init; }

    /// Uncapped spend percentage (can exceed 100); the bar fill clamps at display.
    public double SpendPercent { get; init; }
    public string SpendCurrency { get; init; } = "USD";

    // Disabled-state field.
    public string? DisabledReason { get; init; }

    /// Provisional monthly reset; the captured (disabled) shape carries no reset field, so the
    /// Mac derives it at display until a credits-enabled capture confirms the real field (A3).
    public DateTimeOffset? StateResetDate { get; init; }

    // Balance (independent of state).
    public double? BalanceMajor { get; init; }
    public string BalanceCurrency { get; init; } = "USD";
}
