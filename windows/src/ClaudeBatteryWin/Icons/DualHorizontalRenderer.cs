using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using ClaudeBatteryWin.Models;

namespace ClaudeBatteryWin.Icons;

/// <summary>
/// The light/dark brightness bucket the tray icon paints for. The watcher (ThemeWatcher) and the
/// renderer both collapse system appearance onto these two values so that unrelated broadcasts
/// (the issue #11 class) cannot churn renders -- only a real bucket flip changes the signature.
/// </summary>
public enum ThemeBucket
{
    Light,
    Dark
}

/// <summary>
/// Pure compact-countdown formatting, ported verbatim from the Mac
/// <c>CountdownFormat.compactCountdown</c> (Views/UsagePopoverView.swift). Both the tray cell here
/// and the flyout (U10) route through this so they cannot drift. The result is never more than
/// three characters for ANY input: <c>&gt;=10h -&gt; "9h+"</c> (saturates, still truthful as "at
/// least 9h"), <c>&gt;=1h -&gt; "Nh+"</c>, <c>&gt;=1m -&gt; "Nm"</c>, <c>&gt;0 &amp;&amp; &lt;1m -&gt; "&lt;1m"</c>.
/// Returns null when there is nothing to count down (past, non-finite, or absurdly large date),
/// mirroring the Mac issue-#23 trap protection.
/// </summary>
public static class CountdownFormat
{
    /// <summary>
    /// Seconds until <paramref name="date"/>, or null when there is no positive, finite,
    /// in-range countdown. Mirrors the Mac <c>remainingSeconds</c> guard.
    /// </summary>
    public static double? RemainingSeconds(DateTimeOffset date, DateTimeOffset now)
    {
        double remaining = (date - now).TotalSeconds;
        if (remaining > 0 && !double.IsNaN(remaining) && !double.IsInfinity(remaining) && remaining < long.MaxValue)
        {
            return remaining;
        }
        return null;
    }

    /// <summary>
    /// Compact menu-bar countdown, never more than three characters. Returns null when there is
    /// nothing to count down.
    /// </summary>
    public static string? CompactCountdown(DateTimeOffset date, DateTimeOffset now)
    {
        double? remaining = RemainingSeconds(date, now);
        if (remaining is null)
        {
            return null;
        }

        long total = (long)remaining.Value;
        long hours = total / 3600;
        long minutes = (total % 3600) / 60;
        if (hours >= 10)
        {
            return "9h+";
        }
        if (hours >= 1)
        {
            return $"{hours}h+";
        }
        if (minutes >= 1)
        {
            return $"{minutes}m";
        }
        return "<1m";
    }
}

/// <summary>
/// The resolved render branch for the tray icon, mirroring the Mac <c>RenderState</c> selection in
/// MenuBarController. The renderer draws a battery glyph only for <see cref="Battery"/>; the other
/// branches draw a status/auth glyph. Kept distinct from the flyout's <see cref="RenderState"/>
/// enum because the tray needs the usage payload inline for the battery branch.
/// </summary>
public abstract record TrayRenderState
{
    private TrayRenderState() { }

    /// <summary>No account yet: hollow battery outline.</summary>
    public sealed record Unauthenticated : TrayRenderState;

    /// <summary>401/403: faded "!" glyph (session expired).</summary>
    public sealed record AuthFailed : TrayRenderState;

    /// <summary>Usage present: the dual-horizontal battery.</summary>
    public sealed record Battery(UsageSnapshot Usage) : TrayRenderState;

    /// <summary>Repeated failures with no usable snapshot: faded "!".</summary>
    public sealed record StatusError : TrayRenderState;

    /// <summary>Stale snapshot: faded "...".</summary>
    public sealed record StatusStale : TrayRenderState;

    /// <summary>Poll in flight, no prior snapshot: solid "...".</summary>
    public sealed record StatusLoading : TrayRenderState;
}

