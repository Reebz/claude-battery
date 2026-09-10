using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Tests for <see cref="SwappableClaudeApi"/> (the U2 test-gap follow-on). Swap disposes the prior
/// transport, no-ops on the same reference, forwards to whatever inner is current at call time, and
/// remains thread-safe when a Swap races concurrent <see cref="IClaudeApi.GetUsageAsync"/> calls
/// (the inner reference is read under the gate, so a swap can never tear it).
/// </summary>
public class SwappableClaudeApiTests
{
    [Fact]
    public void Swap_DisposesPriorInner()
    {
        var first = new TrackingApi();
        var second = new TrackingApi();
        var swappable = new SwappableClaudeApi(first);

        swappable.Swap(second);

        Assert.True(first.Disposed);   // prior transport disposed
        Assert.False(second.Disposed); // the new live transport is not
    }

    [Fact]
    public void Swap_SameReference_DoesNotDispose()
    {
        var only = new TrackingApi();
        var swappable = new SwappableClaudeApi(only);

        swappable.Swap(only);

        Assert.False(only.Disposed); // swapping in the SAME instance must not dispose the live one
    }

    [Fact]
    public async Task Forwards_ToCurrentInner_BeforeAndAfterSwap()
    {
        var first = new TrackingApi();
        var second = new TrackingApi();
        var swappable = new SwappableClaudeApi(first);

        await swappable.GetUsageAsync("org", CancellationToken.None);
        swappable.Swap(second);
        await swappable.GetUsageAsync("org", CancellationToken.None);

        Assert.Equal(1, first.UsageCalls);  // first request hit the original inner
        Assert.Equal(1, second.UsageCalls); // post-swap request hit the new inner
    }

    [Fact]
    public async Task Swap_RacingConcurrentGetUsage_NeverThrows()
    {
        // Many callers forward through the wrapper while it is repeatedly swapped. The inner is read
        // under the gate, so a swap can never expose a torn/null reference; no caller observes an
        // exception. (A disposed inner that itself throws mid-request is the transport's concern, not
        // the wrapper's; TrackingApi tolerates post-dispose calls like an in-flight request would.)
        var swappable = new SwappableClaudeApi(new TrackingApi());

        using var cts = new CancellationTokenSource();
        var callers = Enumerable.Range(0, 8).Select(_ => Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                await swappable.GetUsageAsync("org", CancellationToken.None);
            }
        })).ToArray();

        for (var i = 0; i < 50; i++)
        {
            swappable.Swap(new TrackingApi());
        }

        cts.Cancel();
        await Task.WhenAll(callers); // no caller threw
    }

    [Fact]
    public void Ctor_RejectsNullInitial()
        => Assert.Throws<ArgumentNullException>(() => new SwappableClaudeApi(null!));

    /// <summary>An IClaudeApi double that counts usage calls and records disposal, tolerating
    /// post-dispose calls so the swap-race test exercises the wrapper, not the transport.</summary>
    private sealed class TrackingApi : IClaudeApi, IDisposable
    {
        private int _usageCalls;

        public int UsageCalls => _usageCalls;
        public bool Disposed { get; private set; }

        public Task<UsageApiResponse> GetUsageAsync(string organizationId, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref _usageCalls);
            return Task.FromResult(new UsageApiResponse());
        }

        public Task<Credits?> GetCreditsAsync(string organizationId, CancellationToken cancellationToken)
            => Task.FromResult<Credits?>(null);

        public Task<IReadOnlyList<Organization>> GetOrganizationsAsync(CancellationToken cancellationToken)
            => Task.FromResult<IReadOnlyList<Organization>>(Array.Empty<Organization>());

        public void Dispose() => Disposed = true;
    }
}
