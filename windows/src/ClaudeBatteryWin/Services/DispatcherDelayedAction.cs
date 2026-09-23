using System.Windows.Threading;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The production <see cref="IDelayedAction"/>: a one-shot <see cref="DispatcherTimer"/> on the UI
/// thread, so the action it runs can touch windows and the tray without marshalling (KTD15).
/// </summary>
public sealed class DispatcherDelayedAction : IDelayedAction
{
    private readonly Dispatcher _dispatcher;
    private DispatcherTimer? _timer;

    public DispatcherDelayedAction(Dispatcher dispatcher) =>
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));

    public void Arm(TimeSpan delay, Action action)
    {
        ArgumentNullException.ThrowIfNull(action);
        Cancel();

        var timer = new DispatcherTimer(DispatcherPriority.Background, _dispatcher) { Interval = delay };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (ReferenceEquals(_timer, timer))
            {
                _timer = null;
            }
            action();
        };
        _timer = timer;
        timer.Start();
    }

    public void Cancel()
    {
        _timer?.Stop();
        _timer = null;
    }
}
