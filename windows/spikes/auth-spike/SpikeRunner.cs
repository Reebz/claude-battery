using System.Linq;
using System.Net;
using System.Net.Http;
using ClaudeBatteryWin.Services;
using Microsoft.Web.WebView2.Core;

namespace AuthSpike;

/// <summary>
/// The U2 gate logic. Given the WebView2-captured cookies and session UA, it:
/// <list type="number">
///   <item>asserts the HttpOnly <c>sessionKey</c> + <c>__cf_bm</c> cookies were captured (step 3);</item>
///   <item>primes a fresh jar through the PRODUCTION <see cref="AccountStore.PrimeCookies"/> (verbatim);</item>
///   <item>fires <c>GET /api/organizations</c> then <c>GET /usage</c> through the PRODUCTION
///   <see cref="ClaudeApi"/> transport - a 200 means the <c>SocketsHttpHandler</c> cookie-replay
///   cleared Cloudflare (GO on the current architecture); a <see cref="ClaudeAuthException"/> 401/403
///   means the TLS/JA3 fingerprint gated it (implement U14 - the in-WebView2 transport);</item>
///   <item>runs a raw <see cref="SocketsHttpHandler"/> probe that records the EXACT HTTP status and
///   whether the body is a Cloudflare interstitial - because <see cref="ClaudeApi"/> maps 401/403 to
///   an exception and otherwise hides the raw status. The raw probe mirrors
///   <c>ClaudeApi.BuildRequest</c>'s header set (keep in sync; this is a throwaway).</item>
/// </list>
///
/// SECURITY: cookie/session VALUES, response bodies, and the captured UA string are never written to
/// the log - only names, HttpOnly/Secure flags, status codes, header presence, and body length. This
/// keeps the throwaway harness inside the same redaction discipline as the shipped app.
/// </summary>
internal static class SpikeRunner
{
    // Single-source the base URL from the production transport (R10) rather than re-declaring the
    // literal; the spike must hit the exact same origin the shipped ClaudeApi does.
    private const string ClaudeBaseUrl = ClaudeApi.BaseUrl;

