namespace ClaudeBatteryWin.Services;

/// <summary>
/// Keeps the update check running while the app is running (R47, KTD15).
///
/// The port only ever checked at launch, so a tray app left running for a fortnight never learned
/// about a release, and the About row could sit on "Checking for updates..." forever. This checks
/// straight away, then re-arms a fresh one-shot timer for twenty-four hours after each check
/// finishes. A one-shot that re-arms itself, rather than a repeating timer, so a slow check cannot
/// overlap the next one.
///
/// Waking from sleep starts the same sequence over: check now, and count the next twenty-four hours
/// from the moment the machine woke, not from whenever the timer would have fired had the machine
/// been awake.
///
/// The timer itself is injected, so the whole schedule is testable without a dispatcher or a real
/// twenty-four hour wait.
/// </summary>
public sealed class UpdateRecheckScheduler : IDisposable
{
    /// <summary>The Mac's <c>checkInterval</c>: 86400 seconds.</summary>
    public static readonly TimeSpan Interval = TimeSpan.FromHours(24);

    private readonly Func<Task> _check;
    private readonly IDelayedAction _timer;
    private bool _disposed;

    public UpdateRecheckScheduler(Func<Task> check, IDelayedAction timer)
    {
        _check = check ?? throw new ArgumentNullException(nameof(check));
        _timer = timer ?? throw new ArgumentNullException(nameof(timer));
    }

    /// <summary>How many checks this scheduler has started. The tests read it; nothing else does.</summary>
    public int ChecksStarted { get; private set; }

    /// <summary>Check now, then arm the next check for twenty-four hours from now.</summary>
    public void Start() => CheckNowAndRearm();

    /// <summary>The machine woke: check now, and re-arm from the wake moment.</summary>
    public void HandleResume() => CheckNowAndRearm();

    private void CheckNowAndRearm()
    {
        if (_disposed)
        {
            return;
        }

        // Cancel whatever was pending first, so a resume seconds before a due tick does not leave
        // two checks armed.
        _timer.Cancel();
        ChecksStarted++;

        // The check runs on its own; the next one is armed immediately rather than after it
        // returns, so a check that hangs cannot stop the schedule.
        _ = _check();
        _timer.Arm(Interval, OnDue);
    }

    private void OnDue()
    {
        if (_disposed)
        {
            return;
        }

        ChecksStarted++;
        _ = _check();
        _timer.Arm(Interval, OnDue); // re-arm from the end of this tick
    }

    public void Dispose()
    {
        _disposed = true;
        _timer.Cancel();
    }
}

/// <summary>
/// A one-shot timer, behind an interface so the schedule above can be tested with a fake clock.
/// Production is <see cref="DispatcherDelayedAction"/>.
/// </summary>
public interface IDelayedAction
{
    /// <summary>Run <paramref name="action"/> once after <paramref name="delay"/>, replacing
    /// anything already armed.</summary>
    void Arm(TimeSpan delay, Action action);

    /// <summary>Forget anything armed.</summary>
    void Cancel();
}
