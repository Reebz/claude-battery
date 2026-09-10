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
/// branches draw a status/auth glyph. The tray branch carries the usage payload inline for the
/// battery case, which is why it is a discriminated record rather than a bare enum.
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

    // Failure-count thresholds, mirroring UsageService.Constants (StaleFailureThreshold = 3,
    // ErrorFailureThreshold = 10). Duplicated as literals because those constants are private to the
    // poller; kept in sync by name.
    private const int StaleFailureThreshold = 3;
    private const int ErrorFailureThreshold = 10;

    /// <summary>
    /// Pure mapping from polling/auth state to the tray render branch, mirroring the Mac
    /// <c>MenuBarController.renderState</c> selection. A PRESENT snapshot always renders the battery,
    /// even when stale - the open flyout shows the same reading, so staleness alone must never hide a
    /// known value behind "..." (issue #9). The stale glyph is reached ONLY with no snapshot, after a
    /// sustained stale window (&gt;=3 hard failures and past the stale threshold), sitting between the
    /// &gt;=10 error branch and the first-poll loading branch. Extracted from <c>App</c> so the branch
    /// order is unit-testable.
    /// </summary>
    /// <param name="serviceReady">Whether the polling service exists yet (false very early in startup).</param>
    public static TrayRenderState Resolve(
        bool isAuthenticated,
        bool serviceReady,
        bool authFailed,
        UsageSnapshot? latestUsage,
        int consecutiveFailures,
        bool isStale)
    {
        if (!isAuthenticated) return new Unauthenticated();
        if (!serviceReady) return new StatusLoading();
        if (authFailed) return new AuthFailed();

        // A known reading always wins, stale or not (matches the flyout and the Mac).
        if (latestUsage is { } usage) return new Battery(usage);

        // No snapshot from here down.
        if (consecutiveFailures >= ErrorFailureThreshold) return new StatusError();
        if (consecutiveFailures >= StaleFailureThreshold && isStale) return new StatusStale();
        return new StatusLoading();
    }
}

/// <summary>
/// Renders the Dual Horizontal tray bitmap as a SQUARE: two stacked horizontal bars (session on
/// top, weekly below), each spanning the full width with a 1 px outline, a nub on the right end and
/// an interior filled left-to-right by remaining percent. No digits and no countdown cell: the
/// Windows notification area draws every icon into a square small-icon cell (16 px at 100%
/// scaling, 24 at 150%, 32 at 200%) and stretches whatever HICON it gets to fit, so the Mac's
/// 68x18 wide layout (two batteries with numbers plus a countdown tag) was squashed 4x
/// horizontally into an unreadable blob. The numbers and the countdown belong in the tray tooltip
/// and the flyout instead. The caller passes the live cell size (SM_CXSMICON) so the icon is drawn
/// at the exact size the shell shows, never downscaled (a 1 px outline drawn at 32 px vanishes in a
/// 16 px cell).
///
/// Issue #11 port: a private render-signature cache keyed on (render branch, rounded percents,
/// theme bucket, size) short-circuits redundant renders. When the signature matches the last
/// successful render, <see cref="Render"/> returns null and increments <see cref="SuppressedCount"/>
/// rather than re-rasterizing. The countdown string is deliberately NOT part of the signature any
/// more: nothing drawn depends on it, so a per-minute countdown tick must not re-rasterize. The
/// signature struct is intentionally private to this renderer (extract only when a second renderer
/// is added).
///
/// Color thresholds on remaining percent (clamped 0-100), ported from the Mac
/// <c>batteryColor</c>: <c>&lt;20</c> red, <c>&lt;45</c> orange, else green. The base (outline /
/// nub / glyph) color is white on a dark TASKBAR, black on a light one; the caller must pass the
/// taskbar bucket (<c>ThemeWatcher.CurrentTrayBucket</c>), not the app-window bucket.
/// </summary>
public sealed class DualHorizontalRenderer : IDisposable
{
    // --- Square tray layout ratios (all of a size x size canvas) ---
    private const float BarHeightRatio = 0.36f;     // each battery bar's height
    private const float TopBarYRatio = 0.08f;       // session bar top
    private const float BottomBarYRatio = 0.56f;    // weekly bar top (leaves a gap between the two)
    private const float HollowBarHeightRatio = 0.5f; // the single outline bar for unauth/status
    private const float StatusGlyphRatio = 0.55f;   // "!" / "..." font size, in px

