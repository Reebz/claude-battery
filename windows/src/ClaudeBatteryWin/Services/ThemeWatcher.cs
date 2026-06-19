using ClaudeBatteryWin.Icons;
using Microsoft.Win32;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// Watches the system light/dark setting and raises <see cref="BucketChanged"/> only on a real
/// flip, so the tray renderer (U9) re-renders exactly once per theme switch and never churns on
/// unrelated system broadcasts. This is the explicit Windows analog of the Mac issue-#11
/// <c>effectiveAppearance</c> KVO loop fix in MenuBarController:
///
/// <list type="bullet">
/// <item><description>Source of truth is the registry value
/// <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme</c>
/// (0 = dark, non-zero / missing = light), collapsed to a <see cref="ThemeBucket"/>.</description></item>
/// <item><description>Reacts to <see cref="SystemEvents.UserPreferenceChanged"/> FILTERED to
/// <c>Category == General</c> -- the analog of <c>shouldReactToAppearanceChange</c> dropping
/// non-brightness fires. <c>General</c> is the category that carries theme/personalization
/// changes; <c>Color</c>, <c>Locale</c>, <c>Mouse</c>, etc. are ignored before any registry
/// read.</description></item>
/// <item><description>Debounced: General can fire several times in a burst during a theme swap, so
/// a short coalescing window collapses the burst into one re-read.</description></item>
/// <item><description>Bucket-collapsing dedup: after re-reading, the event is raised only when the
/// bucket actually changed from the last raised value, so a re-read that lands on the same bucket
/// is suppressed (mirrors the Mac <c>oldDark != newDark</c> guard).</description></item>
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

    private readonly Func<ThemeBucket> _readBucket;
    private readonly Action<Action> _scheduleDebounced;
    private readonly object _gate = new();

    private bool _started;
    private bool _disposed;
    private bool _pending;

    /// <summary>The last bucket actually surfaced through <see cref="BucketChanged"/>.</summary>
    public ThemeBucket CurrentBucket { get; private set; }

    /// <summary>
    /// Raised exactly once per real light/dark flip with the new bucket. Not raised on
    /// construction; subscribe, then call <see cref="Start"/> -- the initial bucket is available
    /// synchronously via <see cref="CurrentBucket"/>.
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
        : this(ReadBucketFromRegistry, scheduleDebounced)
    {
    }

    /// <summary>
    /// Testable constructor: injects the bucket reader and the debounce scheduler so the
    /// filter/debounce/dedup pipeline can be exercised deterministically.
    /// </summary>
    public ThemeWatcher(Func<ThemeBucket> readBucket, Action<Action> scheduleDebounced)
    {
        _readBucket = readBucket ?? throw new ArgumentNullException(nameof(readBucket));
        _scheduleDebounced = scheduleDebounced ?? throw new ArgumentNullException(nameof(scheduleDebounced));
        CurrentBucket = _readBucket();
    }

    /// <summary>
    /// Begin listening for <see cref="SystemEvents.UserPreferenceChanged"/>. Idempotent. The
    /// initial bucket was captured at construction and is in <see cref="CurrentBucket"/>; no event
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
    /// Re-read the bucket and raise <see cref="BucketChanged"/> only on a real flip. Runs after the
    /// debounce window. Public so tests that use an immediate scheduler can also assert the
    /// post-debounce behavior directly.
    /// </summary>
    public void ReevaluateBucket()
    {
        ThemeBucket newBucket;
        lock (_gate)
        {
            _pending = false;
            if (_disposed)
            {
                return;
            }
            newBucket = _readBucket();
            if (newBucket == CurrentBucket)
            {
                return; // Same bucket after coalescing: a no-op, no render.
            }
            CurrentBucket = newBucket;
        }

        BucketChanged?.Invoke(this, newBucket);
    }

    private static ThemeBucket ReadBucketFromRegistry()
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(PersonalizeKeyPath);
            object? value = key?.GetValue(AppsUseLightThemeValue);
            // 0 = dark; non-zero or missing key/value = light (the OS default when unset).
            if (value is int light)
            {
                return light == 0 ? ThemeBucket.Dark : ThemeBucket.Light;
            }
        }
        catch
        {
            // A locked/absent key is treated as the light default rather than throwing.
        }
        return ThemeBucket.Light;
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
