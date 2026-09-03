using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Text;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U3 tests for <see cref="ClaudeApi"/>. Covers the four plan scenarios:
/// (1) all request headers present and exactly the Mac values;
/// (2) a 401 surfaces as <see cref="ClaudeAuthException"/> with no credential prompt;
/// (3) a rotating <c>__cf_bm</c> Set-Cookie updates the shared <see cref="CookieContainer"/> so the
///     next request carries it;
/// (4) in a Release build no log output contains <c>sessionKey</c> or <c>__cf_bm</c>.
/// Plus a guard on the snake_case + tolerant <c>resets_at</c> decode the transport owns.
/// </summary>
public class ClaudeApiTests
{
    private const string TestUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Edg/126.0.0.0";

    // The exact header values from Mac ClaudeBattery/ClaudeBattery/Services/ClaudeAPI.swift.
    private const string ExpectedBaseUrl = "https://claude.ai";
    private const string ExpectedReferer = "https://claude.ai/settings/usage";

    // --- (1) Headers ---------------------------------------------------------------------------

    [Fact]
    public async Task GetUsageAsync_SendsExactMacHeaderSet()
    {
        var handler = new CapturingHandler(_ => JsonResponse(HttpStatusCode.OK, "{}"));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        await api.GetUsageAsync("org-123", CancellationToken.None);

        var captured = handler.LastRequest;
        Assert.NotNull(captured);

        Assert.Equal(HttpMethod.Get, captured!.Method);
        Assert.Equal(new Uri(ExpectedBaseUrl + "/api/organizations/org-123/usage"), captured.Uri);

        Assert.Equal("web_claude_ai", SingleHeader(captured, "anthropic-client-platform"));
        Assert.Equal("1.0.0", SingleHeader(captured, "anthropic-client-version"));
        Assert.Equal(TestUserAgent, SingleHeader(captured, "User-Agent"));
        Assert.Equal("empty", SingleHeader(captured, "sec-fetch-dest"));
        Assert.Equal("cors", SingleHeader(captured, "sec-fetch-mode"));
        Assert.Equal("same-origin", SingleHeader(captured, "sec-fetch-site"));
        Assert.Equal(ExpectedBaseUrl, SingleHeader(captured, "origin"));
        Assert.Equal(ExpectedReferer, SingleHeader(captured, "referer"));

        // No Cookie header is set by ClaudeApi itself: the handler/jar supplies it. And there is no
        // Authorization header (no credential path), so a 401 can never escalate to a prompt.
        Assert.False(captured.Headers.ContainsKey("Cookie"));
        Assert.False(captured.Headers.ContainsKey("Authorization"));
    }

    [Fact]
    public async Task GetUsageAsync_EscapesPathSpecialCharsInOrgId()
    {
        // A server-supplied org id with path-special chars must be percent-encoded so it cannot
        // inject extra path segments or a query string into the request URL (U20/#23).
        var handler = new CapturingHandler(_ => JsonResponse(HttpStatusCode.OK, "{}"));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        await api.GetUsageAsync("org/../evil?x", CancellationToken.None);

        var uri = handler.LastRequest!.Uri;
        Assert.Empty(uri.Query);                      // the '?' was escaped, not left as a query
        Assert.EndsWith("/usage", uri.AbsolutePath);  // no path-segment injection; shape preserved
    }

    [Fact]
    public async Task GetCreditsAsync_TargetsPrepaidCreditsEndpoint()
    {
        var handler = new CapturingHandler(_ => JsonResponse(HttpStatusCode.OK, "{\"amount\":500,\"currency\":\"USD\"}"));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var credits = await api.GetCreditsAsync("org-9", CancellationToken.None);

        Assert.Equal(new Uri(ExpectedBaseUrl + "/api/organizations/org-9/prepaid/credits"), handler.LastRequest!.Uri);
        Assert.NotNull(credits);
        Assert.Equal(500d, credits!.Amount);
        Assert.Equal("USD", credits.Currency);
    }