    // --- Battery geometry (verbatim from Mac DualHorizontalRenderer) ---
    // unused since the square tray icon; flagged for removal (the whole group below)
    private const float BatteryWidth = 30f;
    private const float BatteryHeight = 14f;
    private const float NubWidth = 2f;
    private const float NubHeight = 6f;
    private const float CornerRadius = 3f;
    private const float FillInset = 1.5f;
    private const float IconHeight = 18f;
    private const float Gap = 4f;

    // --- Countdown tag cell (verbatim from MenuBarController.imageWithCountdownCell) ---
    // unused since the square tray icon; flagged for removal (the whole group below)
    private const float CellHeight = 14f;
    private const float CellCornerRadius = 3f;
    private const float CellGap = 4f;
    private const float CellHPadding = 4f;

    // --- Status / unauthenticated glyph (verbatim from Mac makeStatusIcon) ---
    // unused since the square tray icon; flagged for removal (the whole group below)
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
    // unused since the square tray icon; flagged for removal
    private const float NumberFontSize = 10f;
    // unused since the square tray icon; flagged for removal
    private const float SmallNumberFontSize = 8.5f;
    // unused since the square tray icon; flagged for removal
    private const float CellFontSize = 9f;
    private const float StatusFontSize = 9f;
    private const string MonospaceFamily = "Consolas";

    // unused since the square tray icon; flagged for removal
    private readonly Font _numberFont = new(MonospaceFamily, NumberFontSize, FontStyle.Bold, GraphicsUnit.Pixel);
    // unused since the square tray icon; flagged for removal
    private readonly Font _smallNumberFont = new(MonospaceFamily, SmallNumberFontSize, FontStyle.Bold, GraphicsUnit.Pixel);
    // unused since the square tray icon; flagged for removal
    private readonly Font _cellFont = new(MonospaceFamily, CellFontSize, FontStyle.Regular, GraphicsUnit.Pixel);
    // Only the family is used now: the status glyph font is created per render, sized to the cell.
    private readonly Font _statusFont = new(MonospaceFamily, StatusFontSize, FontStyle.Regular, GraphicsUnit.Pixel);

    // One persistent measure surface reused for every MeasureString, instead of allocating a fresh
    // 1x1 Bitmap+Graphics per measure (R7). Configured identically to NewGraphics so MeasureString
    // results are byte-identical to the prior per-call surface. Disposed in Dispose.
    private readonly Bitmap _measureBitmap;
    private readonly Graphics _measureGraphics;

    // The tight string-measure/draw format, held as an instance field disposed in Dispose rather than
    // a never-disposed static (R8). Symmetric with the per-instance fonts above.
    private readonly StringFormat _tightFormat = CreateTightFormat();

    public DualHorizontalRenderer()
    {
        _measureBitmap = NewCanvas(1, 1);
        _measureGraphics = NewGraphics(_measureBitmap);
    }

    /// <summary>
    /// Cache key for the last successful render. When two signatures compare equal the produced
    /// bitmap would be identical, so a re-render is wasted work. Private struct: equality covers
    /// only the inputs that determine the visible output (the branch, the theme bucket, the
    /// square cell size). The <see cref="Battery"/> branch's usage participates through the
    /// rounded session/weekly percents, not the whole snapshot, so failure-count churn or a
    /// sub-percent drift that does not move the fill by a whole percent cannot force a re-render.
    /// The countdown string is NOT a key: the square icon draws no countdown cell, so a per-minute
    /// tick on any branch (battery included) must be suppressed.
    /// </summary>
    private readonly struct RenderSignature : IEquatable<RenderSignature>
    {
        // 0 unauth, 1 authFailed, 2 statusError, 3 statusStale, 4 statusLoading, 5 battery.
        private readonly int _branch;
        private readonly int _sessionPercent;
        private readonly int _weeklyPercent;
        private readonly ThemeBucket _theme;
        private readonly int _size;

        private RenderSignature(int branch, int sessionPercent, int weeklyPercent, ThemeBucket theme, int size)
        {
            _branch = branch;
            _sessionPercent = sessionPercent;
            _weeklyPercent = weeklyPercent;
            _theme = theme;
            _size = size;
        }

        public static RenderSignature For(TrayRenderState state, ThemeBucket theme, int size)
        {
            return state switch
            {
                TrayRenderState.Unauthenticated => new RenderSignature(0, 0, 0, theme, size),
                TrayRenderState.AuthFailed => new RenderSignature(1, 0, 0, theme, size),
                TrayRenderState.StatusError => new RenderSignature(2, 0, 0, theme, size),
                TrayRenderState.StatusStale => new RenderSignature(3, 0, 0, theme, size),
                TrayRenderState.StatusLoading => new RenderSignature(4, 0, 0, theme, size),
                TrayRenderState.Battery battery => new RenderSignature(
                    5,
                    (int)battery.Usage.SessionRemaining,
                    (int)battery.Usage.WeeklyRemaining,
                    theme,
                    size),
                _ => throw new ArgumentOutOfRangeException(nameof(state))
            };
        }

        public bool Equals(RenderSignature other) =>
            _branch == other._branch
            && _sessionPercent == other._sessionPercent
            && _weeklyPercent == other._weeklyPercent
            && _theme == other._theme
            && _size == other._size;

        public override bool Equals(object? obj) => obj is RenderSignature other && Equals(other);

        public override int GetHashCode() =>
            HashCode.Combine(_branch, _sessionPercent, _weeklyPercent, _theme, _size);

        public static bool operator ==(RenderSignature a, RenderSignature b) => a.Equals(b);
        public static bool operator !=(RenderSignature a, RenderSignature b) => !a.Equals(b);
    }

