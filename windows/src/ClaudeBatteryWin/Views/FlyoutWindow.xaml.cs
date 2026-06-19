using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using ClaudeBatteryWin.Icons;
using ClaudeBatteryWin.ViewModels;

namespace ClaudeBatteryWin.Views;

/// <summary>
/// The borderless, topmost flyout popover window (U10). It hosts the <see cref="FlyoutViewModel"/>
/// (set as the DataContext by the integration layer), swaps the light/dark token dictionary live on
/// a theme flip, dismisses on Deactivated (unless a login is in progress), closes on Escape, and
/// positions itself against the tray icon's rect with a cursor-anchored, work-area-clamped fallback
/// for the overflow case.
///
/// <para>
/// <b>Why a window and not the library TrayPopup.</b> The plan pins this: a borderless
/// <c>WindowStyle=None</c> / <c>AllowsTransparency=true</c> / <c>ShowInTaskbar=false</c> /
/// <c>Topmost=true</c> window gives full control of placement (multi-monitor + PerMonitorV2 DPI) and
/// of the signing-in dismissal suppression, which the library popup does not expose.
/// </para>
///
/// <para>
/// The placement math is factored into the pure static <see cref="FlyoutPlacement"/> so the
/// secondary-monitor/different-DPI test asserts the arithmetic without a real screen. The window
/// method only gathers the live inputs (tray rect, cursor, work area, DPI) and feeds them in.
/// </para>
/// </summary>
public partial class FlyoutWindow : Window
{
    /// The tray icon GUID registered in App.xaml. Shell_NotifyIconGetRect keys on this exact value;
    /// it MUST match the TaskbarIcon.Id in App.xaml or the rect lookup returns the overflow fallback.
    private static readonly Guid TrayIconGuid = new("7E2C1B44-9F3A-4D21-B8E6-0C5A1F2D3E40");

    private FlyoutViewModel? ViewModel => DataContext as FlyoutViewModel;

    public FlyoutWindow()
    {
        InitializeComponent();
    }

    // MARK: - Theme

    /// <summary>
    /// Swap the merged light/dark token dictionary live, so a theme flip re-themes the open flyout
    /// without a close/reopen (the DynamicResource bindings pick up the new brushes). The integration
    /// layer calls this from <c>ThemeWatcher.BucketChanged</c>. Replacing the dictionary in
    /// <see cref="FrameworkElement.Resources"/> is what makes every DynamicResource consumer re-resolve.
    /// </summary>
    public void ApplyTheme(ThemeBucket bucket)
    {
        var source = bucket == ThemeBucket.Dark
            ? "Themes/DarkTokens.xaml"
            : "Themes/LightTokens.xaml";
        var dict = new ResourceDictionary
        {
            Source = new Uri($"pack://application:,,,/{source}", UriKind.Absolute),
        };

        // Replace the single theme dictionary (kept first by convention) rather than appending, so
        // repeated flips do not stack dictionaries. The structural (non-theme) dictionary, if any,
        // stays.
        if (Resources.MergedDictionaries.Count > 0)
        {
            Resources.MergedDictionaries[0] = dict;
        }
        else
        {
            Resources.MergedDictionaries.Add(dict);
        }
    }

    // MARK: - Dismissal

    /// <summary>
    /// Dismiss on loss of activation, EXCEPT while a login is in progress -- the login window steals
    /// focus and we must not lose the signing-in spinner behind it. Mirrors the Mac suppression flag.
    /// </summary>
    protected override void OnDeactivated(EventArgs e)
    {
        base.OnDeactivated(e);
        if (ViewModel?.SuppressDismissOnDeactivate == true)
        {
            return;
        }
        Hide();
    }