    public static async Task RunGateAsync(
        IReadOnlyList<CoreWebView2Cookie> cookies,
        string? userAgent,
        Action<string> log)
    {
        log("==================== U2 GATE TEST START ====================");

        // ---- Step 3: cookie-capture assertion ----------------------------------------------------
        var claudeCookies = cookies
            .Where(c => c.Domain is "claude.ai" or ".claude.ai")
            .ToList();
        log($"[COOKIES] {claudeCookies.Count} claude.ai cookie(s) captured (values never logged):");
        foreach (var c in claudeCookies)
        {
            log($"[COOKIES]   {c.Name,-16} httpOnly={c.IsHttpOnly,-5} secure={c.IsSecure,-5} domain={c.Domain}");
        }

        var sessionKey = claudeCookies.FirstOrDefault(c => c.Name == "sessionKey");
        var cfBm = claudeCookies.FirstOrDefault(c => c.Name == "__cf_bm");
        log($"[COOKIES] sessionKey: present={sessionKey is not null} httpOnly={sessionKey?.IsHttpOnly}");
        log($"[COOKIES] __cf_bm   : present={cfBm is not null} httpOnly={cfBm?.IsHttpOnly}");
        if (sessionKey is null || !sessionKey.IsHttpOnly)
        {
            log("[COOKIES] WARN: expected an HttpOnly sessionKey. If absent, login is not complete "
                + "or capture is broken (would break U6 before it ships).");
        }
        if (cfBm is null)
        {
            log("[COOKIES] WARN: no __cf_bm captured. The Cloudflare cookie may not be set on this "
                + "route yet; the poll below is still the authoritative test.");
        }

        if (sessionKey is null)
        {
            log("[GATE] ABORT: no sessionKey cookie - finish the login, then re-run the gate test.");
            log("==================== U2 GATE TEST END ====================");
            return;
        }

        // ---- Step 4: UA presence -----------------------------------------------------------------
        if (string.IsNullOrEmpty(userAgent))
        {
            log("[GATE] ABORT: no WebView2 UA captured yet - navigate once so NavigationCompleted fires.");
            log("==================== U2 GATE TEST END ====================");
            return;
        }
        log($"[UA] using captured session UA (length {userAgent.Length}; value not logged).");

        // ---- Prime a fresh jar through the PRODUCTION AccountStore.PrimeCookies (verbatim) --------
        // Build the full "name=value; ..." header exactly as the auth funnel hands to PrimeCookies.
        var cookieHeader = string.Join("; ", claudeCookies.Select(c => $"{c.Name}={c.Value}"));
        var jar = new CookieContainer();

        // Temp paths so the spike never touches the real accounts.json / secrets dir. PrimeCookies
        // only manipulates the jar; the AccountStore is constructed solely to call it verbatim.
        var tempMeta = Path.Combine(Path.GetTempPath(), $"auth-spike-accounts-{Guid.NewGuid():N}.json");
        var tempSecrets = Path.Combine(Path.GetTempPath(), $"auth-spike-secrets-{Guid.NewGuid():N}");
        var store = new AccountStore(jar, new SecretStore(tempSecrets), tempMeta);
        store.PrimeCookies(sessionKey.Value, cookieHeader);
        var primed = jar.GetCookies(new Uri(ClaudeBaseUrl)).Count;
        log($"[JAR] primed via production AccountStore.PrimeCookies; jar holds {primed} claude.ai cookie(s).");

        // ---- Step 5a: the PRODUCTION ClaudeApi transport (the real shipped code path) -------------
        string? orgId = null;
        using (var api = new ClaudeApi(jar, userAgent))
        {
            try
            {
                var orgs = await api.GetOrganizationsAsync(CancellationToken.None);
                log($"[CLAUDEAPI] GET /api/organizations -> HTTP 2xx, {orgs.Count} org(s).");
                orgId = orgs.FirstOrDefault()?.Uuid;
                if (orgId is null)
                {
                    log("[CLAUDEAPI] 200 but zero orgs - a Pro/Max plan may be required, or this "
                        + "account has no org. The load-bearing /usage path needs an org id, so it "
                        + "was NOT exercised for this account.");
                    log("[GATE] >>> PARTIAL: org-discovery cleared Cloudflare (200), but /usage was "
                        + "NOT probed (no org id to poll). This is NOT a GO - a clean /usage 200 is the "
                        + "real architecture gate. Re-run with a Pro/Max account that has an org before "
                        + "deciding on U14.");
                }
            }
            catch (ClaudeAuthException ex)
            {
                log($"[CLAUDEAPI] GET /api/organizations -> ClaudeAuthException HTTP {ex.StatusCode}.");
                log("[GATE] >>> 401/403 on the FIRST production request. The SocketsHttpHandler "
                    + "cookie-replay did NOT clear Cloudflare/auth.");
                log("[GATE] >>> VERDICT: implement U14 (the in-WebView2 IClaudeApi). See the spike "
                    + "doc's 403 branch - swap it in at App.BuildObjectGraph via SwappableClaudeApi.");
            }
            catch (Exception ex)
            {
                log($"[CLAUDEAPI] GET /api/organizations -> {ex.GetType().Name}: {ex.Message}");
            }

            if (orgId is not null)
            {
                log("[CLAUDEAPI] org id resolved (value not logged); firing the load-bearing /usage poll.");
                try
                {
                    _ = await api.GetUsageAsync(orgId, CancellationToken.None);
                    log("[CLAUDEAPI] GET /usage -> HTTP 2xx, usage body decoded.");
                    log("[GATE] >>> 200 on the production /usage poll. SocketsHttpHandler cookie-replay "
                        + "CLEARS Cloudflare. VERDICT: GO on the current architecture; U14 not needed.");
                }
                catch (ClaudeAuthException ex)
                {
                    log($"[CLAUDEAPI] GET /usage -> ClaudeAuthException HTTP {ex.StatusCode}.");
                    log("[GATE] >>> 401/403 on /usage. VERDICT: implement U14 (in-WebView2 IClaudeApi).");
                }
                catch (Exception ex)
                {
                    log($"[CLAUDEAPI] GET /usage -> {ex.GetType().Name}: {ex.Message}");
                }
            }
        }

        // ---- Step 5b: raw-status probe (exact status + Cloudflare-challenge detection) ------------
        await RawProbeAsync(jar, userAgent, orgId, log);

        log("==================== U2 GATE TEST END ====================");
    }

