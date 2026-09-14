using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

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
            TrayRenderState.AuthFailed => MakeStatusBitmap(baseColor, 0.5, size),
            TrayRenderState.StatusError => MakeStatusBitmap(baseColor, 0.5, size),
            TrayRenderState.StatusStale => MakeStatusBitmap(baseColor, 0.5, size),
            TrayRenderState.StatusLoading => MakeStatusBitmap(baseColor, 1.0, size),
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

    /// <summary>Both rings empty and faded: something is wrong, or the first poll has not answered.</summary>
    private static Bitmap MakeStatusBitmap(Color baseColor, double alpha, int size)
    {
        var faded = Color.FromArgb((int)Math.Round(255 * alpha), baseColor);
        return MakeEmptyBitmap(faded, size);
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

    private static Graphics NewGraphics(Bitmap bitmap)
    {
        var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);
        return g;
    }
}