    /// <summary>Escape closes the flyout (a standard popover affordance). Mac/Windows parity.</summary>
    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            Hide();
        }
    }

    // MARK: - Placement

    /// <summary>
    /// Show the flyout anchored to the tray icon. Resolves the tray rect via
    /// <c>Shell_NotifyIconGetRect</c> (keyed on the registered GUID); when that fails (the icon is in
    /// the overflow flyout, so it has no on-screen rect), falls back to cursor anchoring. Either way
    /// the result is clamped to the work area of the monitor the anchor is on, honoring PerMonitorV2
    /// DPI. The actual arithmetic lives in <see cref="FlyoutPlacement.Compute"/> so it is testable.
    /// </summary>
    public void ShowAtTray()
    {
        if (!IsVisible)
        {
            Show();
        }

        // Ensure Width/Height are measured so the placement has the real flyout size.
        UpdateLayout();

        var hasTrayRect = TryGetTrayRect(out var trayRect);
        var cursor = GetCursorPosition();
        var anchorPoint = hasTrayRect
            ? new PlacementPoint(trayRect.Left, trayRect.Top)
            : cursor;
        var workArea = GetWorkAreaForPoint(anchorPoint);

        var placed = FlyoutPlacement.Compute(
            hasTrayRect ? trayRect : (PlacementRect?)null,
            cursor,
            workArea,
            new PlacementSize(ActualWidth, ActualHeight));

        Left = placed.X;
        Top = placed.Y;

        Topmost = true;
        Activate();
    }

    private static bool TryGetTrayRect(out PlacementRect rect)
    {
        rect = default;
        var identifier = new NOTIFYICONIDENTIFIER
        {
            cbSize = (uint)Marshal.SizeOf<NOTIFYICONIDENTIFIER>(),
            hWnd = IntPtr.Zero,
            uID = 0,
            guidItem = TrayIconGuid,
        };

        var hr = Shell_NotifyIconGetRect(ref identifier, out var win32Rect);
        // S_OK (0) means the icon has an on-screen rect. Any failure (incl. the icon being in the
        // overflow flyout -> the documented error) means "no rect"; the caller falls back to cursor.
        if (hr != 0)
        {
            return false;
        }

        rect = new PlacementRect(win32Rect.left, win32Rect.top, win32Rect.right, win32Rect.bottom);
        // A zeroed rect is also "no usable anchor" (some shells report S_OK with an empty rect for an
        // overflow icon); treat it as the fallback case rather than anchoring at the origin.
        return rect.Width > 0 && rect.Height > 0;
    }

    private static PlacementPoint GetCursorPosition()
    {
        if (GetCursorPos(out var p))
        {
            return new PlacementPoint(p.X, p.Y);
        }
        return new PlacementPoint(0, 0);
    }

    /// <summary>
    /// The work area (screen minus taskbar) of the monitor under <paramref name="point"/>, in device
    /// pixels. Uses MONITOR_DEFAULTTONEAREST so a point just off any monitor still lands on the
    /// closest one, matching how the flyout should appear on the monitor the user is interacting with.
    /// </summary>
    private static PlacementRect GetWorkAreaForPoint(PlacementPoint point)
    {
        var pt = new POINT { X = (int)point.X, Y = (int)point.Y };
        var monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
        var info = new MONITORINFO { cbSize = (uint)Marshal.SizeOf<MONITORINFO>() };
        if (monitor != IntPtr.Zero && GetMonitorInfo(monitor, ref info))
        {
            var wa = info.rcWork;
            return new PlacementRect(wa.left, wa.top, wa.right, wa.bottom);
        }
        // Fallback to the primary screen work area dimensions.
        return new PlacementRect(0, 0,
            (int)SystemParameters.WorkArea.Width,
            (int)SystemParameters.WorkArea.Height);
    }

    // MARK: - Win32 interop

    [DllImport("shell32.dll", SetLastError = false)]
    private static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER identifier, out RECT iconLocation);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    private const uint MONITOR_DEFAULTTONEAREST = 2;

    [StructLayout(LayoutKind.Sequential)]
    private struct NOTIFYICONIDENTIFIER
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public Guid guidItem;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public uint cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }
}