/// <summary>
/// Renders the default Dual Horizontal tray bitmap: two horizontal batteries (session nub left,
/// weekly nub right) with an optional leading countdown tag cell. Constants, fonts, kerning, and
/// geometry are ported verbatim from the Mac <c>DualHorizontalRenderer</c> and
/// <c>MenuBarController.imageWithCountdownCell</c> so the Windows tray reads identically.
///
/// Issue #11 port: a private render-signature cache keyed on (render branch, theme bucket,
/// countdown string) short-circuits redundant renders. When the signature matches the last
/// successful render, <see cref="Render"/> returns null and increments <see cref="SuppressedCount"/>
/// rather than re-rasterizing. The signature struct is intentionally private to this renderer
/// (extract only when a second renderer is added).
///
/// Color thresholds on remaining percent (clamped 0-100), ported from the Mac
/// <c>batteryColor</c>: <c>&lt;20</c> red, <c>&lt;45</c> orange, else green. The base (outline /
/// digit / nub) color is white on a dark menu bar, black on a light one.
/// </summary>
public sealed class DualHorizontalRenderer : IDisposable
{
    // --- Battery geometry (verbatim from Mac DualHorizontalRenderer) ---
    private const float BatteryWidth = 30f;
    private const float BatteryHeight = 14f;
    private const float NubWidth = 2f;
    private const float NubHeight = 6f;
    private const float CornerRadius = 3f;
    private const float FillInset = 1.5f;
    private const float IconHeight = 18f;
    private const float Gap = 4f;

    // --- Countdown tag cell (verbatim from MenuBarController.imageWithCountdownCell) ---
    private const float CellHeight = 14f;
    private const float CellCornerRadius = 3f;
    private const float CellGap = 4f;
    private const float CellHPadding = 4f;

    // --- Status / unauthenticated glyph (verbatim from Mac makeStatusIcon) ---
    private const float StatusOutlineWidth = 30f;
    private const float StatusOutlineHeight = 12f;
    private const float StatusOutlineY = 3f;
    private const float StatusNubX = 30f;
    private const float StatusNubY = 5.5f;
    private const float StatusNubW = 2f;
    private const float StatusNubH = 5f;

    // Mac font sizes/weights. GDI+ has no "heavy" weight, so Bold is the nearest analog; the
    // monospaced-digit family maps to a monospace font so the two battery numbers stay column-
    // aligned. Sizes are the Mac point sizes.
    private const float NumberFontSize = 10f;
    private const float SmallNumberFontSize = 8.5f;
    private const float CellFontSize = 9f;
    private const float StatusFontSize = 9f;
    private const string MonospaceFamily = "Consolas";

    private readonly Font _numberFont = new(MonospaceFamily, NumberFontSize, FontStyle.Bold, GraphicsUnit.Pixel);
    private readonly Font _smallNumberFont = new(MonospaceFamily, SmallNumberFontSize, FontStyle.Bold, GraphicsUnit.Pixel);
    private readonly Font _cellFont = new(MonospaceFamily, CellFontSize, FontStyle.Regular, GraphicsUnit.Pixel);
    private readonly Font _statusFont = new(MonospaceFamily, StatusFontSize, FontStyle.Regular, GraphicsUnit.Pixel);