    private RenderSignature? _lastSignature;

    /// <summary>
    /// Number of <see cref="Render"/> calls short-circuited by a matching signature since the last
    /// <see cref="ResetSignature"/>. The CPU-safety tests assert this increments on a duplicate
    /// (state, theme, size) tuple.
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
    /// The compact countdown string, or "" when the toggle is off or there is no positive
    /// session-reset countdown. The square tray icon no longer draws it; the tray tooltip carries
    /// it instead (the Mac <c>countdownTitle</c> contract: "" means "show nothing"). Static + pure
    /// so it is reachable from tests.
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
    /// Render the square tray bitmap (<paramref name="size"/> x <paramref name="size"/>) for the
    /// given state and TASKBAR theme bucket. Returns a fresh <see cref="Bitmap"/> the caller owns
    /// (convert to an <c>System.Drawing.Icon</c> and dispose the prior icon), or null when the
    /// signature matches the last successful render (the issue #11 short-circuit), in which case
    /// <see cref="SuppressedCount"/> is incremented and the caller keeps its current icon.
    ///
    /// <paramref name="countdown"/> is kept for the caller's signature but no longer affects the
    /// bitmap or the cache: the square icon draws no countdown cell (put it in the tooltip). A
    /// countdown-only change is therefore suppressed on every branch, battery included.
    /// <paramref name="size"/> is the live small-icon cell size (SM_CXSMICON: 16 at 100% scaling,
    /// 24 at 150%, 32 at 200%); it is part of the signature so a scaling change re-rasterizes.
    /// </summary>
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

        Color baseColor = theme == ThemeBucket.Dark ? Color.White : Color.Black;