// MARK: - Placement geometry (pure, testable)

/// <summary>A rectangle in device pixels, top-left origin. Width/Height derive from the edges.</summary>
public readonly record struct PlacementRect(double Left, double Top, double Right, double Bottom)
{
    public double Width => Right - Left;
    public double Height => Bottom - Top;
}

/// <summary>A point in device pixels.</summary>
public readonly record struct PlacementPoint(double X, double Y);

/// <summary>A size in device pixels.</summary>
public readonly record struct PlacementSize(double Width, double Height);

/// <summary>
/// Pure placement math for the flyout, factored out of <see cref="FlyoutWindow"/> so it is unit
/// testable without a real screen, tray, or DPI context. All inputs are in device pixels.
///
/// <para>
/// Strategy, mirroring how a tray popover lands on Windows:
/// </para>
/// <list type="number">
///   <item>Pick an anchor. When a tray rect is available, anchor to it (the icon's on-screen box);
///   otherwise the icon is in the overflow flyout and we anchor to the cursor.</item>
///   <item>Prefer to place the flyout ABOVE the anchor (the taskbar is usually at the bottom, so the
///   icon's natural reading direction is upward), right-aligned toward the anchor's right edge.</item>
///   <item>Clamp the final rect fully inside the supplied work area (the monitor under the anchor,
///   minus the taskbar). This is what keeps a flyout on a secondary monitor at a different DPI inside
///   that monitor's work area: the work area is already that monitor's, and the clamp guarantees the
///   flyout never spills past any edge. If the flyout is taller than the work area it is pinned to the
///   top so its header stays visible.</item>
/// </list>
/// </summary>
public static class FlyoutPlacement
{
    /// A small gap between the flyout and the tray/anchor, in device pixels.
    private const double Margin = 8;

    /// <summary>
    /// Compute the top-left position for the flyout.
    /// </summary>
    /// <param name="trayRect">
    /// The tray icon's on-screen rect, or null when the icon is in the overflow flyout (cursor
    /// fallback).
    /// </param>
    /// <param name="cursor">The cursor position (used when <paramref name="trayRect"/> is null).</param>
    /// <param name="workArea">The work area of the monitor the flyout should land on (device pixels).</param>
    /// <param name="size">The flyout's measured size (device pixels).</param>
    /// <returns>The clamped top-left point, guaranteed inside <paramref name="workArea"/>.</returns>
    public static PlacementPoint Compute(
        PlacementRect? trayRect,
        PlacementPoint cursor,
        PlacementRect workArea,
        PlacementSize size)
    {
        // Anchor: the tray rect's bottom-right when available, else the cursor.
        double anchorRight;
        double anchorTop;
        if (trayRect is { } tray)
        {
            anchorRight = tray.Right;
            anchorTop = tray.Top;
        }
        else
        {
            anchorRight = cursor.X;
            anchorTop = cursor.Y;
        }

        // Right-align the flyout's right edge to the anchor's right edge; place it above the anchor.
        var left = anchorRight - size.Width;
        var top = anchorTop - size.Height - Margin;

        // Clamp horizontally inside the work area. If the flyout is wider than the work area, pin it
        // to the left edge (its left stays visible).
        var maxLeft = workArea.Right - size.Width;
        if (left > maxLeft)
        {
            left = maxLeft;
        }
        if (left < workArea.Left)
        {
            left = workArea.Left;
        }

        // Clamp vertically. If placing above pushed it off the top of the work area, flip to below
        // the anchor; then clamp to the bottom edge. If it is taller than the work area, pin to top.
        if (top < workArea.Top)
        {
            // Below the anchor: use the anchor's bottom when we have a tray rect, else the cursor.
            var anchorBottom = trayRect is { } t ? t.Bottom : cursor.Y;
            top = anchorBottom + Margin;
        }

        var maxTop = workArea.Bottom - size.Height;
        if (top > maxTop)
        {
            top = maxTop;
        }
        if (top < workArea.Top)
        {
            top = workArea.Top;
        }

        return new PlacementPoint(left, top);
    }
}

