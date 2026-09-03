using System.Diagnostics;
using ClaudeBatteryWin.Models;
using Microsoft.Win32;

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
/// <b>The residual Focus-Assist gap and its backstop (U13/#14).</b> A toast the OS ACCEPTS
/// (<c>Setting == Enabled</c>) can still go unshown: Focus Assist "priority only" queues it to the
/// Action Center, and there is no reliable synchronous "was it shown" signal to gate on. So
/// <see cref="Evaluate"/> also resets the dedup latch whenever the SESSION window rolls over (a new
/// ~5h window), bounding worst-case suppression of an accepted-but-unshown toast to one session
/// window rather than the full weekly window.
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

    /// The session-window reset instant last seen per account, so a rollover (a new ~5h window) can
    /// reset the dedup latch (U13). Bounds worst-case suppression of an OS-accepted-but-unshown toast
    /// to one session window instead of a full weekly window.
    private readonly Dictionary<Guid, DateTimeOffset?> _lastSessionReset = new();

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
    public bool Evaluate(Account account, double weeklyRemaining, DateTimeOffset? sessionResetDate = null)
    {
        ArgumentNullException.ThrowIfNull(account);

        // A toast can be accepted by the OS (Setting==Enabled) yet never surfaced - Focus Assist
        // "priority only" queues it to the Action Center, and there is no reliable synchronous "was
        // shown" signal. If that toast latched the dedup flag, the user would be suppressed until the
        // next WEEKLY reset. Bound it: when the session window rolls over (a new ~5h window), clear
        // the latch so a still-below reading re-attempts delivery (U13/#14).
        var alreadyNotified = account.DidNotifyBelowThreshold;
        if (sessionResetDate is not null
            && _lastSessionReset.TryGetValue(account.Id, out var prior)
            && prior != sessionResetDate
            && alreadyNotified)
        {
            _latch.SetDidNotify(account.Id, false);
            alreadyNotified = false;
            DebugLog("Session window rolled over; dedup latch reset (bounds Focus-Assist suppression)");
        }
        if (sessionResetDate is not null)
        {
            _lastSessionReset[account.Id] = sessionResetDate;
        }

        var action = Decide(
            _notificationsEnabled(),
            weeklyRemaining,
            account.NotificationThreshold,
            alreadyNotified);

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
/// <c>ToastNotificationManager</c> behind an AUMID registered under the per-user
/// <c>HKCU\Software\Classes\AppUserModelId</c> key, see <see cref="AumidRegistration"/>); tests
/// supply a fake that can report delivery success OR simulate OS-level suppression (return false),
/// which is the scenario the delivery-order fix guards.
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

/// <summary>
/// The minimal registry surface the AUMID registration needs: write one named string value under
/// the app's <c>AppUserModelId</c> key. Injected so the values <see cref="AumidRegistration.Write"/>
/// stamps are unit-testable against a recording fake without touching the real <c>HKCU</c> hive.
/// Deliberately NOT <c>IRunKey</c>: that seam hard-codes the autostart Run key path. Production is
/// <see cref="HkcuAumidRegistration"/>.
/// </summary>
public interface IAumidRegistration
{
    /// Create or overwrite the value as a string (REG_SZ).
    void SetValue(string name, string value);
}

/// <summary>
/// The unpackaged-app toast registration. The shipped Windows build is a raw single-file exe: no
/// installer, no Start-menu shortcut, no package identity. WinRT <c>ToastNotificationManager</c>
/// drops every toast for an AUMID the shell has no record of, so
/// <c>SetCurrentProcessExplicitAppUserModelID</c> alone is not enough - the AUMID must also be
/// registered. The registry-only alternative to a shortcut is the per-user
/// <c>HKCU\Software\Classes\AppUserModelId\&lt;aumid&gt;</c> key, which is what Microsoft's own
/// unpackaged-app compat library (<c>ToastNotificationManagerCompat</c>) writes.
///
/// <para>
/// Only <c>DisplayName</c> (the name Windows shows in Settings &gt; Notifications and on the toast)
/// and <c>IconBackgroundColor</c> are written. <c>IconUri</c> is deliberately omitted: Windows
/// expects an image file there and no icon file ships with the exe (the compat library deletes the
/// value when it has none). <c>CustomActivator</c> is likewise omitted: it is only needed for
/// click-activation through a COM server, which this app does not have.
/// </para>
///
/// The key path and the written values are pure data, so they unit-test without WinRT or the
/// registry; the real HKCU write lives in <see cref="HkcuAumidRegistration"/>.
/// </summary>
public static class AumidRegistration
{
    /// <summary>
    /// The Application User Model ID. Must EXACTLY match the AUMID the process sets on itself
    /// (<c>SetCurrentProcessExplicitAppUserModelID</c>) and the registry subkey the registration
    /// is written under, or toasts are dropped. Stable across versions.
    /// </summary>
    public const string Aumid = "com.reebz.claudebatterywin";

    /// HKCU subkey path the AUMID is registered under. Per-user, so no elevation is needed.
    public const string KeyPath = @"Software\Classes\AppUserModelId\" + Aumid;

    /// The name Windows shows for this app's toasts (Settings &gt; System &gt; Notifications).
    public const string DisplayName = "Claude Battery";

    /// The toast icon backdrop, as ARGB hex. The same neutral light grey the compat library writes.
    public const string IconBackgroundColor = "FFDDDDDD";

    /// <summary>
    /// Stamp the registration values. Idempotent: every value is a plain overwrite, so calling it on
    /// every startup (and again when the Settings toggle turns notifications on) is safe.
    /// </summary>
    public static void Write(IAumidRegistration reg)
    {
        ArgumentNullException.ThrowIfNull(reg);
        reg.SetValue("DisplayName", DisplayName);
        reg.SetValue("IconBackgroundColor", IconBackgroundColor);
    }
}

/// <summary>
/// Production <see cref="IAumidRegistration"/> over the real
/// <c>HKEY_CURRENT_USER\Software\Classes\AppUserModelId\com.reebz.claudebatterywin</c> key. Opens
/// (creating if absent) the key per-operation, mirroring <c>HkcuRunKey</c>. Not unit-tested.
/// </summary>
public sealed class HkcuAumidRegistration : IAumidRegistration
{
    public void SetValue(string name, string value)
    {
        // CreateSubKey returns the existing key when present, so this both creates the AUMID key on
        // first run and opens it writable on every later run.
        using RegistryKey key = Registry.CurrentUser.CreateSubKey(AumidRegistration.KeyPath, writable: true)
            ?? throw new InvalidOperationException("Could not open the HKCU AppUserModelId key for writing.");
        key.SetValue(name, value, RegistryValueKind.String);
    }
}

#if WINDOWS10_0_19041_0_OR_GREATER
/// <summary>
/// Production <see cref="IToastSink"/> over WinRT <c>ToastNotificationManager</c>. Requires the
/// Windows-versioned TFM (<c>net8.0-windows10.0.19041.0</c>) so <c>Windows.UI.Notifications</c> is
/// reachable, and an AUMID registered under the per-user <c>HKCU\Software\Classes\AppUserModelId</c>
/// key (<see cref="EnsureRegistered"/> sets the process AUMID and writes that key at startup; the
/// shipped build is a raw exe with no installer or Start-menu shortcut to carry the AUMID).
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
    /// The Application User Model ID. Must EXACTLY match the registry subkey
    /// <see cref="AumidRegistration"/> writes (<see cref="AumidRegistration.KeyPath"/>) or toasts
    /// are dropped. Stable across versions.
    /// </summary>
    public const string Aumid = AumidRegistration.Aumid;

    /// <summary>
    /// Register this process's AUMID so toasts resolve to a shell-known identity: set the process
    /// AUMID, then write the per-user <c>AppUserModelId</c> registry key
    /// (<see cref="AumidRegistration.Write"/>). Call once at startup (after Velopack, before the
    /// first poll); idempotent, so the Settings toggle calls it again on enable. Best-effort: a
    /// failure leaves the sink unable to deliver, and <see cref="TryShow"/> then returns false
    /// rather than throwing.
    /// </summary>
    public static void EnsureRegistered()
    {
        try
        {
            SetCurrentProcessExplicitAppUserModelID(Aumid);
            AumidRegistration.Write(new HkcuAumidRegistration());
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
