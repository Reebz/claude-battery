using System.Diagnostics;
using ClaudeBatteryWin.Models;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// Low-usage Windows toast notifications and the notify-dedup latch (U11, R19). The Windows port
/// of the Mac <c>UsageService.checkAndNotify</c> + <c>scheduleNotification</c>
/// (Services/UsageService.swift), with one deliberate correctness fix called out below.
///
/// Parity with the Mac:
/// <list type="bullet">
///   <item>Fires on WEEKLY remaining only (the Mac calls <c>checkAndNotify</c> only with
///   <c>weeklyRemaining</c>).</item>
///   <item>Gated globally by the notifications-enabled flag (the Mac
///   <c>UserDefaults.standard.bool(forKey: "notificationsEnabled")</c>); off by default.</item>
///   <item>Per-account threshold (default 20, the UI exposes 5-50 step 5).</item>
///   <item>One toast on crossing below threshold; reset the dedup latch when remaining climbs back
///   to/above the threshold (the Mac <c>remaining &gt;= threshold</c> arm clears
///   <c>didNotifyBelowThreshold</c>).</item>
/// </list>
///
/// <para>
/// <b>The Windows delivery-order fix.</b> The Mac sets <c>didNotifyBelowThreshold = true</c>
/// <i>before</i> scheduling the notification. On macOS the OS notification center reliably accepts
/// the request, so setting-before-delivery is harmless. On Windows a toast can be silently dropped
/// at the OS level - a missing/unregistered AUMID, or Focus Assist / Do-Not-Disturb suppressing it.
/// If we latched the flag before delivery and the toast was dropped, the latch would never clear
/// (remaining is still below threshold) and the user would be PERMANENTLY suppressed: they never
/// saw the alert and will never get another until remaining climbs back up. So the latch is set
/// ONLY on confirmed delivery (<see cref="IToastSink.TryShow"/> returning true). A suppressed toast
/// leaves the latch clear, so the next poll that is still below threshold tries again - exactly once
/// delivery becomes possible. (Mac feedback: "toast suppressed at the OS level does NOT latch the
/// flag.")
/// </para>
///
/// <para>
/// The decision logic (<see cref="Decide"/>) is a pure function over (enabled, remaining, threshold,
/// already-notified) so it unit-tests without WinRT. The latch mutation is delegated to an
/// <see cref="INotifyLatch"/> (the AccountStore in production) and toast delivery to an
/// <see cref="IToastSink"/> (the WinRT sink in production), so the whole flow is testable with a
/// fake sink that can simulate OS-level suppression.
/// </para>
/// </summary>
public sealed class Notifier
{
    /// The global "low usage notifications" flag (Mac UserDefaults "notificationsEnabled"; default
    /// off). Read live each poll so toggling it in Settings takes effect without a restart.
    private readonly Func<bool> _notificationsEnabled;
    private readonly INotifyLatch _latch;
    private readonly IToastSink _toastSink;

    public Notifier(Func<bool> notificationsEnabled, INotifyLatch latch, IToastSink toastSink)
    {
        _notificationsEnabled = notificationsEnabled ?? throw new ArgumentNullException(nameof(notificationsEnabled));
        _latch = latch ?? throw new ArgumentNullException(nameof(latch));
        _toastSink = toastSink ?? throw new ArgumentNullException(nameof(toastSink));
    }

    /// <summary>
    /// The action a single weekly-remaining reading implies, given the global enable flag and the
    /// account's threshold + current latch. Pure: no side effects, so the crossing/dedup/reset
    /// matrix is unit-testable without a real toast sink or account store. Mirrors the Mac
    /// <c>checkAndNotify</c> branch structure exactly.
    /// </summary>
    public enum NotifyAction
    {
        /// Below threshold and not yet notified: attempt to deliver a toast (and latch on success).
        Fire,

        /// At/above threshold: clear the latch so a future drop can fire again.
        ResetLatch,

        /// Notifications disabled, or below-and-already-notified, or in the dead band
        /// (below threshold but already notified): do nothing.
        None,
    }