// MARK: - Value converters (inline; no Controls/ library until a second consumer exists)

/// <summary>
/// Shows an element only when the bound <see cref="FlyoutContentState"/> equals the state named in
/// the converter parameter, so each content panel is gated on exactly one state. An unrecognized
/// parameter collapses the element (fail-closed). This is how the XAML reproduces the Mac if/else
/// cascade declaratively.
/// </summary>
public sealed class ContentStateToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is FlyoutContentState state
            && parameter is string name
            && Enum.TryParse<FlyoutContentState>(name, ignoreCase: true, out var target))
        {
            return state == target ? Visibility.Visible : Visibility.Collapsed;
        }
        return Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>
/// Maps a <see cref="UsageColor"/> bucket to its theme-invariant semantic brush (red/orange/green),
/// resolved from the application/window resources so a token override still applies. A null value
/// (no color, e.g. an absent pace bar) yields <see cref="Brushes.Transparent"/>.
/// </summary>
public sealed class UsageColorToBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var key = value switch
        {
            UsageColor.Red => "UsageRedBrush",
            UsageColor.Orange => "UsageOrangeBrush",
            UsageColor.Green => "UsageGreenBrush",
            _ => null,
        };
        return ResolveBrush(key);
    }

    public object ConvertBack(object value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();

    internal static Brush ResolveBrush(string? key)
    {
        if (key is not null && Application.Current?.TryFindResource(key) is Brush brush)
        {
            return brush;
        }
        return Brushes.Transparent;
    }
}

/// <summary>
/// Maps a <see cref="SpendColor"/> bucket (cyan/orange/red) to its semantic brush. A null value
/// (empty spend track) yields <see cref="Brushes.Transparent"/>, so the disabled-state credits bar
/// shows an empty track.
/// </summary>
public sealed class SpendColorToBrushConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var key = value switch
        {
            SpendColor.Cyan => "SpendCyanBrush",
            SpendColor.Orange => "UsageOrangeBrush",
            SpendColor.Red => "UsageRedBrush",
            _ => null,
        };
        return UsageColorToBrushConverter.ResolveBrush(key);
    }

    public object ConvertBack(object value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>
/// <see cref="bool"/> to <see cref="Visibility"/>. The converter parameter "Invert" flips the sense,
/// so one converter instance covers both "show when true" and "show when false" (used for the
/// Models-present split and the update-row branch).
/// </summary>
public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var flag = value is true;
        if (parameter is string s && string.Equals(s, "Invert", StringComparison.OrdinalIgnoreCase))
        {
            flag = !flag;
        }
        return flag ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>
/// Maps a 0-100 percent to a pixel width given a track width passed as the converter parameter (the
/// bar's full pixel width). Clamps the percent to 0-100 so an out-of-range value never overflows the
/// track. A null/non-numeric value yields width 0 (empty fill). This reproduces the Mac
/// <c>geo.size.width * value / 100</c> fill math in a binding.
/// </summary>
public sealed class PercentToWidthConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is null)
        {
            return 0.0;
        }

        double percent;
        try
        {
            percent = System.Convert.ToDouble(value, CultureInfo.InvariantCulture);
        }
        catch (Exception ex) when (ex is FormatException or InvalidCastException or OverflowException)
        {
            return 0.0;
        }

        double trackWidth = 0;
        if (parameter is string s && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var w))
        {
            trackWidth = w;
        }

        var clamped = Math.Max(0, Math.Min(100, percent));
        return trackWidth * clamped / 100.0;
    }

    public object ConvertBack(object value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>
/// Produces the gauge arc <see cref="Geometry"/> for a <see cref="GaugeCard"/>: the full 270-degree
/// track ("track") or the fill trimmed to the remaining percent ("fill"), on the same geometry as
/// the Mac <c>ArcShape</c> (start 135 degrees, sweep 270 degrees, clockwise). The arc is sized to a
/// fixed nominal box matching the Mac 58pt gauge; WPF scales the Path to its layout slot.
/// </summary>
public sealed class GaugeArcConverter : IValueConverter
{
    // Nominal geometry box. The Mac centers at (midX, midY+6) with radius min(w,h)/2 - 3 over a
    // ~58pt square; these constants reproduce that arc proportionally.
    private const double BoxSize = 58;
    private const double Radius = BoxSize / 2 - 3;
    private const double CenterX = BoxSize / 2;
    private const double CenterY = BoxSize / 2 + 6;
    private const double StartAngleDeg = 135;
    private const double SweepDeg = 270;

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not GaugeCard card)
        {
            return null;
        }

        var which = parameter as string ?? "fill";
        double fraction = string.Equals(which, "track", StringComparison.OrdinalIgnoreCase)
            ? 1.0
            : Math.Max(0, Math.Min(100, card.RemainingPercent)) / 100.0;

        return BuildArc(fraction);
    }

    public object ConvertBack(object value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();

    private static Geometry BuildArc(double fraction)
    {
        var geometry = new StreamGeometry();
        if (fraction <= 0)
        {
            return geometry; // empty: nothing to draw for a 0% fill
        }

        var sweep = SweepDeg * fraction;
        var start = PointOnArc(StartAngleDeg);
        var end = PointOnArc(StartAngleDeg + sweep);

        using (var ctx = geometry.Open())
        {
            ctx.BeginFigure(start, isFilled: false, isClosed: false);
            ctx.ArcTo(
                end,
                new Size(Radius, Radius),
                rotationAngle: 0,
                isLargeArc: sweep > 180,
                SweepDirection.Clockwise,
                isStroked: true,
                isSmoothJoin: false);
        }

        geometry.Freeze();
        return geometry;
    }

    private static Point PointOnArc(double angleDeg)
    {
        var radians = angleDeg * Math.PI / 180.0;
        return new Point(CenterX + Radius * Math.Cos(radians), CenterY + Radius * Math.Sin(radians));
    }
}