        Bitmap bitmap = state switch
        {
            TrayRenderState.Battery battery =>
                MakeBatteryBitmap(battery.Usage, baseColor, size),
            TrayRenderState.Unauthenticated =>
                MakeUnauthenticatedBitmap(baseColor, size),
            TrayRenderState.AuthFailed =>
                MakeStatusBitmap("!", baseColor, 0.5, size),
            TrayRenderState.StatusError =>
                MakeStatusBitmap("!", baseColor, 0.5, size),
            TrayRenderState.StatusStale =>
                MakeStatusBitmap("...", baseColor, 0.5, size),
            TrayRenderState.StatusLoading =>
                MakeStatusBitmap("...", baseColor, 1.0, size),
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

    // MARK: - Drawing (square cell)

    /// <summary>Outline stroke and nub width: 1 px up to 24 px cells, 2 px at 32.</summary>
    private static int OutlineWidth(int size) => Math.Max(1, size / 16);

    private Bitmap MakeBatteryBitmap(UsageSnapshot usage, Color baseColor, int size)
    {
        int sessionPercent = (int)usage.SessionRemaining;
        int weeklyPercent = (int)usage.WeeklyRemaining;

        var bitmap = NewCanvas(size, size);
        using var g = NewGraphics(bitmap);

        // Session bar on top, weekly bar below; both fill left-to-right, nub on the right.
        float barHeight = (float)Math.Round(size * BarHeightRatio);
        DrawBar(g, size, y: (float)Math.Round(size * TopBarYRatio), height: barHeight, baseColor, percent: sessionPercent);
        DrawBar(g, size, y: (float)Math.Round(size * BottomBarYRatio), height: barHeight, baseColor, percent: weeklyPercent);

        return bitmap;
    }

    /// <summary>
    /// One horizontal battery bar spanning the full cell width: a rounded outline in
    /// <paramref name="color"/>, a nub on the right end, and (when <paramref name="percent"/> is
    /// given) the interior filled left-to-right by remaining percent in <see cref="BatteryColor"/>,
    /// clipped to the inside of the outline so the fill never bleeds past the rounded corners.
    /// </summary>
    private static void DrawBar(Graphics g, int size, float y, float height, Color color, int? percent)
    {
        float stroke = OutlineWidth(size);
        float nubWidth = stroke;
        float bodyWidth = size - nubWidth;
        float radius = size / 8f;

        // 1. Outline. GDI+ centres the pen on the path, so inset by half the stroke to land a 1 px
        //    pen on whole pixels instead of smearing it across two.
        float half = stroke / 2f;
        using (var pen = new Pen(color, stroke))
        using (var outline = RoundedRect(half, y + half, bodyWidth - stroke, height - stroke, radius))
        {
            g.DrawPath(pen, outline);
        }

        // 2. Nub: half the bar height, vertically centred, flush against the right edge.
        float nubHeight = Math.Max(1f, (float)Math.Round(height / 2f));
        using (var nubBrush = new SolidBrush(color))
        {
            g.FillRectangle(nubBrush, bodyWidth, y + (height - nubHeight) / 2f, nubWidth, nubHeight);
        }

        // 3. Fill level, the full three-tier batteryColor scale (<20 red, <45 orange, else green).
        if (percent is { } p && p > 0)
        {
            float interiorX = stroke;
            float interiorY = y + stroke;
            float interiorWidth = bodyWidth - stroke * 2f;
            float interiorHeight = height - stroke * 2f;
            float fillWidth = interiorWidth * Math.Min(100, p) / 100f;

            using var fillBrush = new SolidBrush(BatteryColor(p));
            using var interior = RoundedRect(interiorX, interiorY, interiorWidth, interiorHeight, Math.Max(0f, radius - stroke));
            var saved = g.Save();
            g.SetClip(interior);
            g.FillRectangle(fillBrush, interiorX, interiorY, fillWidth, interiorHeight);
            g.Restore(saved);
        }
    }

    // unused since the square tray icon; flagged for removal
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
            g.DrawString(numberStr, font, brush, x, y, _tightFormat);
        }
        g.Restore(saved);
    }

    /// <summary>One hollow outline bar (with nub) vertically centred in the cell: signed out.</summary>
    private Bitmap MakeUnauthenticatedBitmap(Color baseColor, int size)
    {
        var bitmap = NewCanvas(size, size);
        using var g = NewGraphics(bitmap);
        DrawHollowBar(g, size, baseColor);
        return bitmap;
    }

    /// <summary>
    /// The hollow bar tinted by <paramref name="alpha"/> with the status glyph ("!" / "...")
    /// centred over it in a font sized to the cell (about 0.55 x size px, created and disposed per
    /// call so every cell size gets a glyph that fits).
    /// </summary>
    private Bitmap MakeStatusBitmap(string text, Color baseColor, double alpha, int size)
    {
        Color tinted = WithAlpha(baseColor, alpha);
        var bitmap = NewCanvas(size, size);
        using var g = NewGraphics(bitmap);
        DrawHollowBar(g, size, tinted);

        float bodyWidth = size - OutlineWidth(size);
        using var glyphFont = new Font(_statusFont.FontFamily, size * StatusGlyphRatio, FontStyle.Regular, GraphicsUnit.Pixel);
        SizeF textSize = MeasureTight(g, text, glyphFont);
        using (var brush = new SolidBrush(tinted))
        {
            // Centred over the outline body (not the nub) and the full cell height.
            g.DrawString(text, glyphFont, brush,
                (bodyWidth - textSize.Width) / 2f,
                (size - textSize.Height) / 2f,
                _tightFormat);
        }

        return bitmap;
    }

    private static void DrawHollowBar(Graphics g, int size, Color color)
    {
        float height = (float)Math.Round(size * HollowBarHeightRatio);
        float y = (float)Math.Round((size - height) / 2f);
        DrawBar(g, size, y, height, color, percent: null);
    }

    // unused since the square tray icon; flagged for removal
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

            SizeF textSize = MeasureTight(_measureGraphics, countdown, _cellFont);
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
                    _tightFormat);
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
    private static StringFormat CreateTightFormat()
    {
        var fmt = (StringFormat)StringFormat.GenericTypographic.Clone();
        fmt.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces;
        return fmt;
    }

    private SizeF MeasureTight(Graphics g, string text, Font font) =>
        g.MeasureString(text, font, int.MaxValue, _tightFormat);

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
        _tightFormat.Dispose();
        _measureGraphics.Dispose();
        _measureBitmap.Dispose();
    }
}
