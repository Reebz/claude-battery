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
/// <c>Topmost=true</c> window gives full control of placement (multi-monitor + DPI scaling) and
/// of the signing-in dismissal suppression, which the library popup does not expose.
/// </para>
///
/// <para>
/// <b>Units.</b> The process is system-DPI-aware (WPF's default; there is no app manifest and this
/// change must not add one), so every Win32 coordinate (tray rect, cursor, monitor work area) is in
/// device pixels of the one session DPI, while WPF's <c>ActualWidth</c>/<c>ActualHeight</c> and
/// <c>Left</c>/<c>Top</c> are device-independent units (DIPs). Placement runs entirely in device
/// pixels and converts at the boundary with <see cref="FlyoutPlacement.ToDevice"/> /
/// <see cref="FlyoutPlacement.ToDips"/>, using the window's own <c>TransformToDevice</c> scale.
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
    /// <summary>
    /// The live tray icon GUID, assigned by the composition root AFTER the tray icon is created (the
    /// library derives its default Id from the process path, and a creation retry may replace it, so
    /// the value must be read from the created icon, never hard-coded). Shell_NotifyIconGetRect keys
    /// on this exact value. While it is still <see cref="Guid.Empty"/> (not yet assigned) the rect
    /// lookup reports "no rect" and placement falls back to the cursor anchor.
    /// </summary>
    internal static Guid TrayIconGuid { get; set; } = Guid.Empty;

    /// <summary>
    /// Monotonic stamp (<see cref="Environment.TickCount64"/>) of the last Hide() caused by a loss of
    /// activation; null when the last hide was not a deactivation or has been consumed. Used by the
    /// tray-click toggle: a click on the tray icon deactivates (and hides) the open flyout BEFORE the
    /// icon's mouse-up arrives, so the show request that follows within a short window is really the
    /// second half of a toggle-close and must be swallowed.
    /// </summary>
    private long? _hiddenByDeactivationAtMs;

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
    /// This only works because the window's base dictionary defines NO theme token itself: WPF reads
    /// the base dictionary before the merged ones, so a base-level token would shadow the swap.
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

        // Replace the single theme dictionary (slot 0, seeded with DarkTokens.xaml by the XAML) rather
        // than appending, so repeated flips do not stack dictionaries. The structural (non-theme)
        // dictionary, if any, stays.
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
        // Stamp ONLY this hide (not Escape, not the suppressed early return) so a tray click that
        // just dismissed the flyout can be recognized as a toggle-close by ShouldTreatAsToggleClose.
        _hiddenByDeactivationAtMs = Environment.TickCount64;
        Hide();
    }

    // MARK: - Tray-click toggle

    /// <summary>
    /// The default window after a deactivation-hide during which a tray click counts as the close
    /// half of a toggle (the EarTrumpet pattern, which uses 300 ms). Known limitation: a press held
    /// longer than this before release still reopens the panel, which is harmless.
    /// </summary>
    internal const long ToggleCloseWindowMs = 400;

    /// <summary>
    /// Pure decision: was the flyout hidden by a deactivation so recently that a show request now is
    /// really the second half of a toggle-close? Monotonic milliseconds (<see cref="Environment.TickCount64"/>)
    /// so a wall-clock step cannot swallow or admit a click. A null stamp or a negative delta is never
    /// a toggle.
    /// </summary>
    internal static bool ShouldTreatAsToggleClose(long? hiddenAtMs, long nowMs, long windowMs = ToggleCloseWindowMs)
    {
        if (hiddenAtMs is not { } hidden)
        {
            return false;
        }
        var delta = nowMs - hidden;
        return delta >= 0 && delta < windowMs;
    }

    /// <summary>
    /// Read-and-clear the deactivation-hide stamp: true when the flyout was hidden by a deactivation
    /// within the toggle window of <paramref name="nowMs"/>. The composition root calls this on the
    /// tray-click path (only; the second-instance signal keeps the unguarded show) and skips the show
    /// when it returns true. Clearing on every call means a stale stamp never blocks a later click.
    /// </summary>
    internal bool ConsumeRecentDeactivationHide(long nowMs)
    {
        var result = ShouldTreatAsToggleClose(_hiddenByDeactivationAtMs, nowMs);
        _hiddenByDeactivationAtMs = null;
        return result;
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
    /// <c>Shell_NotifyIconGetRect</c> (keyed on the live <see cref="TrayIconGuid"/>); when that fails
    /// (the icon is in the overflow flyout, so it has no on-screen rect), falls back to cursor
    /// anchoring. Either way the result is clamped to the work area of the monitor the anchor is on,
    /// with the DIP/device-pixel conversion done at the boundary (the process is system-DPI-aware).
    /// The actual arithmetic lives in <see cref="FlyoutPlacement.Compute"/> so it is testable.
    /// </summary>
    public void ShowAtTray()
    {
        // A successful show consumes any deactivation-hide stamp so it can never block a later click.
        _hiddenByDeactivationAtMs = null;

        if (!IsVisible)
        {
            Show();
        }

        // Ensure Width/Height are measured so the placement has the real flyout size. Show() has run,
        // so the PresentationSource (and with it the DPI scale) is available to Reposition.
        UpdateLayout();
        Reposition(new PlacementSize(ActualWidth, ActualHeight));

        Topmost = true;
        Activate();
    }

    /// <summary>
    /// The window is SizeToContent=Height, and the visible content panel swaps while the flyout is
    /// open (Loading -> Authenticated on the first poll, for example). WPF keeps Left/Top on a resize,
    /// so growth would extend downward over the taskbar and off-screen; re-run the placement so the
    /// bottom edge stays anchored above the tray. The override also fires during ShowAtTray's own
    /// Show()/UpdateLayout(), which just re-runs the same placement with identical inputs. No
    /// Activate()/Topmost here: a size-driven reposition must not steal focus.
    /// </summary>
    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
    {
        base.OnRenderSizeChanged(sizeInfo);
        if (IsVisible && IsLoaded && sizeInfo.HeightChanged)
        {
            Reposition(new PlacementSize(sizeInfo.NewSize.Width, sizeInfo.NewSize.Height));
        }
    }

    /// <summary>
    /// Place the window for the given DIP size: gather the live device-pixel inputs (tray rect,
    /// cursor, work area), convert the size to device pixels, compute, and convert the result back to
    /// DIPs for Left/Top. Never calls UpdateLayout() itself (it runs from inside a layout pass).
    /// </summary>
    private void Reposition(PlacementSize dipSize)
    {
        var (sx, sy) = DeviceScale();

        var hasTrayRect = TryGetTrayRect(out var trayRect);
        var cursor = GetCursorPosition();
        var anchorPoint = hasTrayRect
            ? new PlacementPoint(trayRect.Left, trayRect.Top)
            : cursor;
        var workArea = GetWorkAreaForPoint(anchorPoint, sx, sy);

        var placed = FlyoutPlacement.Compute(
            hasTrayRect ? trayRect : (PlacementRect?)null,
            cursor,
            workArea,
            FlyoutPlacement.ToDevice(dipSize, sx, sy));

        var dip = FlyoutPlacement.ToDips(placed, sx, sy);
        Left = dip.X;
        Top = dip.Y;
    }

    /// <summary>
    /// The DIP-to-device scale of this window's presentation source (M11/M22 of TransformToDevice).
    /// Identity when the window has no source yet (before Show()). Under system-DPI awareness this is
    /// the single session scale, so it is exact on every monitor.
    /// </summary>
    private (double sx, double sy) DeviceScale()
    {
        var m = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice ?? Matrix.Identity;
        return (m.M11, m.M22);
    }

    private static bool TryGetTrayRect(out PlacementRect rect)
    {
        rect = default;
        if (TrayIconGuid == Guid.Empty)
        {
            // Not yet assigned by the composition root: no rect to key on, use the cursor anchor.
            return false;
        }
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
    /// Falls back to the primary monitor (same physical-pixel API), and only then to
    /// <see cref="SystemParameters.WorkArea"/>, which is in DIPs and so is scaled by
    /// (<paramref name="sx"/>, <paramref name="sy"/>) so every branch yields device pixels.
    /// </summary>
    private static PlacementRect GetWorkAreaForPoint(PlacementPoint point, double sx, double sy)
    {
        var pt = new POINT { X = (int)point.X, Y = (int)point.Y };
        if (TryGetMonitorWorkArea(MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST), out var nearest))
        {
            return nearest;
        }
        if (TryGetMonitorWorkArea(MonitorFromPoint(pt, MONITOR_DEFAULTTOPRIMARY), out var primary))
        {
            return primary;
        }
        var wa = SystemParameters.WorkArea;
        return new PlacementRect(wa.Left * sx, wa.Top * sy, wa.Right * sx, wa.Bottom * sy);
    }

    private static bool TryGetMonitorWorkArea(IntPtr monitor, out PlacementRect workArea)
    {
        workArea = default;
        var info = new MONITORINFO { cbSize = (uint)Marshal.SizeOf<MONITORINFO>() };
        if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref info))
        {
            return false;
        }
        var wa = info.rcWork;
        workArea = new PlacementRect(wa.left, wa.top, wa.right, wa.bottom);
        return true;
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

    private const uint MONITOR_DEFAULTTOPRIMARY = 1;
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
/// testable without a real screen, tray, or DPI context. All inputs to <see cref="Compute"/> are in
/// device pixels; the window converts its DIP size in with <see cref="ToDevice"/> and the result
/// back out with <see cref="ToDips"/>.
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

    /// <summary>Scale a DIP size to device pixels by the window's (M11, M22) DPI scale.</summary>
    public static PlacementSize ToDevice(PlacementSize dips, double sx, double sy)
        => new(dips.Width * sx, dips.Height * sy);

    /// <summary>Scale a device-pixel point back to DIPs by the window's (M11, M22) DPI scale.</summary>
    public static PlacementPoint ToDips(PlacementPoint device, double sx, double sy)
        => new(device.X / sx, device.Y / sy);

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
/// Maps a <see cref="UsageColor"/> bucket to its theme-invariant semantic brush (red/orange/green).
/// The brushes are frozen static constants, NOT resource lookups: a converter has no element
/// context, and <c>Application.TryFindResource</c> never sees a window's resources or the theme
/// dictionaries merged into it, so a lookup there silently returned Transparent and every gauge
/// fill and bar was invisible. The semantic colors are the same in both theme dictionaries (Mac
/// parity), so nothing is lost by pinning them here; a token override does NOT apply to
/// converter-driven brushes. A null value (no color, e.g. an absent pace bar) yields
/// <see cref="Brushes.Transparent"/>.
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

    // Frozen constants: the values of UsageRedBrush/UsageOrangeBrush/UsageGreenBrush/SpendCyanBrush in
    // Themes/DarkTokens.xaml (the cyan is the dark/window value; the light-theme cyan variant is not
    // used for converter-driven brushes).
    private static readonly SolidColorBrush Red = Frozen(0xE7, 0x4C, 0x3C);
    private static readonly SolidColorBrush Orange = Frozen(0xF3, 0x9C, 0x12);
    private static readonly SolidColorBrush Green = Frozen(0x2E, 0xCC, 0x71);
    private static readonly SolidColorBrush Cyan = Frozen(0x22, 0xC3, 0xE6);

    private static SolidColorBrush Frozen(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }

    internal static Brush ResolveBrush(string? key) => key switch
    {
        "UsageRedBrush" => Red,
        "UsageOrangeBrush" => Orange,
        "UsageGreenBrush" => Green,
        "SpendCyanBrush" => Cyan,
        _ => Brushes.Transparent,
    };
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
/// Maps a 0-100 percent (values[0]) to a pixel width against the track's REAL width (values[1], bound
/// to the track element's <c>ActualWidth</c>). Clamps the percent to 0-100 so an out-of-range value
/// never overflows the track. Either value missing (<see cref="DependencyProperty.UnsetValue"/>,
/// null, or non-numeric) yields width 0 (empty fill). This reproduces the Mac
/// <c>geo.size.width * value / 100</c> fill math in a binding without a hard-coded track width, which
/// drifted from the layout and overstated every bar.
/// </summary>
public sealed class PercentOfWidthConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object? parameter, CultureInfo culture)
    {
        if (values is null || values.Length < 2)
        {
            return 0.0;
        }
        if (!TryToDouble(values[0], out var percent) || !TryToDouble(values[1], out var trackWidth))
        {
            return 0.0;
        }

        var clamped = Math.Max(0, Math.Min(100, percent));
        return trackWidth * clamped / 100.0;
    }

    public object[] ConvertBack(object value, Type[] targetTypes, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();

    private static bool TryToDouble(object? value, out double result)
    {
        result = 0;
        if (value is null || value == DependencyProperty.UnsetValue)
        {
            return false;
        }
        try
        {
            result = System.Convert.ToDouble(value, CultureInfo.InvariantCulture);
        }
        catch (Exception ex) when (ex is FormatException or InvalidCastException or OverflowException)
        {
            return false;
        }
        return !double.IsNaN(result) && !double.IsInfinity(result);
    }
}

/// <summary>
/// Produces the gauge arc <see cref="Geometry"/> for a <see cref="GaugeCard"/>: the full 270-degree
/// track ("track") or the fill trimmed to the remaining percent ("fill"), on the same geometry as
/// the Mac <c>ArcShape</c> (start 135 degrees, sweep 270 degrees, clockwise). The arc is built in
/// absolute coordinates of a fixed 58x58 box matching the Mac 58pt gauge. The consuming Paths use
/// the WPF default Stretch=None (no scaling to the layout slot), so the XAML hosts them in a Grid
/// that is exactly that 58x58 box, centred in the card.
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
