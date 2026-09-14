namespace ClaudeBatteryWin.Models;

/// <summary>
/// How much session capacity a week's capacity is worth, per plan.
///
/// A five-hour session window and a week's quota are measured in different units, so "6 percent of
/// the week left" cannot be compared to "100 percent of the session left" without a conversion
/// factor. These three figures are the published capacities divided out (R9, R11).
///
/// Any other plan string, including an unrecognised one, converts to nothing at all. That is
/// deliberate: Free publishes no capacity to divide by, a prepaid billing tier is not a plan, and an
/// unseen string could be a typo or a plan that does not exist yet. Showing the true session number
/// is right in all of those; guessing produces a confidently wrong one.
/// </summary>
public static class PlanRatio
{
    /// 550,000 / 5,000,000
    public const double Pro = 0.1100;

    /// 3,300,000 / 41,666,700
    public const double Max5x = 0.0792;

    /// 11,000,000 / 83,333,300
    public const double Max20x = 0.1320;

    /// <summary>
    /// How far a measured ratio may sit from the published one and still be believed. The widest
    /// disagreement in the source material is 1.39x and the three published ratios span 1.67x end to
    /// end, so two gives real headroom without accepting a measurement that must be wrong.
    /// </summary>
    public const double AgreementFactor = 2;

    /// <summary>The published ratio for a plan string, or null when there is none. Exact match.</summary>
    public static double? ForTier(string? tier) => tier switch
    {
        "default_claude_pro" => Pro,
        "default_claude_max_5x" => Max5x,
        "default_claude_max_20x" => Max20x,
        _ => null
    };

    /// <summary>
    /// Which ratio the dial actually uses. The account's own measurement wins when it agrees with
    /// the published figure for its plan, or when there is no published figure to check it against.
    /// A measurement that contradicts a known plan by more than the agreement factor is set aside for
    /// that reading, in either direction.
    /// </summary>
    public static double? Resolve(double? measured, string? tier)
    {
        var table = ForTier(tier);

        if (measured is not { } value)
        {
            return table;
        }
        if (table is not { } published)
        {
            return value;
        }

        var agrees = value <= published * AgreementFactor && value * AgreementFactor >= published;
        return agrees ? value : published;
    }
}