    /// <summary>
    /// Cache key for the last successful render. When two signatures compare equal the produced
    /// bitmap would be identical, so a re-render is wasted work. Private struct: equality covers
    /// only the inputs that determine the visible output (the branch, the theme bucket, the
    /// composed countdown string). The <see cref="Battery"/> branch's usage participates through
    /// the rounded session/weekly percents, not the whole snapshot, so failure-count churn or a
    /// sub-percent drift that does not change a drawn digit cannot force a re-render.
    /// </summary>
    private readonly struct RenderSignature : IEquatable<RenderSignature>
    {
        // 0 unauth, 1 authFailed, 2 statusError, 3 statusStale, 4 statusLoading, 5 battery.
        private readonly int _branch;
        private readonly int _sessionPercent;
        private readonly int _weeklyPercent;
        private readonly ThemeBucket _theme;
        private readonly string _countdown;

        private RenderSignature(int branch, int sessionPercent, int weeklyPercent, ThemeBucket theme, string countdown)
        {
            _branch = branch;
            _sessionPercent = sessionPercent;
            _weeklyPercent = weeklyPercent;
            _theme = theme;
            _countdown = countdown;
        }

        public static RenderSignature For(TrayRenderState state, ThemeBucket theme, string countdown)
        {
            return state switch
            {
                TrayRenderState.Unauthenticated => new RenderSignature(0, 0, 0, theme, countdown),
                TrayRenderState.AuthFailed => new RenderSignature(1, 0, 0, theme, countdown),
                TrayRenderState.StatusError => new RenderSignature(2, 0, 0, theme, countdown),
                TrayRenderState.StatusStale => new RenderSignature(3, 0, 0, theme, countdown),
                TrayRenderState.StatusLoading => new RenderSignature(4, 0, 0, theme, countdown),
                TrayRenderState.Battery battery => new RenderSignature(
                    5,
                    (int)battery.Usage.SessionRemaining,
                    (int)battery.Usage.WeeklyRemaining,
                    theme,
                    countdown),
                _ => throw new ArgumentOutOfRangeException(nameof(state))
            };
        }

        public bool Equals(RenderSignature other) =>
            _branch == other._branch
            && _sessionPercent == other._sessionPercent
            && _weeklyPercent == other._weeklyPercent
            && _theme == other._theme
            && _countdown == other._countdown;

        public override bool Equals(object? obj) => obj is RenderSignature other && Equals(other);

        public override int GetHashCode() =>
            HashCode.Combine(_branch, _sessionPercent, _weeklyPercent, _theme, _countdown);

        public static bool operator ==(RenderSignature a, RenderSignature b) => a.Equals(b);
        public static bool operator !=(RenderSignature a, RenderSignature b) => !a.Equals(b);
    }

    private RenderSignature? _lastSignature;

    /// <summary>
    /// Number of <see cref="Render"/> calls short-circuited by a matching signature since the last
    /// <see cref="ResetSignature"/>. The CPU-safety tests assert this increments on a duplicate
    /// (state, theme, countdown) tuple.
    /// </summary>
    public long SuppressedCount { get; private set; }

    /// <summary>
    /// Pure mapping from remaining percent to fill color, ported verbatim from the Mac
    /// <c>batteryColor(remainingPercent:)</c>: clamp 0-100, then <c>&lt;20</c> red, <c>&lt;45</c>
    /// orange, else green. Exposed for the boundary tests.
    /// </summary>
    public static Color BatteryColor(double remainingPercent)
    {
        double clamped = Math.Max(0, Math.Min(100, remainingPercent));
        if (clamped < 20)
        {
            return Color.Red;
        }
        if (clamped < 45)
        {
            return Color.Orange;
        }
        return Color.Green;
    }

    /// <summary>
    /// The compact countdown string for the tray cell, or "" when the toggle is off or there is no
    /// positive session-reset countdown. Folding "" into the signature is what makes the per-minute
    /// timer re-render exactly once per string change and never in a loop (the Mac
    /// <c>countdownTitle</c> contract). Static + pure so it is reachable from tests.
    /// </summary>
    public static string CountdownCellText(UsageSnapshot? usage, bool enabled, DateTimeOffset now)
    {
        if (!enabled || usage?.SessionResetDate is not { } resetDate)
        {
            return string.Empty;
        }
        return CountdownFormat.CompactCountdown(resetDate, now) ?? string.Empty;
    }