    /// <summary>
    /// Decide the action for a weekly-remaining reading. Mirrors the Mac:
    /// <code>
    /// if remaining &lt; threshold &amp;&amp; !didNotify  -> notify (and set latch)
    /// else if remaining &gt;= threshold                 -> clear latch
    /// </code>
    /// with the global enable flag gating everything (the Mac's leading
    /// <c>guard notificationsEnabled else { return }</c>).
    /// </summary>
    public static NotifyAction Decide(bool notificationsEnabled, double remaining, double threshold, bool alreadyNotified)
    {
        if (!notificationsEnabled)
        {
            return NotifyAction.None;
        }

        if (remaining < threshold)
        {
            return alreadyNotified ? NotifyAction.None : NotifyAction.Fire;
        }

        // remaining >= threshold
        return NotifyAction.ResetLatch;
    }

    /// <summary>
    /// Evaluate one weekly-remaining reading for an account and apply the side effects:
    /// on <see cref="NotifyAction.Fire"/>, attempt delivery via the toast sink and latch the
    /// account's dedup flag ONLY if delivery is confirmed; on <see cref="NotifyAction.ResetLatch"/>,
    /// clear the latch. Returns whether a toast was actually delivered (true only on a confirmed
    /// fire, so a suppressed toast returns false and leaves the latch clear).
    ///
    /// Call this from the poll-success path with the resolved weekly-remaining percentage (the Mac
    /// calls <c>checkAndNotify(account:remaining:)</c> with <c>weeklyRemaining</c>, never the
    /// session value).
    /// </summary>
    public bool Evaluate(Account account, double weeklyRemaining)
    {
        ArgumentNullException.ThrowIfNull(account);

        var action = Decide(
            _notificationsEnabled(),
            weeklyRemaining,
            account.NotificationThreshold,
            account.DidNotifyBelowThreshold);

        switch (action)
        {
            case NotifyAction.Fire:
            {
                // Deliver FIRST; latch only on confirmed delivery (the Windows delivery-order fix).
                // A dropped toast (no AUMID / Focus Assist) returns false and leaves the latch clear,
                // so the next still-below poll re-attempts once delivery is possible.
                var delivered = _toastSink.TryShow(
                    title: $"Claude Usage Low - {account.DisplayName}",
                    body: FormatBody(weeklyRemaining),
                    tag: account.Id);
                if (delivered)
                {
                    _latch.SetDidNotify(account.Id, true);
                }
                DebugLog(delivered
                    ? "Weekly-low toast delivered; latch set"
                    : "Weekly-low toast suppressed at OS level; latch left clear (will retry)");
                return delivered;
            }

            case NotifyAction.ResetLatch:
                if (account.DidNotifyBelowThreshold)
                {
                    _latch.SetDidNotify(account.Id, false);
                    DebugLog("Weekly remaining back at/above threshold; dedup latch reset");
                }
                return false;

            default:
                return false;
        }
    }

    /// Notification body, matching the Mac <c>String(format: "Weekly quota is at %.0f%% remaining.")</c>.
    private static string FormatBody(double remaining)
        => $"Weekly quota is at {remaining:0}% remaining.";

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[Notifier] {message}");
}

/// <summary>
/// The dedup-latch mutation seam. In production this is the <c>AccountStore</c> (its
/// <c>UpdateDidNotify</c> matches this signature); tests supply a fake that records the latch state
/// so the set-on-delivery / reset-on-recovery behavior is asserted in isolation.
/// </summary>
public interface INotifyLatch
{
    /// Set the account's <c>DidNotifyBelowThreshold</c> latch (mirrors AccountStore.UpdateDidNotify).
    void SetDidNotify(Guid accountId, bool value);
}

/// <summary>
/// Toast delivery seam. The production implementation is <see cref="WinRtToastSink"/> (WinRT
/// <c>ToastNotificationManager</c> behind an AUMID-bearing Start-menu shortcut); tests supply a fake
/// that can report delivery success OR simulate OS-level suppression (return false), which is the
/// scenario the delivery-order fix guards.
///
/// <see cref="TryShow"/> returns <c>true</c> only when the toast was handed to the OS without the
/// notifier being able to detect an immediate failure. It must return <c>false</c> when delivery is
/// impossible (no registered AUMID) or rejected (notifications disabled at the OS / Focus Assist
/// that the API surfaces synchronously), so the dedup latch is not set for a toast the user never
/// saw.
/// </summary>
public interface IToastSink
{
    /// <summary>
    /// Show a toast. Returns true only on confirmed hand-off to the OS notification platform.
    /// </summary>
    /// <param name="title">The toast title line.</param>
    /// <param name="body">The toast body line.</param>
    /// <param name="tag">An identity for the toast (the account id), so repeated alerts for the
    /// same account replace rather than stack.</param>
    bool TryShow(string title, string body, Guid tag);
}