    /// <summary>
    /// Fire the same request the production transport would, but on a hand-built
    /// <see cref="SocketsHttpHandler"/> that exposes the EXACT HTTP status and whether the body is a
    /// Cloudflare interstitial. <see cref="ClaudeApi"/> maps 401/403 to an exception and other non-2xx
    /// to null, so it cannot report (for example) a 503 challenge page - this probe can. The header
    /// set mirrors <c>ClaudeApi.BuildRequest</c> verbatim; keep the two in sync (throwaway spike).
    /// The response body is inspected for challenge markers but NEVER logged.
    /// </summary>
    private static async Task RawProbeAsync(CookieContainer jar, string userAgent, string? orgId, Action<string> log)
    {
        var path = orgId is not null
            ? $"/api/organizations/{Uri.EscapeDataString(orgId)}/usage"
            : "/api/organizations";

        // The org id is a secret-ish identifier; the real path is used for the request but the LOG
        // shows a placeholder so the org UUID never reaches the log, honoring the harness's stated
        // "value not logged" discipline (R18).
        var displayPath = orgId is not null
            ? "/api/organizations/<org-id>/usage"
            : "/api/organizations";

        var handler = new SocketsHttpHandler
        {
            UseCookies = true,
            CookieContainer = jar,
            Credentials = null,
            PreAuthenticate = false,
            AutomaticDecompression = DecompressionMethods.All,
        };
        using var client = new HttpClient(handler, disposeHandler: true)
        {
            Timeout = TimeSpan.FromSeconds(30),
        };

        using var req = new HttpRequestMessage(HttpMethod.Get, new Uri(ClaudeBaseUrl + path));
        var h = req.Headers;
        h.TryAddWithoutValidation("anthropic-client-platform", "web_claude_ai");
        h.TryAddWithoutValidation("anthropic-client-version", "1.0.0");
        h.TryAddWithoutValidation("User-Agent", userAgent);
        h.TryAddWithoutValidation("sec-fetch-dest", "empty");
        h.TryAddWithoutValidation("sec-fetch-mode", "cors");
        h.TryAddWithoutValidation("sec-fetch-site", "same-origin");
        h.TryAddWithoutValidation("origin", ClaudeBaseUrl);
        h.TryAddWithoutValidation("referer", ClaudeBaseUrl + "/settings/usage");

        try
        {
            using var resp = await client.SendAsync(req, HttpCompletionOption.ResponseContentRead, CancellationToken.None);
            var status = (int)resp.StatusCode;
            var body = await resp.Content.ReadAsStringAsync();

            // Cloudflare interstitial markers (managed-challenge / JS-challenge / block pages). Only
            // the boolean is logged, never the body - the body can echo session material.
            var challenge =
                body.Contains("Just a moment", StringComparison.OrdinalIgnoreCase)
                || body.Contains("cf-chl", StringComparison.OrdinalIgnoreCase)
                || body.Contains("Attention Required", StringComparison.OrdinalIgnoreCase)
                || body.Contains("Checking your browser", StringComparison.OrdinalIgnoreCase);

            var server = resp.Headers.TryGetValues("server", out var sv) ? string.Join(",", sv) : "(none)";
            var cfRay = resp.Headers.Contains("cf-ray");
            var cfMitigated = resp.Headers.TryGetValues("cf-mitigated", out var cm) ? string.Join(",", cm) : "(none)";

            log($"[RAW] GET {displayPath}");
            log($"[RAW]   status={status}  server={server}  cf-ray={cfRay}  cf-mitigated={cfMitigated}");
            log($"[RAW]   cloudflare-challenge-body={challenge}  bodyLength={body.Length}");

            if (status == 200 && !challenge)
            {
                if (orgId is not null)
                {
                    log("[RAW] >>> 200 and no challenge body on /usage: the cookie-replay poll clears "
                        + "Cloudflare. GO.");
                }
                else
                {
                    log("[RAW] >>> 200 and no challenge body on /api/organizations, but /usage was NOT "
                        + "probed (no org id). PARTIAL: re-run with an account that has an org for the "
                        + "load-bearing /usage gate.");
                }
            }
            else if (status is 401 or 403 || challenge)
            {
                log("[RAW] >>> 401/403 or a Cloudflare challenge body: the TLS/JA3 fingerprint is gating "
                    + "the out-of-process poll. Adopt U14 (poll inside the authenticated WebView2).");
            }
            else
            {
                log($"[RAW] >>> Unexpected status {status}: not a clean GO; capture this for analysis.");
            }
        }
        catch (Exception ex)
        {
            log($"[RAW] GET {displayPath} -> {ex.GetType().Name}: {ex.Message}");
        }
    }
}