    /// <summary>
    /// Render the tray bitmap for the given state, theme bucket, and (already-composed) countdown
    /// string. Returns a fresh <see cref="Bitmap"/> the caller owns (convert to an
    /// <c>System.Drawing.Icon</c> and dispose the prior icon), or null when the signature matches
    /// the last successful render (the issue #11 short-circuit), in which case
    /// <see cref="SuppressedCount"/> is incremented and the caller keeps its current icon.
    ///
    /// The countdown cell only rides the battery branch; status/auth glyphs stay bare, matching the
    /// Mac (<c>if case .battery = render, !countdown.isEmpty</c>).
    /// </summary>
    public Bitmap? Render(TrayRenderState state, ThemeBucket theme, string countdown)
    {
        ArgumentNullException.ThrowIfNull(state);
        ArgumentNullException.ThrowIfNull(countdown);

        var signature = RenderSignature.For(state, theme, countdown);
        if (_lastSignature is { } last && last == signature)
        {
            SuppressedCount++;
            return null;
        }

        Color baseColor = theme == ThemeBucket.Dark ? Color.White : Color.Black;

        Bitmap bitmap = state switch
        {
            TrayRenderState.Battery battery when countdown.Length > 0 =>
                Compose(MakeBatteryBitmap(battery.Usage, baseColor), countdown, baseColor),
            TrayRenderState.Battery battery =>
                MakeBatteryBitmap(battery.Usage, baseColor),
            TrayRenderState.Unauthenticated =>
                MakeUnauthenticatedBitmap(baseColor),
            TrayRenderState.AuthFailed =>
                MakeStatusBitmap("!", baseColor, 0.5),
            TrayRenderState.StatusError =>
                MakeStatusBitmap("!", baseColor, 0.5),
            TrayRenderState.StatusStale =>
                MakeStatusBitmap("...", baseColor, 0.5),
            TrayRenderState.StatusLoading =>
                MakeStatusBitmap("...", baseColor, 1.0),
            _ => throw new ArgumentOutOfRangeException(nameof(state))
        };

        _lastSignature = signature;
        return bitmap;
    }

    /// <summary>
    /// Invalidate the signature cache so the next <see cref="Render"/> always rasterizes. Mirrors
    /// the Mac wake/button-loss reset (<c>lastRenderedSignature = nil</c>): after a display
    /// reconfiguration the cached image may no longer be on screen, so a matching signature must
    /// not suppress the first render afterward. Does not reset <see cref="SuppressedCount"/>.
    /// </summary>
    public void ResetSignature() => _lastSignature = null;

    // MARK: - Drawing

    private Bitmap MakeBatteryBitmap(UsageSnapshot usage, Color baseColor)
    {
        int weeklyPercent = (int)usage.WeeklyRemaining;
        int sessionPercent = (int)usage.SessionRemaining;

        float totalWidth = NubWidth + BatteryWidth + Gap + BatteryWidth + NubWidth;
        var bitmap = NewCanvas((int)Math.Ceiling(totalWidth), (int)IconHeight);
        using var g = NewGraphics(bitmap);

        // Session battery (left, nub points left). Weekly battery (right, nub points right).
        DrawBattery(g, baseColor, bodyX: NubWidth, nubOnLeft: true, percent: sessionPercent);
        DrawBattery(g, baseColor, bodyX: NubWidth + BatteryWidth + Gap, nubOnLeft: false, percent: weeklyPercent);

        return bitmap;
    }

    private void DrawBattery(Graphics g, Color baseColor, float bodyX, bool nubOnLeft, int percent)
    {
        float batteryY = (IconHeight - BatteryHeight) / 2f;
        float interiorWidth = BatteryWidth - FillInset * 2f;
        float interiorHeight = BatteryHeight - FillInset * 2f;

        Font font = percent >= 100 ? _smallNumberFont : _numberFont;
        string numberStr = percent.ToString();

        // 1. Outline (1.0pt stroke).
        using (var pen = new Pen(baseColor, 1.0f))
        using (var outline = RoundedRect(bodyX, batteryY, BatteryWidth, BatteryHeight, CornerRadius))
        {
            g.DrawPath(pen, outline);
        }

        // 2. Nub.
        float nubX = nubOnLeft ? bodyX - NubWidth : bodyX + BatteryWidth;
        using (var nubBrush = new SolidBrush(baseColor))
        using (var nub = RoundedRect(nubX, batteryY + (BatteryHeight - NubHeight) / 2f, NubWidth, NubHeight, 0.5f))
        {
            g.FillPath(nubBrush, nub);
        }

        // 3. Fill level. The Mac uses red below 20; this port uses the full three-tier
        // batteryColor scale (<20 red, <45 orange, else green) per the U9 plan.
        float fillWidth = interiorWidth * percent / 100f;
        RectangleF fillRect = RectangleF.Empty;
        if (fillWidth > 0)
        {
            float fillX = nubOnLeft
                ? bodyX + FillInset + interiorWidth - fillWidth
                : bodyX + FillInset;
            fillRect = new RectangleF(fillX, batteryY + FillInset, fillWidth, interiorHeight);
            Color fillColor = BatteryColor(percent);
            using var fillBrush = new SolidBrush(fillColor);
            using var fillPath = RoundedRect(fillRect.X, fillRect.Y, fillRect.Width, fillRect.Height, 1.5f);
            g.FillPath(fillBrush, fillPath);
        }

        // 4. Text -- two-pass clipping for contrast (white over the fill, base color over the
        // empty portion), mirroring the Mac's clip-and-draw passes.
        if (fillWidth > 0)
        {
            DrawClippedNumber(g, numberStr, font, bodyX, fillRect, Color.White);
        }

        float unfilledWidth = interiorWidth - fillWidth;
        if (unfilledWidth > 0)
        {
            float unfilledX = nubOnLeft
                ? bodyX + FillInset
                : bodyX + FillInset + fillWidth;
            var unfilledRect = new RectangleF(unfilledX, batteryY + FillInset, unfilledWidth, interiorHeight);
            DrawClippedNumber(g, numberStr, font, bodyX, unfilledRect, baseColor);
        }
    }