/// <summary>
/// Produces the interior tick marks for a <see cref="GaugeCard"/> arc: <c>TickCount</c> short radial
/// notches (5 for the session gauge, 7 for weekly) spaced evenly across the same 270-degree sweep as
/// <see cref="GaugeArcConverter"/>. The Mac drew these subtle gauge ticks; they were computed in the
/// view-model (<c>TickCount</c>) but never rendered (issue #25). Returns an empty geometry for a card
/// with fewer than two ticks.
/// </summary>
public sealed class GaugeTicksConverter : IValueConverter
{
    // Same nominal geometry box as GaugeArcConverter so the ticks sit on the arc.
    private const double BoxSize = 58;
    private const double Radius = BoxSize / 2 - 3;
    private const double CenterX = BoxSize / 2;
    private const double CenterY = BoxSize / 2 + 6;
    private const double StartAngleDeg = 135;
    private const double SweepDeg = 270;
    private const double TickHalfLength = 3.0; // notch length, centered on the track radius

    public object? Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is not GaugeCard card || card.TickCount < 2)
        {
            return Geometry.Empty;
        }

        var group = new GeometryGroup();
        for (var i = 0; i < card.TickCount; i++)
        {
            var angle = StartAngleDeg + SweepDeg * i / (card.TickCount - 1);
            var radians = angle * Math.PI / 180.0;
            var cos = Math.Cos(radians);
            var sin = Math.Sin(radians);
            var inner = new Point(CenterX + (Radius - TickHalfLength) * cos, CenterY + (Radius - TickHalfLength) * sin);
            var outer = new Point(CenterX + (Radius + TickHalfLength) * cos, CenterY + (Radius + TickHalfLength) * sin);
            group.Children.Add(new LineGeometry(inner, outer));
        }

        group.Freeze();
        return group;
    }

    public object ConvertBack(object value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
