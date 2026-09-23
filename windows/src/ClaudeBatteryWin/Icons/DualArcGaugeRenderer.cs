using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;

namespace ClaudeBatteryWin.Icons;

/// <summary>
/// Two concentric arcs in the tray: the week on the outside, the session on the inside (R39, KD11).
///
/// The same shape as the dials in the panel, so glancing at the tray and opening the panel show the
/// same picture rather than two unrelated ones. The gap at the bottom is what tells a full ring from
/// an empty one at sixteen pixels.
///
/// Colours follow the tray rule, not the panel's: one base tint for the taskbar's theme, red for a
/// side that is nearly empty, nothing else. Ported from the Mac renderer, scaled from its twenty
/// point canvas to the cell the shell actually gives us.
///
/// The status states carry the Mac's glyphs so they can be told apart: "!" at half strength for an
/// expired session or repeated failures, "..." at half strength for stale, "..." at full strength
/// for loading, and no glyph for signed out. The Mac draws the glyph to the right of the rings on a
/// wider canvas; the tray cell is square, so here it sits centred over the empty rings, the same way
/// the Stacked Bars style centres it over its hollow bar.
/// </summary>
public sealed class DualArcGaugeRenderer : ITrayIconRenderer
{
    // Proportions of the Mac's 20 point canvas, so the shape is the same at every cell size.
    private const float OuterRadiusRatio = 8f / 20f;
    private const float InnerRadiusRatio = 5f / 20f;
    private const float StrokeRatio = 2.5f / 20f;

    /// <summary>Bottom-left, in GDI+ degrees (clockwise from east).</summary>
    private const float StartAngle = 135f;

    /// <summary>Three quarters of the way round, leaving the gap at the bottom.</summary>
    private const float Sweep = 270f;

    /// <summary>How faint the unfilled part of each ring is.</summary>
    private const int TrackAlpha = 38; // the Mac's 0.15 opacity

    /// <summary>The status glyph's font size as a share of the cell, matching Stacked Bars.</summary>
    private const float StatusGlyphRatio = 0.55f;

    /// <summary>The monospace family Stacked Bars draws its status glyph in.</summary>
    private const string GlyphFamily = "Consolas";

    private RenderSignature? _lastSignature;

    public long SuppressedCount { get; private set; }

    public void ResetSignature() => _lastSignature = null;

    public void Dispose()
    {
        // Nothing held between renders: every bitmap belongs to the caller.
    }

    public Bitmap? Render(TrayRenderState state, ThemeBucket theme, string countdown, int size = 16)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(countdown);
        ArgumentOutOfRangeException.ThrowIfLessThan(size, 1);

        var signature = RenderSignature.For(state, theme, size);
        if (_lastSignature is { } last && last == signature)
        {
            SuppressedCount++;
            return null;
        }

        var baseColor = TrayPalette.BaseTint(theme);

        var bitmap = state switch
        {
            TrayRenderState.Battery battery => MakeBatteryBitmap(battery.Reading, baseColor, size),
            TrayRenderState.Unauthenticated => MakeEmptyBitmap(baseColor, size),
            TrayRenderState.AuthFailed => MakeStatusBitmap("!", baseColor, 0.5, size),
            TrayRenderState.StatusError => MakeStatusBitmap("!", baseColor, 0.5, size),
            TrayRenderState.StatusStale => MakeStatusBitmap("...", baseColor, 0.5, size),
            TrayRenderState.StatusLoading => MakeStatusBitmap("...", baseColor, 1.0, size),
            _ => throw new ArgumentOutOfRangeException(nameof(state)),
        };

        _lastSignature = signature;
        return bitmap;
    }

    private static Bitmap MakeBatteryBitmap(Models.UsageReading reading, Color baseColor, int size)
    {
        // The session side draws the display value, the same number the panel and the tooltip show.
        var session = reading.SessionDisplayRemaining;
        var weekly = reading.Snapshot.WeeklyRemaining;

        var bitmap = NewCanvas(size);
        using var g = NewGraphics(bitmap);

        DrawArc(g, size, OuterRadiusRatio, weekly, baseColor);
        DrawArc(g, size, InnerRadiusRatio, session, baseColor);
        return bitmap;
    }

    /// <summary>Both rings empty: no account yet.</summary>
    private static Bitmap MakeEmptyBitmap(Color baseColor, int size)
    {
        var bitmap = NewCanvas(size);
        using var g = NewGraphics(bitmap);

        DrawArc(g, size, OuterRadiusRatio, 0, baseColor);
        DrawArc(g, size, InnerRadiusRatio, 0, baseColor);
        return bitmap;
    }

    /// <summary>
    /// Both rings empty with the status glyph centred over them: something is wrong, or the first
    /// poll has not answered.
    ///
    /// The fade goes on the glyph, not the rings. Fading the rings could not tell the states apart:
    /// the track is already at its fixed 0.15 opacity (the Mac's <c>withAlphaComponent(0.15)</c>
    /// replaces the faded alpha the same way), so before the glyph every status state, and signed
    /// out, drew the same two faint rings and an expired session gave no cue in the tray.
    /// </summary>
    private static Bitmap MakeStatusBitmap(string text, Color baseColor, double alpha, int size)
    {
        var bitmap = MakeEmptyBitmap(baseColor, size);
        using var g = NewGraphics(bitmap, clear: false);

        var tinted = Color.FromArgb((int)Math.Round(255 * Math.Max(0, Math.Min(1, alpha))), baseColor);
        using var font = new Font(GlyphFamily, size * StatusGlyphRatio, FontStyle.Regular, GraphicsUnit.Pixel);
        using var format = (StringFormat)StringFormat.GenericTypographic.Clone();
        format.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces;

        var textSize = g.MeasureString(text, font, int.MaxValue, format);
        using var brush = new SolidBrush(tinted);
        g.DrawString(text, font, brush, (size - textSize.Width) / 2f, (size - textSize.Height) / 2f, format);
        return bitmap;
    }

    private static void DrawArc(Graphics g, int size, float radiusRatio, double percent, Color baseColor)
    {
        var center = size / 2f;
        var radius = size * radiusRatio;
        var stroke = Math.Max(1f, size * StrokeRatio);
        var bounds = new RectangleF(center - radius, center - radius, radius * 2, radius * 2);

        using (var trackPen = new Pen(Color.FromArgb(TrackAlpha, baseColor), stroke) { StartCap = LineCap.Round, EndCap = LineCap.Round })
        {
            g.DrawArc(trackPen, bounds, StartAngle, Sweep);
        }

        var fraction = (float)(Math.Max(0, Math.Min(100, percent)) / 100.0);
        if (fraction <= 0)
        {
            return;
        }

        var fill = TrayPalette.Fill(percent, baseColor);
        using var fillPen = new Pen(fill, stroke) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        g.DrawArc(fillPen, bounds, StartAngle, Sweep * fraction);
    }

    private static Bitmap NewCanvas(int size) => new(size, size, PixelFormat.Format32bppArgb);

    private static Graphics NewGraphics(Bitmap bitmap, bool clear = true)
    {
        var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        // Greyscale text antialiasing, as Stacked Bars uses: ClearType fringes on a transparent canvas.
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        if (clear)
        {
            g.Clear(Color.Transparent);
        }
        return g;
    }
}
