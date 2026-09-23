using System.Drawing;

namespace ClaudeBatteryWin.Icons;

/// <summary>
/// What every tray icon style has to do (R39, KTD7).
///
/// The tray is repainted on every poll, every theme change and every minute tick, so the expensive
/// part is not drawing once - it is drawing when nothing changed. Each style compares its own
/// signature and returns null when the answer would be identical to the last one, and the caller
/// keeps the icon it already has.
/// </summary>
public interface ITrayIconRenderer : IDisposable
{
    /// <summary>
    /// The tray bitmap for this state, at this size, for the taskbar's theme, or null when nothing
    /// about it would differ from the last render.
    /// </summary>
    /// <param name="countdown">
    /// The compact session countdown. Only a style that draws it includes it in its signature; the
    /// others ignore it, so a countdown tick alone does not repaint them.
    /// </param>
    /// <param name="size">The shell's small-icon cell: 16, 24 or 32 pixels by display scaling.</param>
    Bitmap? Render(TrayRenderState state, ThemeBucket theme, string countdown, int size = 16);

    /// <summary>
    /// Forget the last signature so the next render always draws. Used after waking and after a
    /// display change, where the cached image may no longer be on screen at all.
    /// </summary>
    void ResetSignature();

    /// <summary>How many renders have been skipped since the last reset. The CPU-safety tests read
    /// it; a style whose signature never matches would show up here as a flat zero.</summary>
    long SuppressedCount { get; }
}

/// <summary>
/// The colours every tray style draws with (R38, KD9).
///
/// One tint that reads against the taskbar, and red when a side is nearly empty. The three-tier
/// green/orange/red scale the panel uses stays in the panel: at sixteen pixels it is a coloured dot,
/// not a reading.
/// </summary>
public static class TrayPalette
{
    /// <summary>Below this much left, a side is drawn red. Matches the Mac's tray rule.</summary>
    public const double LowRemainingThreshold = 20;

    /// <summary>The tint that reads against the taskbar: white on a dark one, black on a light one.</summary>
    public static Color BaseTint(ThemeBucket theme) => theme == ThemeBucket.Dark ? Color.White : Color.Black;

    /// <summary>The colour for one side of the icon: red when nearly empty, the base tint otherwise.</summary>
    public static Color Fill(double remainingPercent, Color baseColor)
    {
        var clamped = Math.Max(0, Math.Min(100, remainingPercent));
        return clamped < LowRemainingThreshold ? Color.Red : baseColor;
    }
}

/// <summary>The tray icon styles a user can choose between (R39, KD11).</summary>
public enum TrayIconStyle
{
    /// <summary>Two thin horizontal bars, session above weekly. The style the beta shipped.</summary>
    StackedBars,

    /// <summary>Two concentric arcs, matching the two-ring dials in the panel.</summary>
    DualArcGauge,
}

/// <summary>Display names and parsing for <see cref="TrayIconStyle"/>, shared by Settings and the
/// stored setting so the two cannot drift.</summary>
public static class TrayIconStyles
{
    public const string StackedBarsName = "Stacked Bars";
    public const string DualArcGaugeName = "Dual Arc Gauge";

    public static IReadOnlyList<string> AllNames { get; } = new[] { StackedBarsName, DualArcGaugeName };

    public static string NameOf(TrayIconStyle style) =>
        style == TrayIconStyle.DualArcGauge ? DualArcGaugeName : StackedBarsName;

    /// <summary>Reads a stored name. Anything unrecognised falls back to the default style rather
    /// than leaving the user with no icon.</summary>
    public static TrayIconStyle Parse(string? name) =>
        string.Equals(name, DualArcGaugeName, StringComparison.Ordinal)
            ? TrayIconStyle.DualArcGauge
            : TrayIconStyle.StackedBars;

    /// <summary>Builds the renderer for a style. The caller disposes the previous one: a fresh
    /// renderer has no signature yet, so the first paint after a change is never skipped.</summary>
    public static ITrayIconRenderer Create(TrayIconStyle style) => style switch
    {
        TrayIconStyle.DualArcGauge => new DualArcGaugeRenderer(),
        _ => new StackedBarsRenderer(),
    };
}