#if WINDOWS10_0_19041_0_OR_GREATER
/// <summary>
/// Production <see cref="IToastSink"/> over WinRT <c>ToastNotificationManager</c>. Requires the
/// Windows-versioned TFM (<c>net8.0-windows10.0.19041.0</c>) so <c>Windows.UI.Notifications</c> is
/// reachable, and an AUMID registered through an installed Start-menu shortcut (the installer, U12,
/// creates the shortcut; <see cref="EnsureRegistered"/> sets the process AUMID at startup).
///
/// <para>
/// <b>Why <see cref="TryShow"/> can return false (the delivery-order fix's reason for existing).</b>
/// <c>CreateToastNotifier(aumid).Setting</c> reports whether toasts are actually deliverable:
/// <c>Enabled</c> means deliver; <c>DisabledForApplication</c> / <c>DisabledForUser</c> /
/// <c>DisabledByGroupPolicy</c> / <c>DisabledByManifest</c> mean a toast would be silently dropped
/// (Focus Assist / notifications-off / no manifest). In those cases we return false WITHOUT showing,
/// so the <see cref="Notifier"/> does not latch the dedup flag for a toast the user never sees. An
/// unregistered AUMID or any WinRT throw is likewise a false (not-delivered) result.
/// </para>
///
/// Not unit-tested (it touches the real WinRT platform); the <see cref="Notifier"/> logic is tested
/// against a fake <see cref="IToastSink"/>.
/// </summary>
public sealed class WinRtToastSink : IToastSink
{
    /// <summary>
    /// The Application User Model ID. Must EXACTLY match the AUMID stamped on the installed
    /// Start-menu shortcut (U12) or toasts are dropped. Stable across versions.
    /// </summary>
    public const string Aumid = "com.reebz.claudebatterywin";

    /// <summary>
    /// Register this process's AUMID so toasts resolve to the installed shortcut's identity. Call
    /// once at startup (after Velopack, before the first poll). Best-effort: a failure leaves the
    /// sink unable to deliver, and <see cref="TryShow"/> then returns false rather than throwing.
    /// </summary>
    public static void EnsureRegistered()
    {
        try
        {
            SetCurrentProcessExplicitAppUserModelID(Aumid);
        }
        catch
        {
            // A failed registration is non-fatal; TryShow will report not-delivered.
        }
    }

    public bool TryShow(string title, string body, Guid tag)
    {
        try
        {
            var notifier = Windows.UI.Notifications.ToastNotificationManager.CreateToastNotifier(Aumid);

            // Deliverability gate: do not show (and do not let the caller latch) when the OS would
            // drop the toast. Only NotificationSetting.Enabled means it will actually surface.
            if (notifier.Setting != Windows.UI.Notifications.NotificationSetting.Enabled)
            {
                DebugLog($"Toast suppressed by OS setting: {notifier.Setting}");
                return false;
            }

            var xml = Windows.UI.Notifications.ToastNotificationManager.GetTemplateContent(
                Windows.UI.Notifications.ToastTemplateType.ToastText02);
            var textNodes = xml.GetElementsByTagName("text");
            textNodes[0].AppendChild(xml.CreateTextNode(title));
            textNodes[1].AppendChild(xml.CreateTextNode(body));

            var toast = new Windows.UI.Notifications.ToastNotification(xml)
            {
                // Replace a prior alert for the same account instead of stacking.
                Tag = ToastTag(tag),
            };
            notifier.Show(toast);
            return true;
        }
        catch (Exception ex)
        {
            DebugLog($"Toast delivery threw, treating as not-delivered: {ex.GetType().Name}");
            return false;
        }
    }

    /// WinRT toast Tag is capped at 64 chars; the 32-char "N" GUID is well within that.
    private static string ToastTag(Guid id) => id.ToString("N");

    [System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError = true)]
    private static extern void SetCurrentProcessExplicitAppUserModelID(
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string appId);

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[WinRtToastSink] {message}");
}
#endif