    /// <summary>
    /// Draw the centered battery number clipped to a region, so the same glyph paints white over
    /// the filled portion and the base color over the empty portion (the Mac contrast trick). The
    /// number is centered across the whole battery body, not the clip region, so the two passes
    /// align into one glyph.
    /// </summary>
    private void DrawClippedNumber(Graphics g, string numberStr, Font font, float bodyX, RectangleF clip, Color color)
    {
        SizeF numberSize = MeasureTight(g, numberStr, font);
        float x = bodyX + (BatteryWidth - numberSize.Width) / 2f;
        float y = (IconHeight - numberSize.Height) / 2f;

        var saved = g.Save();
        g.SetClip(clip);
        using (var brush = new SolidBrush(color))
        {
            g.DrawString(numberStr, font, brush, x, y, TightFormat);
        }
        g.Restore(saved);
    }

    private Bitmap MakeUnauthenticatedBitmap(Color baseColor)
    {
        var bitmap = NewCanvas(34, (int)IconHeight);
        using var g = NewGraphics(bitmap);

        using (var pen = new Pen(baseColor, 1.0f))
        using (var outline = RoundedRect(0, StatusOutlineY, StatusOutlineWidth, StatusOutlineHeight, 2f))
        {
            g.DrawPath(pen, outline);
        }
        using (var nubBrush = new SolidBrush(baseColor))
        using (var nub = RoundedRect(StatusNubX, StatusNubY, StatusNubW, StatusNubH, 0.5f))
        {
            g.FillPath(nubBrush, nub);
        }

        return bitmap;
    }

    private Bitmap MakeStatusBitmap(string text, Color baseColor, double alpha)
    {
        Color tinted = WithAlpha(baseColor, alpha);
        var bitmap = NewCanvas(40, (int)IconHeight);
        using var g = NewGraphics(bitmap);

        using (var pen = new Pen(tinted, 1.0f))
        using (var outline = RoundedRect(0, StatusOutlineY, StatusOutlineWidth, StatusOutlineHeight, 2f))
        {
            g.DrawPath(pen, outline);
        }
        using (var nubBrush = new SolidBrush(tinted))
        using (var nub = RoundedRect(StatusNubX, StatusNubY, StatusNubW, StatusNubH, 0.5f))
        {
            g.FillPath(nubBrush, nub);
        }

        SizeF size = MeasureTight(g, text, _statusFont);
        using (var brush = new SolidBrush(tinted))
        {
            // Centered within the 30-wide outline body, matching the Mac (size 18 canvas tall).
            g.DrawString(text, _statusFont, brush,
                (StatusOutlineWidth - size.Width) / 2f,
                (IconHeight - size.Height) / 2f,
                TightFormat);
        }

        return bitmap;
    }

