using System;

namespace ClaudeBatteryWin.Icons;

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
internal readonly struct RenderSignature : IEquatable<RenderSignature>
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
                (int)battery.Reading.SessionDisplayRemaining,
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