    [Fact]
    public async Task GetOrganizationsAsync_TargetsOrganizationsEndpoint()
    {
        const string body = "[{\"uuid\":\"u1\",\"name\":\"Acme\",\"billing_type\":\"pro\"}]";
        var handler = new CapturingHandler(_ => JsonResponse(HttpStatusCode.OK, body));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var orgs = await api.GetOrganizationsAsync(CancellationToken.None);

        Assert.Equal(new Uri(ExpectedBaseUrl + "/api/organizations"), handler.LastRequest!.Uri);
        Assert.Single(orgs);
        Assert.Equal("u1", orgs[0].Uuid);
        Assert.Equal("Acme", orgs[0].Name);
        Assert.Equal("pro", orgs[0].BillingType); // snake_case billing_type maps correctly.
    }

    // --- (2) Auth error, no credential prompt --------------------------------------------------

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, 401)]
    [InlineData(HttpStatusCode.Forbidden, 403)]
    public async Task GetUsageAsync_OnAuthStatus_ThrowsTypedAuthErrorWithNoCredentialRetry(
        HttpStatusCode status, int expectedCode)
    {
        var handler = new CapturingHandler(_ => new HttpResponseMessage(status));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var ex = await Assert.ThrowsAsync<ClaudeAuthException>(
            () => api.GetUsageAsync("org-1", CancellationToken.None));

        Assert.Equal(expectedCode, ex.StatusCode);

        // A credential prompt would manifest as the stack re-issuing the request with an
        // Authorization header. The single request carried none, and only one request was made.
        Assert.Equal(1, handler.RequestCount);
        Assert.False(handler.LastRequest!.Headers.ContainsKey("Authorization"));
    }

    [Fact]
    public async Task GetOrganizationsAsync_On403_ThrowsTypedAuthError()
    {
        var handler = new CapturingHandler(_ => new HttpResponseMessage(HttpStatusCode.Forbidden));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var ex = await Assert.ThrowsAsync<ClaudeAuthException>(
            () => api.GetOrganizationsAsync(CancellationToken.None));
        Assert.Equal(403, ex.StatusCode);
    }

    [Fact]
    public async Task GetCreditsAsync_On401_DegradesToNull_DoesNotThrow()
    {
        // Credits must NOT throw on auth failure: it degrades silently to null (R13), so the poll
        // is not failed by a missing/forbidden credits endpoint.
        var handler = new CapturingHandler(_ => new HttpResponseMessage(HttpStatusCode.Unauthorized));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var credits = await api.GetCreditsAsync("org-1", CancellationToken.None);
        Assert.Null(credits);
    }

    [Fact]
    public async Task GetUsageAsync_OnFiveHundred_Throws_NeverFabricatesEmptySuccess()
    {
        // Review #5: the old contract returned `new UsageApiResponse()` here, which the poller
        // published as a SUCCESSFUL poll - a full-looking tray during any 5xx/429 incident,
        // including non-403 Cloudflare challenges that bypass the U3 discriminator. A non-auth,
        // non-2xx must now throw a plain transport error (never ClaudeAuthException, so the poller
        // takes the backoff arm, not the auth arm).
        var handler = new CapturingHandler(_ => new HttpResponseMessage(HttpStatusCode.InternalServerError));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var ex = await Assert.ThrowsAsync<HttpRequestException>(
            () => api.GetUsageAsync("org-1", CancellationToken.None));
        Assert.IsNotType<ClaudeAuthException>(ex);
    }

    // --- (2b) Cloudflare-block discrimination on the auth exception (U3) ------------------------

    [Fact]
    public async Task AuthException_403WithCfMitigatedChallenge_FlagsCloudflareBlock()
    {
        var handler = new CapturingHandler(_ => AuthResponse(HttpStatusCode.Forbidden, cfMitigated: "challenge", contentType: "text/html"));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var ex = await Assert.ThrowsAsync<ClaudeAuthException>(() => api.GetUsageAsync("org-1", CancellationToken.None));
        Assert.Equal(403, ex.StatusCode);
        Assert.True(ex.LooksLikeCloudflareBlock); // the documented cf-mitigated: challenge tell
    }

    [Fact]
    public async Task AuthException_403WithHtmlNoCfMitigated_FlagsCloudflareBlock()
    {
        // Belt for edge configs that omit cf-mitigated: a 403 with text/html still reads as a block.
        var handler = new CapturingHandler(_ => AuthResponse(HttpStatusCode.Forbidden, contentType: "text/html"));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var ex = await Assert.ThrowsAsync<ClaudeAuthException>(() => api.GetUsageAsync("org-1", CancellationToken.None));
        Assert.True(ex.LooksLikeCloudflareBlock);
    }

    [Fact]
    public async Task AuthException_403JsonNoCfMitigated_IsGenuineAuth_NotCloudflare()
    {
        // The key safety residual: a genuine auth 403 (application/json, no cf-mitigated) must NOT be
        // flagged a Cloudflare block, so U4 still hard-stops and prompts re-auth.
        var handler = new CapturingHandler(_ => AuthResponse(HttpStatusCode.Forbidden, contentType: "application/json"));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var ex = await Assert.ThrowsAsync<ClaudeAuthException>(() => api.GetUsageAsync("org-1", CancellationToken.None));
        Assert.Equal(403, ex.StatusCode);
        Assert.False(ex.LooksLikeCloudflareBlock);
    }

    [Fact]
    public async Task AuthException_403WithBareCfRay_DoesNotFlagCloudflareBlock()
    {
        // Bare cf-ray / Server: cloudflare are on EVERY claude.ai response (it all sits behind
        // Cloudflare), so they must not flip the bool - only the documented block tell does.
        var handler = new CapturingHandler(_ =>
        {
            var resp = AuthResponse(HttpStatusCode.Forbidden, contentType: "application/json");
            resp.Headers.TryAddWithoutValidation("cf-ray", "8abc-SEA");
            resp.Headers.TryAddWithoutValidation("Server", "cloudflare");
            return resp;
        });
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var ex = await Assert.ThrowsAsync<ClaudeAuthException>(() => api.GetUsageAsync("org-1", CancellationToken.None));
        Assert.False(ex.LooksLikeCloudflareBlock);
    }

    [Fact]
    public async Task AuthException_401_IsNeverCloudflareBlock()
    {
        var handler = new CapturingHandler(_ => AuthResponse(HttpStatusCode.Unauthorized, contentType: "application/json"));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var ex = await Assert.ThrowsAsync<ClaudeAuthException>(() => api.GetUsageAsync("org-1", CancellationToken.None));
        Assert.Equal(401, ex.StatusCode);
        Assert.False(ex.LooksLikeCloudflareBlock); // a 401 is a genuine auth failure, never a CF block
    }

    [Fact]
    public void ClaudeAuthException_SingleArgCtor_DefaultsCloudflareBlockFalse()
    {
        // The kept single-arg ctor (the production throw + ~10 test call sites) must default the flag
        // false so existing 401/403 throws and FakeApi-thrown auth errors stay behaviorally unchanged.
        Assert.False(new ClaudeAuthException(403).LooksLikeCloudflareBlock);
        Assert.Equal(403, new ClaudeAuthException(403).StatusCode);
    }

    [Fact]
    public async Task AuthException_CarriesOnlyStatusAndFlag_NoBodyOrHeaderMaterial()
    {
        // The exception must carry ONLY the status int + the derived bool - never body or raw header
        // material (KTD3 redaction). Feed a secret-bearing body and assert none of it reaches Message.
        const string secretBody = "{\"sessionKey\":\"sk-ant-LEAK\"}";
        var handler = new CapturingHandler(_ =>
            AuthResponse(HttpStatusCode.Forbidden, cfMitigated: "challenge", contentType: "text/html", body: secretBody));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var ex = await Assert.ThrowsAsync<ClaudeAuthException>(() => api.GetUsageAsync("org-1", CancellationToken.None));
        Assert.DoesNotContain("sk-ant-", ex.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("sessionKey", ex.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("challenge", ex.Message, StringComparison.OrdinalIgnoreCase); // header value not echoed

        // The exception's OWN public surface is EXACTLY status + the flag (no body/header field). This
        // catches a future field that carried body/header material, where the Message asserts above (a
        // constant format string interpolating only the status) cannot.
        var declaredProps = typeof(ClaudeAuthException)
            .GetProperties(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.DeclaredOnly)
            .Select(p => p.Name)
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToArray();
        Assert.Equal(new[] { "LooksLikeCloudflareBlock", "StatusCode" }, declaredProps);
    }

    [Fact]
    public async Task SetCookie_OnA403_IsAbsorbedBySharedJar_EnablingTheU4SelfHeal()
    {
        // The CI-checkable proof of the KTD5/U4 assumption: the SocketsHttpHandler absorbs Set-Cookie
        // STATUS-INDEPENDENTLY, even on a 403, so the first restored poll's retry carries a FRESH
        // __cf_bm the server just issued. Reuse the real SocketsHttpHandler + shared CookieContainer.
        var jar = new CookieContainer();
        using var server = new LoopbackServer(ctx =>
        {
            ctx.Response.StatusCode = 403;
            ctx.Response.Headers["Set-Cookie"] = "__cf_bm=fresh; Path=/";
            ctx.Response.ContentType = "text/html";
            ctx.Response.OutputStream.Close();
        });
        var origin = server.Origin;

        using (var api = ClaudeApi.CreateForLoopbackTest(jar, TestUserAgent, origin))
        {
            // The 403 throws (throwOnAuth) - expected; the assertion is on the jar absorbing Set-Cookie
            // regardless of the status, which is exactly what U4's penalty-free retry relies on.
            await Assert.ThrowsAsync<ClaudeAuthException>(() => api.GetUsageAsync("org-1", CancellationToken.None));
        }

        Assert.Contains("__cf_bm=fresh", jar.GetCookieHeader(new Uri(origin)));
    }

    // --- (3) Cookie rotation via the shared CookieContainer ------------------------------------

    [Fact]
    public async Task RotatingCfBm_UpdatesSharedCookieContainer_NextRequestCarriesNewValue()
    {
        // Exercise the REAL SocketsHttpHandler + shared CookieContainer end-to-end against a
        // loopback server. The server rotates __cf_bm on every response; each subsequent request
        // must carry the latest value, proving the shared jar absorbs Set-Cookie (the Mac jar
        // parity that preserves Cloudflare __cf_bm rotation).
        var jar = new CookieContainer();
        var receivedCookieHeaders = new List<string>();
        var rotation = 0;

        using var server = new LoopbackServer(ctx =>
        {
            receivedCookieHeaders.Add(ctx.Request.Headers["Cookie"] ?? string.Empty);
            rotation++;
            ctx.Response.Headers["Set-Cookie"] = $"__cf_bm=rotated-{rotation}; Path=/";
            WriteJson(ctx.Response, "{}");
        });

        var origin = server.Origin;
        // Seed an initial __cf_bm exactly as the AccountStore activation boundary would.
        jar.SetCookies(new Uri(origin), "__cf_bm=initial; Path=/");

        using (var api = ClaudeApi.CreateForLoopbackTest(jar, TestUserAgent, origin))
        {
            await api.GetUsageAsync("org-1", CancellationToken.None); // carries initial, server -> rotated-1
            await api.GetUsageAsync("org-1", CancellationToken.None); // carries rotated-1, server -> rotated-2
            await api.GetUsageAsync("org-1", CancellationToken.None); // carries rotated-2
        }

        Assert.Equal(3, receivedCookieHeaders.Count);
        Assert.Contains("__cf_bm=initial", receivedCookieHeaders[0]);
        Assert.Contains("__cf_bm=rotated-1", receivedCookieHeaders[1]);
        Assert.Contains("__cf_bm=rotated-2", receivedCookieHeaders[2]);

        // The shared jar reflects the final rotated value, so any future request (or a sibling
        // request from another endpoint) carries it too.
        var finalCookies = jar.GetCookieHeader(new Uri(origin));
        Assert.Contains("__cf_bm=rotated-3", finalCookies);
    }

    // --- (4) Release build: no secret strings in log output ------------------------------------

    [Fact]
    public async Task ReleaseBuild_NoLogOutput_ContainsSessionKeyOrCfBm()
    {
        // Drive a path that, in DEBUG, would log a status line, then assert nothing carrying a
        // secret leaked. The secret-bearing body is the only place sessionKey/__cf_bm could come
        // from; in Release the [Conditional("DEBUG")] log call is compiled out entirely.
        const string secretBody = "{\"error\":\"sessionKey=sk-ant-LEAK __cf_bm=cf-LEAK\"}";

        using var captured = new CapturingTraceListener();
        Trace.Listeners.Add(captured.Listener);
        try
        {
            var handler = new CapturingHandler(_ => JsonResponse(HttpStatusCode.BadGateway, secretBody));
            using var client = new HttpClient(handler);
            var api = new ClaudeApi(client, TestUserAgent);

            // A non-auth non-2xx now THROWS (review #5) instead of returning an empty success;
            // the assertion under test is unchanged - nothing secret-bearing may reach the log.
            await Assert.ThrowsAsync<HttpRequestException>(
                () => api.GetUsageAsync("org-1", CancellationToken.None));
        }
        finally
        {
            Trace.Listeners.Remove(captured.Listener);
        }

        var output = captured.Text;
        Assert.DoesNotContain("sessionKey", output, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("__cf_bm", output, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("sk-ant-", output, StringComparison.OrdinalIgnoreCase);

#if !DEBUG
        // Belt and suspenders: in a Release build the conditional log is gone, so no status line
        // is emitted at all from this path.
        Assert.True(string.IsNullOrEmpty(output) || !output.Contains("ClaudeApi"));
#endif
    }

    // --- Decode guard: snake_case + tolerant resets_at -----------------------------------------

    [Fact]
    public async Task GetUsageAsync_DriftedFieldTypes_DegradePerField_NotThrowWholeBody()
    {
        // Strict STJ would throw on these (a bool given a string, scope given a scalar, percent
        // given a non-numeric string). Routing /usage through the tolerant UsageResponseParser
        // degrades each bad field to null and still returns a usable response (Mac KTD1). This is
        // the #1 regression: the production /usage decode is now the per-field-tolerant path.
        const string body = """
        {
          "five_hour": { "utilization": 30.0 },
          "limits": [
            {
              "kind": "weekly_scoped",
              "percent": "not-a-number",
              "is_active": "yes",
              "scope": "unexpected-scalar"
            }
          ]
        }
        """;
        var handler = new CapturingHandler(_ => JsonResponse(HttpStatusCode.OK, body));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var r = await api.GetUsageAsync("org-1", CancellationToken.None);

        Assert.Equal(30.0, r.FiveHour!.Utilization); // a well-formed field still decodes
        Assert.NotNull(r.Limits);
        Assert.Single(r.Limits!);
        Assert.Equal("weekly_scoped", r.Limits![0].Kind);
        Assert.Null(r.Limits[0].Percent);  // non-numeric string -> null, not a throw
        Assert.Null(r.Limits[0].IsActive); // non-bool -> null
        Assert.Null(r.Limits[0].Scope);    // scalar where an object is expected -> null
    }

    [Fact]
    public async Task GetUsageAsync_DecodesSnakeCaseAndTolerantResetsAt()
    {
        // Covers the snake_case mapping (five_hour, seven_day_opus, amount_minor, disabled_reason,
        // display_name, is_active) and the multi-form resets_at the tolerant parser handles.
        const string body = """
        {
          "five_hour": { "utilization": 42.0, "resets_at": "2026-07-01T12:00:00Z" },
          "seven_day": { "utilization": 10.0, "resets_at": 1782000000 },
          "seven_day_opus": { "utilization": 5.0, "resets_at": "1782000000" },
          "limits": [
            {
              "kind": "weekly_scoped",
              "percent": 30.0,
              "is_active": true,
              "scope": { "model": { "id": "opus", "display_name": "Opus" } }
            }
          ],
          "spend": {
            "percent": 120.0,
            "enabled": true,
            "disabled_reason": null,
            "used": { "amount_minor": 12345, "currency": "USD", "exponent": 2 }
          }
        }
        """;
        var handler = new CapturingHandler(_ => JsonResponse(HttpStatusCode.OK, body));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var r = await api.GetUsageAsync("org-1", CancellationToken.None);

        Assert.Equal(42.0, r.FiveHour!.Utilization);
        Assert.NotNull(r.FiveHour.ResetsAt); // ISO8601 form.
        Assert.NotNull(r.SevenDay!.ResetsAt); // numeric epoch form.
        Assert.NotNull(r.SevenDayOpus!.ResetsAt); // string-epoch form.
        Assert.Equal(r.SevenDay.ResetsAt, r.SevenDayOpus.ResetsAt); // same instant, both forms.

        Assert.NotNull(r.Limits);
        Assert.Single(r.Limits!);
        Assert.Equal("weekly_scoped", r.Limits![0].Kind);
        Assert.True(r.Limits[0].IsActive);
        Assert.Equal("Opus", r.Limits[0].Scope!.Model!.DisplayName);

        Assert.NotNull(r.Spend);
        Assert.Equal(120.0, r.Spend!.Percent); // percent can exceed 100 (KTD7).
        Assert.True(r.Spend.Enabled);
        Assert.Equal(12345d, r.Spend.Used!.AmountMinor);
        Assert.Equal(123.45d, r.Spend.Used.ToMajor());
    }

    [Theory]
    [InlineData("\"not-a-date\"")]
    [InlineData("\"\"")]
    [InlineData("null")]
    [InlineData("0")]            // below the 2001 floor -> unparseable -> null.
    [InlineData("9999999999999")] // > 1e11 treated as ms; 9.99e12 ms ~= year 2286 -> out of range -> null.
    public async Task ResetsAt_UnparseableOrOutOfRange_DecodesToNull_NotThrow(string resetsAtJson)
    {
        var body = $"{{\"five_hour\":{{\"utilization\":1.0,\"resets_at\":{resetsAtJson}}}}}";
        var handler = new CapturingHandler(_ => JsonResponse(HttpStatusCode.OK, body));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var r = await api.GetUsageAsync("org-1", CancellationToken.None);

        Assert.Equal(1.0, r.FiveHour!.Utilization); // utilization still decodes.
        Assert.Null(r.FiveHour.ResetsAt);            // bad resets_at degrades to null, no throw.
    }

    [Fact]
    public async Task ResetsAt_MillisecondEpoch_DecodesWithinRange()
    {
        // 1_782_000_000_000 ms == 1_782_000_000 s (year 2026), >= 1e11 so treated as ms.
        const string body = "{\"five_hour\":{\"resets_at\":1782000000000}}";
        var handler = new CapturingHandler(_ => JsonResponse(HttpStatusCode.OK, body));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        var r = await api.GetUsageAsync("org-1", CancellationToken.None);

        Assert.NotNull(r.FiveHour!.ResetsAt);
        Assert.Equal(1782000000L, r.FiveHour.ResetsAt!.Value.ToUnixTimeSeconds());
    }

    // --- Cancellation honored ------------------------------------------------------------------

    [Fact]
    public async Task GetUsageAsync_CanceledToken_ThrowsOperationCanceled()
    {
        var handler = new CapturingHandler(_ => JsonResponse(HttpStatusCode.OK, "{}"));
        using var client = new HttpClient(handler);
        var api = new ClaudeApi(client, TestUserAgent);

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => api.GetUsageAsync("org-1", cts.Token));
    }

    [Fact]
    public void Ctor_RejectsEmptyUserAgent()
    {
        Assert.Throws<ArgumentException>(() => new ClaudeApi(new CookieContainer(), ""));
    }

    // --- U2: cold-start transport UA seed resolver ---------------------------------------------

    [Fact]
    public void ResolveSeedUserAgent_StoredUa_IsUsed()
    {
        var account = new Account { Email = "a@x.com", SessionKey = "sk", OrganizationId = "o", UserAgent = "UA/Stored" };
        Assert.Equal("UA/Stored", ClaudeBatteryWin.App.ResolveSeedUserAgent(account));
    }

    [Fact]
    public void ResolveSeedUserAgent_NullAccountOrEmptyUa_FallsBackToANonEmptyDefault()
    {
        // A null account (nothing restored) and a pre-fix account with a null/empty UA both fall back
        // to the same frozen default - and it must be non-empty so the ClaudeApi ctor cannot throw.
        var fallback = ClaudeBatteryWin.App.ResolveSeedUserAgent(null);
        Assert.False(string.IsNullOrEmpty(fallback));

        var emptyUa = new Account { Email = "a@x.com", SessionKey = "sk", OrganizationId = "o", UserAgent = "" };
        Assert.Equal(fallback, ClaudeBatteryWin.App.ResolveSeedUserAgent(emptyUa));

        var nullUa = new Account { Email = "a@x.com", SessionKey = "sk", OrganizationId = "o", UserAgent = null };
        Assert.Equal(fallback, ClaudeBatteryWin.App.ResolveSeedUserAgent(nullUa));

        // The fallback is a valid ClaudeApi UA (the ctor accepts it - proves the coalesce is load-bearing).
        using var api = new ClaudeApi(new CookieContainer(), fallback);
        Assert.NotNull(api);
    }

    [Fact]
    public void Ctor_RejectsNullCookieJar()
    {
        Assert.Throws<ArgumentNullException>(() => new ClaudeApi(null!, TestUserAgent));
    }

    // --- Helpers -------------------------------------------------------------------------------

    private static string? SingleHeader(CapturedRequest request, string name)
    {
        return request.Headers.TryGetValue(name, out var values) ? string.Join(",", values) : null;
    }

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, string body)
    {
        return new HttpResponseMessage(status)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
    }

    /// <summary>
    /// Build an auth-status response with a controllable <c>cf-mitigated</c> header and content type,
    /// so the U3 Cloudflare-block discriminator can be asserted across crafted responses (header-only).
    /// </summary>
    private static HttpResponseMessage AuthResponse(
        HttpStatusCode status, string? cfMitigated = null, string contentType = "application/json", string body = "")
    {
        var resp = new HttpResponseMessage(status);
        if (cfMitigated is not null)
        {
            resp.Headers.TryAddWithoutValidation("cf-mitigated", cfMitigated);
        }
        resp.Content = new StringContent(body, Encoding.UTF8);
        resp.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(contentType);
        return resp;
    }

    private static void WriteJson(HttpListenerResponse response, string body)
    {
        var bytes = Encoding.UTF8.GetBytes(body);
        response.ContentType = "application/json";
        response.ContentLength64 = bytes.Length;
        response.OutputStream.Write(bytes, 0, bytes.Length);
        response.OutputStream.Close();
    }

    /// <summary>An immutable snapshot of an outbound request (the live message is disposed).</summary>
    private sealed record CapturedRequest(HttpMethod Method, Uri Uri, IReadOnlyDictionary<string, string[]> Headers);

    /// <summary>Records each outbound request and returns a scripted response.</summary>
    private sealed class CapturingHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, HttpResponseMessage> _responder;

        public CapturingHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) => _responder = responder;

        public CapturedRequest? LastRequest { get; private set; }
        public int RequestCount { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            RequestCount++;
            // Capture the RAW, unparsed header values. Enumerating request.Headers directly would
            // tokenize known headers (notably User-Agent splits into product/comment and rejoins
            // with a comma), which is a capture artifact, not what TryAddWithoutValidation sent.
            var headers = request.Headers.NonValidated.ToDictionary(
                h => h.Key, h => h.Value.ToArray(), StringComparer.OrdinalIgnoreCase);
            LastRequest = new CapturedRequest(request.Method, request.RequestUri!, headers);
            return Task.FromResult(_responder(request));
        }
    }

    /// <summary>Minimal loopback HTTP server over <see cref="HttpListener"/> for the cookie test.</summary>
    private sealed class LoopbackServer : IDisposable
    {
        private readonly HttpListener _listener;
        private readonly CancellationTokenSource _cts = new();
        private readonly Task _loop;

        public string Origin { get; }

        public LoopbackServer(Action<HttpListenerContext> handle)
        {
            var port = GetFreePort();
            Origin = $"http://127.0.0.1:{port}";
            _listener = new HttpListener();
            _listener.Prefixes.Add(Origin + "/");
            _listener.Start();

            _loop = Task.Run(async () =>
            {
                while (!_cts.IsCancellationRequested)
                {
                    HttpListenerContext ctx;
                    try
                    {
                        ctx = await _listener.GetContextAsync();
                    }
                    catch
                    {
                        break; // listener stopped
                    }

                    try
                    {
                        handle(ctx);
                    }
                    catch
                    {
                        try { ctx.Response.Abort(); } catch { /* ignore */ }
                    }
                }
            });
        }

        private static int GetFreePort()
        {
            var l = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
            l.Start();
            var port = ((IPEndPoint)l.LocalEndpoint).Port;
            l.Stop();
            return port;
        }

        public void Dispose()
        {
            _cts.Cancel();
            try { _listener.Stop(); } catch { /* ignore */ }
            try { _loop.Wait(TimeSpan.FromSeconds(2)); } catch { /* ignore */ }
            _listener.Close();
            _cts.Dispose();
        }
    }

    /// <summary>Captures Trace/Debug output so the release-build secret-leak assertion can read it.</summary>
    private sealed class CapturingTraceListener : IDisposable
    {
        private readonly StringBuilder _sb = new();
        public TraceListener Listener { get; }

        public CapturingTraceListener() => Listener = new StringWriterTraceListener(_sb);

        public string Text => _sb.ToString();

        public void Dispose() => Listener.Dispose();

        private sealed class StringWriterTraceListener : TraceListener
        {
            private readonly StringBuilder _target;
            public StringWriterTraceListener(StringBuilder target) => _target = target;
            public override void Write(string? message) => _target.Append(message);
            public override void WriteLine(string? message) => _target.AppendLine(message);
        }
    }
}