    /// <summary>
    /// Compose a leading rounded tag cell carrying the countdown onto the front of the battery
    /// bitmap: <c>[ 3h+ ] [75] [43]</c>. Ported from <c>MenuBarController.imageWithCountdownCell</c>
    /// -- 1.0pt cell outline, corner radius 3, height 14, vertically centered; the cell font is one
    /// weight lighter and a touch smaller than the heavy battery digits so the timer reads as
    /// secondary.
    /// </summary>
    private Bitmap Compose(Bitmap batteryBitmap, string countdown, Color color)
    {
        using (batteryBitmap)
        {
            float iconHeight = Math.Max(IconHeight, batteryBitmap.Height);

            using var measureBitmap = NewCanvas(1, 1);
            using var measureG = NewGraphics(measureBitmap);
            SizeF textSize = MeasureTight(measureG, countdown, _cellFont);
            float cellWidth = (float)Math.Ceiling(textSize.Width) + CellHPadding * 2f;

            float totalWidth = cellWidth + CellGap + batteryBitmap.Width;
            var composed = NewCanvas((int)Math.Ceiling(totalWidth), (int)iconHeight);
            using var g = NewGraphics(composed);

            float cellY = (iconHeight - CellHeight) / 2f;
            using (var pen = new Pen(color, 1.0f))
            using (var outline = RoundedRect(0.5f, cellY, cellWidth - 1f, CellHeight, CellCornerRadius))
            {
                g.DrawPath(pen, outline);
            }

            using (var brush = new SolidBrush(color))
            {
                g.DrawString(countdown, _cellFont, brush,
                    (cellWidth - textSize.Width) / 2f,
                    (iconHeight - textSize.Height) / 2f,
                    TightFormat);
            }

            g.DrawImage(batteryBitmap,
                new RectangleF(cellWidth + CellGap, (iconHeight - batteryBitmap.Height) / 2f,
                    batteryBitmap.Width, batteryBitmap.Height),
                new RectangleF(0, 0, batteryBitmap.Width, batteryBitmap.Height),
                GraphicsUnit.Pixel);

            return composed;
        }
    }

    // MARK: - GDI+ helpers

    private static Bitmap NewCanvas(int width, int height)
    {
        // Guard against a zero/negative canvas (a degenerate measure pass), GDI+ throws otherwise.
        return new Bitmap(Math.Max(1, width), Math.Max(1, height), PixelFormat.Format32bppArgb);
    }

    private static Graphics NewGraphics(Bitmap bitmap)
    {
        var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.Clear(Color.Transparent);
        return g;
    }

    /// <summary>
    /// String-measure/draw format with no extra padding so text centers like the Mac's
    /// <c>size(withAttributes:)</c>. <c>GenericTypographic</c> drops the default GDI+ glyph
    /// overhang.
    /// </summary>
    private static readonly StringFormat TightFormat = CreateTightFormat();

    private static StringFormat CreateTightFormat()
    {
        var fmt = (StringFormat)StringFormat.GenericTypographic.Clone();
        fmt.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces;
        return fmt;
    }

    private static SizeF MeasureTight(Graphics g, string text, Font font) =>
        g.MeasureString(text, font, int.MaxValue, TightFormat);

    private static Color WithAlpha(Color color, double alpha)
    {
        int a = (int)Math.Round(Math.Max(0, Math.Min(1, alpha)) * 255);
        return Color.FromArgb(a, color.R, color.G, color.B);
    }

    /// <summary>
    /// A rounded-rectangle path. A radius of 0 (or one too large for the rect) collapses to a plain
    /// rectangle, matching how the Mac's tiny-radius nub reads as effectively square.
    /// </summary>
    private static GraphicsPath RoundedRect(float x, float y, float width, float height, float radius)
    {
        var path = new GraphicsPath();
        float r = Math.Max(0, Math.Min(radius, Math.Min(width, height) / 2f));
        if (r <= 0f)
        {
            path.AddRectangle(new RectangleF(x, y, width, height));
            path.CloseFigure();
            return path;
        }

        float d = r * 2f;
        path.AddArc(x, y, d, d, 180, 90);
        path.AddArc(x + width - d, y, d, d, 270, 90);
        path.AddArc(x + width - d, y + height - d, d, d, 0, 90);
        path.AddArc(x, y + height - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public void Dispose()
    {
        _numberFont.Dispose();
        _smallNumberFont.Dispose();
        _cellFont.Dispose();
        _statusFont.Dispose();
    }
}
