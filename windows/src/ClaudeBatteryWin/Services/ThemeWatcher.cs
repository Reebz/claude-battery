using ClaudeBatteryWin.Icons;
using Microsoft.Win32;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The two light/dark buckets Windows keeps: <see cref="Tray"/> follows the taskbar/Start/notification
/// area (<c>SystemUsesLightTheme</c>) and <see cref="App"/> follows app windows
/// (<c>AppsUseLightTheme</c>). They are independent settings and the stock Windows 10 theme splits
/// them (dark taskbar, light apps), so the tray icon must paint for <see cref="Tray"/> and the flyout
/// for <see cref="App"/>. Value equality (record struct) is what the dedup compares.
/// </summary>
public readonly record struct ThemeBuckets(ThemeBucket Tray, ThemeBucket App);

/// <summary>
/// Watches the system light/dark settings and raises <see cref="BucketsChanged"/> only on a real
/// flip, so the tray renderer (U9) re-renders exactly once per theme switch and never churns on
/// unrelated system broadcasts. This is the explicit Windows analog of the Mac issue-#11
/// <c>effectiveAppearance</c> KVO loop fix in MenuBarController:
///
/// <list type="bullet">
/// <item><description>Source of truth is two registry values under
/// <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize</c>:
/// <c>SystemUsesLightTheme</c> drives the taskbar (and so the tray icon colour; 0 = dark, non-zero =
/// light, MISSING = dark because a pre-1903 taskbar has no value and is always dark) and
/// <c>AppsUseLightTheme</c> drives app windows (and so the flyout; 0 = dark, non-zero / missing =
/// light). Both are collapsed to a <see cref="ThemeBuckets"/>. Reading only the app value is wrong:
/// the stock Windows 10 theme is dark taskbar + light apps, which drew a black icon on a black
/// taskbar.</description></item>
/// <item><description>Reacts to <see cref="SystemEvents.UserPreferenceChanged"/> FILTERED to
/// <c>Category == General</c> -- the analog of <c>shouldReactToAppearanceChange</c> dropping
/// non-brightness fires. <c>General</c> is the category that carries theme/personalization
/// changes for BOTH values (Windows mode and app mode broadcast the same ImmersiveColorSet);
/// <c>Color</c>, <c>Locale</c>, <c>Mouse</c>, etc. are ignored before any registry
/// read.</description></item>
/// <item><description>Debounced: General can fire several times in a burst during a theme swap, so
/// a short coalescing window collapses the burst into one re-read.</description></item>
/// <item><description>Bucket-collapsing dedup: after re-reading, the event is raised only when
/// either bucket actually changed from the last raised pair, so a re-read that lands on the same
/// pair is suppressed (mirrors the Mac <c>oldDark != newDark</c> guard).</description></item>
/// </list>
///
/// The reader and the debounce scheduler are injectable so the dedup/debounce logic is unit
/// testable without touching the real registry or pumping the Win32 message loop. In production
/// the defaults read the registry and post the coalesced re-read onto a WPF dispatcher timer.
/// </summary>
public sealed class ThemeWatcher : IDisposable
{
    private const string PersonalizeKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private const string AppsUseLightThemeValue = "AppsUseLightTheme";
    private const string SystemUsesLightThemeValue = "SystemUsesLightTheme";

    private readonly Func<ThemeBuckets> _readBuckets;
    private readonly Action<Action> _scheduleDebounced;
    private readonly object _gate = new();

    private bool _started;
    private bool _disposed;
    private bool _pending;

    /// <summary>The last bucket pair actually surfaced through <see cref="BucketsChanged"/>.</summary>
    public ThemeBuckets CurrentBuckets { get; private set; }

    /// <summary>The taskbar bucket (<c>SystemUsesLightTheme</c>): what the tray icon paints for.</summary>
    public ThemeBucket CurrentTrayBucket => CurrentBuckets.Tray;

    /// <summary>The app-window bucket (<c>AppsUseLightTheme</c>): what the flyout themes for.</summary>
    public ThemeBucket CurrentAppBucket => CurrentBuckets.App;

    /// <summary>
    /// Compat alias for <see cref="CurrentAppBucket"/>. Callers that paint the TRAY must use
    /// <see cref="CurrentTrayBucket"/> instead; the two differ on a stock Windows 10 box.
    /// </summary>
    public ThemeBucket CurrentBucket => CurrentAppBucket;

    /// <summary>
    /// Raised exactly once per real flip of EITHER bucket with the new pair. Not raised on
    /// construction; subscribe, then call <see cref="Start"/> -- the initial pair is available
    /// synchronously via <see cref="CurrentBuckets"/>.
    /// </summary>
    public event EventHandler<ThemeBuckets>? BucketsChanged;

    /// <summary>
    /// Compat event: raised exactly once per real flip of the APP bucket with the new app bucket. A
    /// tray-only flip does not raise it; subscribe to <see cref="BucketsChanged"/> to see both halves.
    /// </summary>
    public event EventHandler<ThemeBucket>? BucketChanged;

