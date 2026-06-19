namespace ClaudeBatteryWin.Models;

/// <summary>
/// A monetary amount in minor units. Mirrors the Mac <c>Money</c> struct
/// (Services/UsageService.swift, KTD4). Convert to major units exactly once at the derivation
/// boundary (<c>amountMinor / 10^exponent</c>), never at display, to guard the documented 100x
/// cents-vs-dollars bug.
/// </summary>
public sealed record Money
{
    /// JSON key <c>amount_minor</c>.
    public double? AmountMinor { get; init; }
    public string? Currency { get; init; }
    public int? Exponent { get; init; }

    /// Major-unit value. Exponent defaults to 2 (cents) when absent, matching the Mac.
    public double ToMajor()
    {
        var exponent = Exponent ?? 2;
        return (AmountMinor ?? 0) / Math.Pow(10.0, exponent);
    }
}

/// <summary>
/// The newer <c>/usage</c> <c>spend</c> object: monthly extra-usage spend plus enabled/disabled
/// state. Mirrors the Mac <c>SpendInfo</c>. <see cref="Percent"/> can exceed 100 (KTD7). All
/// fields optional/lenient.
/// </summary>
public sealed record SpendInfo
{
    public Money? Used { get; init; }
    public Money? Limit { get; init; }
    public double? Percent { get; init; }
    public string? Severity { get; init; }
    public bool? Enabled { get; init; }

    /// JSON key <c>disabled_reason</c>.
    public string? DisabledReason { get; init; }
}
