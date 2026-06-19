using ClaudeBatteryWin.Models;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The swappable transport to claude.ai. Two implementations are possible per the U2 spike
/// verdict: a <c>SocketsHttpHandler</c> with a shared <c>CookieContainer</c>, or polling inside
/// the authenticated WebView2 if the TLS/JA3 fingerprint gates a separate <c>HttpClient</c>
/// (Cloudflare <c>__cf_bm</c> is bound to a fingerprint bundle, not the UA). Both satisfy this
/// interface so the rest of the app (U4 polling, U7 org discovery) does not know which transport
/// is in use.
///
/// All methods are cancelable. The active account's cookies must already be primed into the
/// shared cookie jar (via the AccountStore activation boundary) before these are called; the
/// transport does not take a session key per call. Mirrors the Mac <c>ClaudeAPI</c> request
/// surface (Services/ClaudeAPI.swift): same endpoints, same header set.
/// </summary>
public interface IClaudeApi
{
    /// <summary>
    /// Fetch and decode <c>GET /api/organizations/{organizationId}/usage</c>. Returns the raw
    /// response shape (legacy tiers and/or the newer <c>limits[]</c>/<c>spend</c>); the caller
    /// (U4) resolves it into a <see cref="UsageSnapshot"/>.
    /// </summary>
    /// <exception cref="ClaudeAuthException">Thrown on a 401/403 so the caller can mark the
    /// account auth-failed without a credential prompt being raised.</exception>
    Task<UsageApiResponse> GetUsageAsync(string organizationId, CancellationToken cancellationToken);

    /// <summary>
    /// Fetch and decode <c>GET /api/organizations/{organizationId}/prepaid/credits</c>. Returns
    /// null when credits are unavailable (any non-2xx or decode failure), so the caller degrades
    /// silently to no-credits (R13); it does not throw for the credits path.
    /// </summary>
    Task<Credits?> GetCreditsAsync(string organizationId, CancellationToken cancellationToken);

    /// <summary>
    /// Fetch and decode <c>GET /api/organizations</c> for org discovery (U7). Never returns the
    /// first org as a default; the caller decides auto-select vs picker. An empty list means no
    /// organizations were found (a Pro/Max plan may be required).
    /// </summary>
    /// <exception cref="ClaudeAuthException">Thrown on a 401/403.</exception>
    Task<IReadOnlyList<Organization>> GetOrganizationsAsync(CancellationToken cancellationToken);
}

/// <summary>
/// Raised by <see cref="IClaudeApi"/> when claude.ai returns 401 or 403, so the polling layer
/// (U4) maps it to <see cref="Models.RenderState.AuthFailed"/> (R10) instead of treating it as a
/// transient transport failure. Carries the offending status code.
/// </summary>
public sealed class ClaudeAuthException : Exception
{
    public int StatusCode { get; }

    public ClaudeAuthException(int statusCode)
        : base($"claude.ai returned HTTP {statusCode} (authentication failure)")
    {
        StatusCode = statusCode;
    }
}
