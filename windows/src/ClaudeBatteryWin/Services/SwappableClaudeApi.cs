using ClaudeBatteryWin.Models;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// An integration-owned <see cref="IClaudeApi"/> that forwards to a swappable inner transport. It
/// exists for one reason: the outbound poll User-Agent must equal the WebView2 session UA captured
/// at login (necessary, not sufficient, for Cloudflare), but a <see cref="ClaudeApi"/> fixes its UA
/// at construction. The <see cref="UsageService"/> (U4) and <see cref="ManualSignIn"/> (U11) hold
/// their <see cref="IClaudeApi"/> by reference and never re-acquire it; injecting this wrapper lets
/// the composition root replace the inner transport in place when a login captures the real UA,
/// without modifying those units or their tests.
///
/// <para>
/// The inner transport starts as a <see cref="ClaudeApi"/> seeded with a plausible fallback UA so a
/// restored-account first poll works; <see cref="Swap"/> replaces it with a UA-matched transport on
/// the first successful login and disposes the prior one. All calls forward to whatever inner is
/// current at call time, so an in-flight account switch sees the new transport on its next request.
/// </para>
///
/// <para>
/// Per the U2 spike verdict, the inner could also be an in-WebView2 <see cref="IClaudeApi"/> if the
/// TLS/JA3 fingerprint gates a separate <see cref="System.Net.Http.SocketsHttpHandler"/> poll (403);
/// this wrapper does not care which concrete transport it forwards to.
/// </para>
/// </summary>
public sealed class SwappableClaudeApi : IClaudeApi, IDisposable
{
    private readonly object _gate = new();
    private IClaudeApi _inner;

    public SwappableClaudeApi(IClaudeApi initial)
    {
        _inner = initial ?? throw new ArgumentNullException(nameof(initial));
    }

    private IClaudeApi Current
    {
        get { lock (_gate) { return _inner; } }
    }

    /// <summary>
    /// Replace the inner transport (e.g. with a UA-matched <see cref="ClaudeApi"/> after a login
    /// captures the WebView2 session UA) and dispose the prior one. The shared cookie jar is
    /// unchanged, so the new transport keeps the active account's primed cookies.
    /// </summary>
    public void Swap(IClaudeApi next)
    {
        ArgumentNullException.ThrowIfNull(next);
        IClaudeApi old;
        lock (_gate)
        {
            old = _inner;
            _inner = next;
        }
        if (!ReferenceEquals(old, next))
        {
            (old as IDisposable)?.Dispose();
        }
    }

    public Task<UsageApiResponse> GetUsageAsync(string organizationId, CancellationToken cancellationToken)
        => Current.GetUsageAsync(organizationId, cancellationToken);

    public Task<Credits?> GetCreditsAsync(string organizationId, CancellationToken cancellationToken)
        => Current.GetCreditsAsync(organizationId, cancellationToken);

    public Task<IReadOnlyList<Organization>> GetOrganizationsAsync(CancellationToken cancellationToken)
        => Current.GetOrganizationsAsync(cancellationToken);

    public void Dispose()
    {
        IClaudeApi inner;
        lock (_gate) { inner = _inner; }
        (inner as IDisposable)?.Dispose();
    }
}