    /// <summary>
    /// Production constructor: reads the registry and debounces re-reads onto the supplied
    /// scheduler (typically a WPF <c>DispatcherTimer</c> wrapper) with a default coalescing window.
    /// </summary>
    /// <param name="scheduleDebounced">
    /// Schedules the coalesced re-read after the debounce window, on the UI thread. The watcher
    /// passes a single callback; multiple <see cref="OnUserPreferenceChanged"/> fires within one
    /// window must collapse to one invocation (the implementation guards re-entrancy itself, so a
    /// trivial scheduler that runs immediately is also correct, just un-debounced).
    /// </param>
    public ThemeWatcher(Action<Action> scheduleDebounced)
        : this(ReadBucketsFromRegistry, scheduleDebounced)
    {
    }

    /// <summary>
    /// Testable constructor: injects the two-bucket reader and the debounce scheduler so the
    /// filter/debounce/dedup pipeline can be exercised deterministically.
    /// </summary>
    public ThemeWatcher(Func<ThemeBuckets> readBuckets, Action<Action> scheduleDebounced)
    {
        _readBuckets = readBuckets ?? throw new ArgumentNullException(nameof(readBuckets));
        _scheduleDebounced = scheduleDebounced ?? throw new ArgumentNullException(nameof(scheduleDebounced));
        CurrentBuckets = _readBuckets();
    }

    /// <summary>
    /// Compat testable constructor: a single-bucket reader is lifted into both halves (tray == app),
    /// so tests written against the one-bucket watcher keep their read counts and raise counts.
    /// </summary>
    public ThemeWatcher(Func<ThemeBucket> readBucket, Action<Action> scheduleDebounced)
        : this(LiftSingleBucket(readBucket ?? throw new ArgumentNullException(nameof(readBucket))), scheduleDebounced)
    {
    }

    private static Func<ThemeBuckets> LiftSingleBucket(Func<ThemeBucket> readBucket) =>
        () =>
        {
            ThemeBucket bucket = readBucket();
            return new ThemeBuckets(bucket, bucket);
        };

    /// <summary>
    /// Begin listening for <see cref="SystemEvents.UserPreferenceChanged"/>. Idempotent. The
    /// initial pair was captured at construction and is in <see cref="CurrentBuckets"/>; no event
    /// fires for it.
    /// </summary>
    public void Start()
    {
        lock (_gate)
        {
            if (_started || _disposed)
            {
                return;
            }
            SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
            _started = true;
        }
    }

    /// <summary>
    /// Handle a <see cref="SystemEvents.UserPreferenceChanged"/> fire. Internal so tests can drive
    /// it directly with a synthetic <see cref="UserPreferenceChangedEventArgs"/>. The
    /// <c>Category == General</c> filter is the first gate: any other category returns before a
    /// re-read is even scheduled, so unrelated broadcasts (Color, Locale, Mouse, Window, etc.)
    /// cannot churn the renderer.
    /// </summary>
    public void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category != UserPreferenceCategory.General)
        {
            return;
        }

        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            // Coalesce a burst: only the first General fire in a window schedules the re-read.
            if (_pending)
            {
                return;
            }
            _pending = true;
        }

        _scheduleDebounced(ReevaluateBucket);
    }

    /// <summary>
    /// Re-read both buckets and raise <see cref="BucketsChanged"/> only when either half really
    /// flipped (and the compat <see cref="BucketChanged"/> only when the app half did). Runs after
    /// the debounce window. Public so tests that use an immediate scheduler can also assert the
    /// post-debounce behavior directly.
    /// </summary>
    public void ReevaluateBucket()
    {
        ThemeBuckets newBuckets;
        bool appChanged;
        lock (_gate)
        {
            _pending = false;
            if (_disposed)
            {
                return;
            }
            newBuckets = _readBuckets();
            if (newBuckets == CurrentBuckets)
            {
                return; // Same pair after coalescing: a no-op, no render.
            }
            appChanged = newBuckets.App != CurrentBuckets.App;
            CurrentBuckets = newBuckets;
        }

        BucketsChanged?.Invoke(this, newBuckets);
        if (appChanged)
        {
            BucketChanged?.Invoke(this, newBuckets.App);
        }
    }

    /// <summary>
    /// Pure mapping for the taskbar value <c>SystemUsesLightTheme</c>: 0 = dark, any other int =
    /// light, missing or non-int = DARK. A taskbar with no value is pre-1903 Windows 10, whose
    /// taskbar is always dark; defaulting to light there paints a black icon on a black taskbar.
    /// </summary>
    internal static ThemeBucket TrayBucketFrom(object? value) =>
        value is int light && light != 0 ? ThemeBucket.Light : ThemeBucket.Dark;

    /// <summary>
    /// Pure mapping for the app-window value <c>AppsUseLightTheme</c>: 0 = dark, any other int =
    /// light, missing or non-int = LIGHT (the OS default for app windows when unset).
    /// </summary>
    internal static ThemeBucket AppBucketFrom(object? value) =>
        value is int light && light == 0 ? ThemeBucket.Dark : ThemeBucket.Light;

    private static ThemeBuckets ReadBucketsFromRegistry()
    {
        object? systemValue = null;
        object? appsValue = null;
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(PersonalizeKeyPath);
            systemValue = key?.GetValue(SystemUsesLightThemeValue);
            appsValue = key?.GetValue(AppsUseLightThemeValue);
        }
        catch
        {
            // A locked/absent key falls through to the per-value defaults (tray dark, app light)
            // rather than throwing.
        }
        return new ThemeBuckets(TrayBucketFrom(systemValue), AppBucketFrom(appsValue));
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            if (_started)
            {
                SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
                _started = false;
            }
        }
    }
}
