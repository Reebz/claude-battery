using ClaudeBatteryWin.Icons;
using ClaudeBatteryWin.Services;
using Microsoft.Win32;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U9 ThemeWatcher tests: the <c>Category == General</c> filter, the bucket-collapsing dedup, and
/// burst debouncing -- the Windows analog of the Mac issue-#11 appearance-KVO guard. The injectable
/// reader and scheduler let the filter/debounce/dedup pipeline be driven deterministically without
/// the real registry or a Win32 message pump.
/// </summary>
public class ThemeWatcherTests
{
    /// <summary>An immediate scheduler: runs the coalesced re-read synchronously (no real delay).</summary>
    private static readonly Action<Action> RunImmediately = static action => action();

    private static UserPreferenceChangedEventArgs Args(UserPreferenceCategory category) => new(category);

    [Fact]
    public void NonThemeBroadcast_DoesNotReRead_OrRaiseEvent()
    {
        int reads = 0;
        ThemeBucket Reader()
        {
            reads++;
            return ThemeBucket.Light;
        }

        var watcher = new ThemeWatcher(Reader, RunImmediately);
        int initialReads = reads; // one read at construction
        int raised = 0;
        watcher.BucketChanged += (_, _) => raised++;

        // Non-General categories must be dropped before any re-read is even scheduled.
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.Color));
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.Locale));
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.Mouse));
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.Window));

        Assert.Equal(initialReads, reads); // no extra reads
        Assert.Equal(0, raised);           // no event
    }

    [Fact]
    public void RealLightToDarkSwitch_RaisesExactlyOnce()
    {
        ThemeBucket current = ThemeBucket.Light;
        var watcher = new ThemeWatcher(() => current, RunImmediately);
        Assert.Equal(ThemeBucket.Light, watcher.CurrentBucket);

        int raised = 0;
        ThemeBucket? lastValue = null;
        watcher.BucketChanged += (_, b) => { raised++; lastValue = b; };

        current = ThemeBucket.Dark; // OS flipped to dark
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.General));

        Assert.Equal(1, raised);
        Assert.Equal(ThemeBucket.Dark, lastValue);
        Assert.Equal(ThemeBucket.Dark, watcher.CurrentBucket);
    }

    [Fact]
    public void RealDarkToLightSwitch_RaisesExactlyOnce()
    {
        ThemeBucket current = ThemeBucket.Dark;
        var watcher = new ThemeWatcher(() => current, RunImmediately);

        int raised = 0;
        watcher.BucketChanged += (_, _) => raised++;

        current = ThemeBucket.Light;
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.General));

        Assert.Equal(1, raised);
        Assert.Equal(ThemeBucket.Light, watcher.CurrentBucket);
    }

    [Fact]
    public void GeneralFireWithSameBucket_DoesNotRaise()
    {
        ThemeBucket current = ThemeBucket.Dark;
        var watcher = new ThemeWatcher(() => current, RunImmediately);

        int raised = 0;
        watcher.BucketChanged += (_, _) => raised++;

        // A General broadcast that does not change the bucket (e.g. an unrelated personalization
        // tweak) re-reads but lands on the same bucket -> suppressed, no render churn.
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.General));

        Assert.Equal(0, raised);
        Assert.Equal(ThemeBucket.Dark, watcher.CurrentBucket);
    }

    [Fact]
    public void RepeatedGeneralFiresAcrossOneFlip_RaiseOnlyOnce()
    {
        ThemeBucket current = ThemeBucket.Light;
        var watcher = new ThemeWatcher(() => current, RunImmediately);

        int raised = 0;
        watcher.BucketChanged += (_, _) => raised++;

        current = ThemeBucket.Dark;
        // The OS often emits several General fires for one theme swap; each re-reads but only the
        // first that observes the flip raises, the rest collapse onto the same bucket.
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.General));
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.General));
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.General));

        Assert.Equal(1, raised);
    }

    [Fact]
    public void BurstOfGeneralFires_BeforeDebounceElapses_CollapsesToOneReRead()
    {
        // Capture the scheduled callback instead of running it, simulating an un-elapsed debounce
        // window: a burst of General fires must schedule exactly one coalesced re-read.
        var scheduled = new List<Action>();
        Action<Action> capture = scheduled.Add;

        int reads = 0;
        ThemeBucket current = ThemeBucket.Light;
        ThemeBucket Reader()
        {
            reads++;
            return current;
        }

        var watcher = new ThemeWatcher(Reader, capture);
        int constructionReads = reads;

        int raised = 0;
        watcher.BucketChanged += (_, _) => raised++;

        current = ThemeBucket.Dark;
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.General));
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.General));
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.General));

        // Only one re-read was scheduled despite three fires; none has run yet.
        Assert.Single(scheduled);
        Assert.Equal(constructionReads, reads); // no re-read yet (debounce window not elapsed)
        Assert.Equal(0, raised);

        // Fire the debounce: one re-read, one raise.
        scheduled[0]();
        Assert.Equal(constructionReads + 1, reads);
        Assert.Equal(1, raised);
        Assert.Equal(ThemeBucket.Dark, watcher.CurrentBucket);

        // After the window closes, a subsequent burst schedules a fresh re-read.
        scheduled.Clear();
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.General));
        Assert.Single(scheduled);
    }

    [Fact]
    public void DisposeUnsubscribes_NoRaiseAfterDispose()
    {
        ThemeBucket current = ThemeBucket.Light;
        var watcher = new ThemeWatcher(() => current, RunImmediately);

        int raised = 0;
        watcher.BucketChanged += (_, _) => raised++;

        watcher.Dispose();
        current = ThemeBucket.Dark;
        // A late fire after dispose must be inert.
        watcher.OnUserPreferenceChanged(null, Args(UserPreferenceCategory.General));

        Assert.Equal(0, raised);
    }

    [Fact]
    public void CurrentBucket_ReflectsInitialReadAtConstruction()
    {
        var dark = new ThemeWatcher(() => ThemeBucket.Dark, RunImmediately);
        var light = new ThemeWatcher(() => ThemeBucket.Light, RunImmediately);

        Assert.Equal(ThemeBucket.Dark, dark.CurrentBucket);
        Assert.Equal(ThemeBucket.Light, light.CurrentBucket);
    }
}
