using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U11 notification tests: the notify-dedup latch and the Windows delivery-order fix.
///
/// Covers the plan's scenarios: crossing below threshold fires exactly one toast; staying below
/// does not re-fire; climbing back resets the dedup latch; a toast suppressed at the OS level does
/// NOT latch the flag (so it fires once delivery is possible); and the pure
/// <see cref="Notifier.Decide"/> rule including notifications-off-by-default.
///
/// The dedup latch and delivery sink are faked so the whole flow runs without WinRT. The fake latch
/// mirrors AccountStore.UpdateDidNotify; because <see cref="Account"/> is immutable, each successive
/// poll is modeled by reading the latch's recorded state and building the next Account with that
/// <see cref="Account.DidNotifyBelowThreshold"/>, exactly as the AccountStore would persist it.
/// </summary>
public sealed class NotifierTests
{
    private sealed class FakeLatch : INotifyLatch
    {
        public readonly Dictionary<Guid, bool> State = new();
        public int Sets;

        public void SetDidNotify(Guid accountId, bool value)
        {
            State[accountId] = value;
            Sets++;
        }

        public bool Get(Guid id) => State.TryGetValue(id, out var v) && v;
    }

    private sealed class FakeToastSink : IToastSink
    {
        public bool Deliverable = true;   // flip to simulate OS-level suppression
        public int ShowAttempts;
        public int Delivered;

        public bool TryShow(string title, string body, Guid tag)
        {
            ShowAttempts++;
            if (Deliverable)
            {
                Delivered++;
                return true;
            }
            return false;
        }
    }

    private static Account NewAccount(double threshold = 20.0, bool didNotify = false) => new()
    {
        Email = "user@example.com",
        SessionKey = "sk",
        OrganizationId = "org-1",
        NotificationThreshold = threshold,
        DidNotifyBelowThreshold = didNotify,
    };

    // ---- pure Decide rule ----

    [Fact]
    public void Decide_NotificationsDisabled_IsNone_RegardlessOfRemaining()
    {
        Assert.Equal(Notifier.NotifyAction.None, Notifier.Decide(false, 5, 20, alreadyNotified: false));
        Assert.Equal(Notifier.NotifyAction.None, Notifier.Decide(false, 90, 20, alreadyNotified: true));
    }

    [Fact]
    public void Decide_BelowThreshold_NotYetNotified_IsFire()
    {
        Assert.Equal(Notifier.NotifyAction.Fire, Notifier.Decide(true, 19.9, 20, alreadyNotified: false));
    }

    [Fact]
    public void Decide_BelowThreshold_AlreadyNotified_IsNone()
    {
        Assert.Equal(Notifier.NotifyAction.None, Notifier.Decide(true, 5, 20, alreadyNotified: true));
    }

    [Fact]
    public void Decide_AtOrAboveThreshold_IsResetLatch()
    {
        // The Mac uses `remaining >= threshold` for the reset arm: exactly-at-threshold resets.
        Assert.Equal(Notifier.NotifyAction.ResetLatch, Notifier.Decide(true, 20, 20, alreadyNotified: true));
        Assert.Equal(Notifier.NotifyAction.ResetLatch, Notifier.Decide(true, 80, 20, alreadyNotified: false));
    }

    // ---- crossing below fires exactly one toast ----

    [Fact]
    public void CrossingBelowThreshold_FiresExactlyOneToast()
    {
        var latch = new FakeLatch();
        var sink = new FakeToastSink();
        var notifier = new Notifier(() => true, latch, sink);
        var account = NewAccount(threshold: 20);

        var delivered = notifier.Evaluate(account, weeklyRemaining: 15);

        Assert.True(delivered);
        Assert.Equal(1, sink.Delivered);
        Assert.True(latch.Get(account.Id)); // latch set on confirmed delivery
    }

    [Fact]
    public void StayingBelowThreshold_DoesNotReFire()
    {
        var latch = new FakeLatch();
        var sink = new FakeToastSink();
        var notifier = new Notifier(() => true, latch, sink);
        var account = NewAccount(threshold: 20);

        // First poll below: fires and latches.
        notifier.Evaluate(account, 15);
        Assert.Equal(1, sink.Delivered);

        // Next poll, still below: model the persisted latch by rebuilding the account from it.
        var stillBelow = account with { DidNotifyBelowThreshold = latch.Get(account.Id) };
        notifier.Evaluate(stillBelow, 12);
        notifier.Evaluate(stillBelow, 8);

        Assert.Equal(1, sink.Delivered); // never re-fired while continuously below
    }

    [Fact]
    public void ClimbingBackToOrAboveThreshold_ResetsTheLatch()
    {
        var latch = new FakeLatch();
        var sink = new FakeToastSink();
        var notifier = new Notifier(() => true, latch, sink);
        var account = NewAccount(threshold: 20);

        notifier.Evaluate(account, 15);                 // fire + latch
        Assert.True(latch.Get(account.Id));

        var latched = account with { DidNotifyBelowThreshold = true };
        notifier.Evaluate(latched, 55);                 // climbs back: reset latch
        Assert.False(latch.Get(account.Id));

        // Dropping below again after the reset must fire a fresh toast.
        var reset = account with { DidNotifyBelowThreshold = latch.Get(account.Id) };
        var redelivered = notifier.Evaluate(reset, 10);
        Assert.True(redelivered);
        Assert.Equal(2, sink.Delivered);
    }

    // ---- OS-suppressed toast does NOT latch (the delivery-order fix) ----

