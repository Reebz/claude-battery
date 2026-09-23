using System.Drawing;

namespace ClaudeBatteryWin.Icons;

/// <summary>
/// Holds whichever tray icon style is currently selected, and swaps it when the user picks another
/// one (R39).
///
/// The swap has to do two things at once: dispose the style being left, so its GDI+ handles go, and
/// make sure the first paint in the new style actually happens. Both fall out of building a fresh
/// renderer: a new one has no remembered signature, so it cannot decide the icon is already right.
/// Keeping that in one place means the app's startup path and the Settings change path cannot drift.
/// </summary>
public sealed class TrayIconRendererHost : IDisposable
{
    private ITrayIconRenderer _renderer;

    public TrayIconRendererHost(TrayIconStyle style)
    {
        Style = style;
        _renderer = TrayIconStyles.Create(style);
    }

    public TrayIconStyle Style { get; private set; }

    /// <summary>The renderer for the current style. Never null until <see cref="Dispose"/>.</summary>
    public ITrayIconRenderer Current => _renderer;

    /// <summary>
    /// Point the host at a style. Returns true when the style actually changed, so the caller can
    /// skip a repaint for a settings change that was about something else.
    /// </summary>
    public bool SetStyle(TrayIconStyle style)
    {
        if (style == Style)
        {
            return false;
        }

        var previous = _renderer;
        _renderer = TrayIconStyles.Create(style);
        Style = style;
        previous.Dispose();
        return true;
    }

    public Bitmap? Render(TrayRenderState state, ThemeBucket theme, string countdown, int size = 16) =>
        _renderer.Render(state, theme, countdown, size);

    public void ResetSignature() => _renderer.ResetSignature();

    public long SuppressedCount => _renderer.SuppressedCount;

    public void Dispose() => _renderer.Dispose();
}