    [Fact]
    public void OsSuppressedToast_DoesNotLatch_FiresOnceDeliveryIsPossible()
    {
        var latch = new FakeLatch();
        var sink = new FakeToastSink { Deliverable = false }; // Focus Assist / missing AUMID
        var notifier = new Notifier(() => true, latch, sink);
        var account = NewAccount(threshold: 20);

        // Below threshold, but the OS drops the toast: an attempt was made, nothing delivered,
        // and CRITICALLY the latch is NOT set (otherwise the user is permanently suppressed).
        var delivered = notifier.Evaluate(account, 15);
        Assert.False(delivered);
        Assert.Equal(1, sink.ShowAttempts);
        Assert.Equal(0, sink.Delivered);
        Assert.False(latch.Get(account.Id)); // latch left clear

        // Delivery becomes possible (Focus Assist off / AUMID registered). The account is still
        // un-latched (we never set it), still below threshold: the next poll fires once.
        sink.Deliverable = true;
        var stillUnlatched = account with { DidNotifyBelowThreshold = latch.Get(account.Id) };
        var redelivered = notifier.Evaluate(stillUnlatched, 14);

        Assert.True(redelivered);
        Assert.Equal(1, sink.Delivered);
        Assert.True(latch.Get(account.Id)); // now latched, exactly once delivery succeeded
    }

    // ---- session-window rollover bounds Focus-Assist suppression (U13/#14) ----

    [Fact]
    public void SessionWindowRollover_ResetsLatch_SoAnAcceptedButUnshownToastRetries()
    {
        var latch = new FakeLatch();
        // The OS ACCEPTS the toast (Deliverable = true) but Focus Assist may have only queued it.
        var sink = new FakeToastSink { Deliverable = true };
        var notifier = new Notifier(() => true, latch, sink);
        var account = NewAccount(threshold: 20);

        var t1 = new DateTimeOffset(2026, 6, 19, 12, 0, 0, TimeSpan.Zero);
        var t2 = t1.AddHours(5); // the session window rolls over

        // First below-threshold reading: fires + latches against session window t1.
        Assert.True(notifier.Evaluate(account, weeklyRemaining: 10, sessionResetDate: t1));
        Assert.Equal(1, sink.Delivered);
        Assert.True(latch.Get(account.Id));

        // Same session window, still below, already latched: no re-fire (intra-session dedup holds).
        var latched = account with { DidNotifyBelowThreshold = true };
        Assert.False(notifier.Evaluate(latched, weeklyRemaining: 10, sessionResetDate: t1));
        Assert.Equal(1, sink.Delivered);

        // Session window rolled over (t2): the latch is reset, so a still-below reading re-attempts -
        // the unshown toast is not suppressed for the full week.
        Assert.True(notifier.Evaluate(latched, weeklyRemaining: 10, sessionResetDate: t2));
        Assert.Equal(2, sink.Delivered);
    }

    [Fact]
    public void SessionResetUnchanged_DoesNotResetLatch()
    {
        var latch = new FakeLatch();
        var sink = new FakeToastSink { Deliverable = true };
        var notifier = new Notifier(() => true, latch, sink);
        var account = NewAccount(threshold: 20);
        var t1 = new DateTimeOffset(2026, 6, 19, 12, 0, 0, TimeSpan.Zero);

        notifier.Evaluate(account, 10, t1); // fire + latch
        var latched = account with { DidNotifyBelowThreshold = true };

        // Repeated polls inside the SAME window do not re-fire (no spurious latch reset).
        Assert.False(notifier.Evaluate(latched, 9, t1));
        Assert.False(notifier.Evaluate(latched, 8, t1));
        Assert.Equal(1, sink.Delivered);
    }

    // ---- notifications off by default ----

    [Fact]
    public void NotificationsOff_NoToast_NoLatchMutation()
    {
        var latch = new FakeLatch();
        var sink = new FakeToastSink();
        // Default is off: the global flag returns false.
        var notifier = new Notifier(() => false, latch, sink);
        var account = NewAccount(threshold: 20);

        var delivered = notifier.Evaluate(account, 5); // far below threshold

        Assert.False(delivered);
        Assert.Equal(0, sink.ShowAttempts);
        Assert.Equal(0, latch.Sets); // no latch read or write while disabled
    }

    [Fact]
    public void AppSettings_NotificationsAndCountdown_DefaultOff()
    {
        // The master switch the Notifier gates on, and the countdown toggle, both default off
        // (Mac UserDefaults defaults). Verified at the settings layer so the Notifier's "() => flag"
        // wiring starts disabled.
        using var temp = new TempSettings();
        var settings = new AppSettings(temp.Path);

        Assert.False(settings.NotificationsEnabled);
        Assert.False(settings.ShowSessionCountdown);
    }

    [Fact]
    public void AppSettings_PersistsAcrossInstances_AndRaisesChanged()
    {
        using var temp = new TempSettings();
        var settings = new AppSettings(temp.Path);
        var changes = 0;
        settings.Changed += (_, _) => changes++;

        settings.NotificationsEnabled = true;
        settings.ShowSessionCountdown = true;
        Assert.Equal(2, changes);

        // Setting to the same value is a no-op (no extra Changed, no rewrite churn).
        settings.NotificationsEnabled = true;
        Assert.Equal(2, changes);

        var reloaded = new AppSettings(temp.Path);
        Assert.True(reloaded.NotificationsEnabled);
        Assert.True(reloaded.ShowSessionCountdown);
    }

    private sealed class TempSettings : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(), "cbw-settings-tests", Guid.NewGuid().ToString("N"), "settings.json");

        public void Dispose()
        {
            try
            {
                var dir = System.IO.Path.GetDirectoryName(Path);
                if (dir is not null && System.IO.Directory.Exists(dir))
                {
                    System.IO.Directory.Delete(dir, recursive: true);
                }
            }
            catch (System.IO.IOException)
            {
            }
        }
    }
}
