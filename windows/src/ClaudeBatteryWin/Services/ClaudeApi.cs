using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using ClaudeBatteryWin.Models;

// Test-only seam: lets ClaudeApiTests inject a stub HttpMessageHandler (to capture the outbound
// HttpRequestMessage and script responses) without exposing the transport ctor publicly. Declared
// here rather than in the csproj so U1's project file is untouched.
[assembly: InternalsVisibleTo("ClaudeBatteryWin.Tests")]

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The default <see cref="IClaudeApi"/> transport: a <c>SocketsHttpHandler</c> with a shared
/// <c>CookieContainer</c>. Mirrors the Mac <c>ClaudeAPI</c> (Services/ClaudeAPI.swift) request
/// surface verbatim - same base URL, same endpoints, same header set and values.
///
/// Cookie handling parity with the Mac jar: <c>UseCookies=true</c> + the injected shared
/// <see cref="CookieContainer"/> means the handler auto-applies every <c>Set-Cookie</c>, so a
/// rotating Cloudflare <c>__cf_bm</c> is absorbed passively and the next request carries the new
/// value - no explicit <c>Cookie</c> header is ever set (an explicit one would suppress the jar's
/// rotation-updated cookies, the same trap the Mac avoids).
///
/// Credential-prompt safety: <c>Credentials=null</c>, <c>UseDefaultCredentials=false</c>,
/// <c>PreAuthenticate=false</c> ensure a 401/403 never raises a Windows credential dialog (the
/// .NET analog of the Mac ephemeral-session fix). A 401/403 is mapped to
/// <see cref="ClaudeAuthException"/> for the polling layer (U4) to flag the account auth-failed.
///
/// Per the U2 spike verdict, this <c>SocketsHttpHandler</c> transport is used when an
/// out-of-process <c>HttpClient</c> poll clears Cloudflare; if the TLS/JA3 fingerprint gates it
/// (403), an in-WebView2 implementation of <see cref="IClaudeApi"/> is substituted instead.
/// </summary>
public sealed class ClaudeApi : IClaudeApi, IDisposable
{
    /// <summary>Base URL for every claude.ai endpoint. Matches Mac <c>ClaudeAPI.baseURL</c>.</summary>
    public const string BaseUrl = "https://claude.ai";

    // --- Header values, copied verbatim from Mac ClaudeAPI.swift (the single source of truth). ---
    private const string ClientPlatformValue = "web_claude_ai";
    private const string ClientVersionValue = "1.0.0";
    private const string SecFetchDestValue = "empty";
    private const string SecFetchModeValue = "cors";
    private const string SecFetchSiteValue = "same-origin";
    private const string RefererValue = BaseUrl + "/settings/usage";

    private readonly HttpClient _httpClient;
    private readonly bool _ownsHttpClient;
    private readonly string _userAgent;

    // Test-only origin override. Production always targets BaseUrl; the cookie-rotation test
    // points the real SocketsHttpHandler at a loopback HttpListener so the shared CookieContainer's
    // Set-Cookie absorption can be exercised end-to-end. Null in every production path.
    private readonly string _origin;

    /// <summary>
    /// JSON options matching the Mac decoder: <c>convertFromSnakeCase</c> (so <c>five_hour</c>,
    /// <c>seven_day_opus</c>, <c>amount_minor</c>, <c>disabled_reason</c>, <c>display_name</c>,
    /// <c>is_active</c>, <c>resets_at</c> map to the C# record properties) and a tolerant
    /// <c>resets_at</c> converter spanning ISO8601 (with/without fractional seconds), UNIX epoch
    /// as a number, and epoch as a numeric string (Mac <c>ResetDate.parse</c>, KTD2). Unknown keys
    /// are ignored so a server-side shape drift degrades rather than throwing the whole decode.
    /// </summary>
    private static readonly JsonSerializerOptions JsonOptions = BuildJsonOptions();

    /// <summary>
    /// Production ctor. Builds the <c>SocketsHttpHandler</c> with the fixed cookie/credential
    /// configuration and owns the resulting <see cref="HttpClient"/>.
    /// </summary>
    /// <param name="cookieJar">The process-wide shared cookie container primed at the account
    /// activation boundary (U5). Must be the same instance the AccountStore primes, so cookie
    /// rotation and account switches are reflected here.</param>
    /// <param name="userAgent">The WebView2 session User-Agent captured after the first
    /// <c>NavigationCompleted</c> (U6) and handed in here. UA match is necessary (not sufficient)
    /// for Cloudflare; it must equal the login session's UA verbatim.</param>
    public ClaudeApi(CookieContainer cookieJar, string userAgent)
    {
        ArgumentNullException.ThrowIfNull(cookieJar);
        if (string.IsNullOrEmpty(userAgent))
        {
            throw new ArgumentException("User-Agent must be the non-empty WebView2-captured UA.", nameof(userAgent));
        }

        _userAgent = userAgent;

        var handler = new SocketsHttpHandler
        {
            UseCookies = true,
            CookieContainer = cookieJar,
            // No credential path: a 401/403 must surface as data, never as a Windows credential
            // prompt (the .NET analog of the Mac ephemeral-session urlCredentialStorage = nil).
            Credentials = null,
            PreAuthenticate = false,
            AutomaticDecompression = DecompressionMethods.All,
        };

        _httpClient = new HttpClient(handler, disposeHandler: true)
        {
            // Mirrors the Mac timeoutIntervalForRequest = 30.
            Timeout = TimeSpan.FromSeconds(30),
        };
        _ownsHttpClient = true;
        _origin = BaseUrl;
    }

    /// <summary>
    /// Test seam. Accepts a caller-built <see cref="HttpMessageHandler"/> (e.g. a stub that
    /// captures the request and scripts the response) so the header set, auth-error mapping, and
    /// cookie rotation can be asserted without a network. The handler is responsible for its own
    /// cookie behavior; this ctor does not dispose the supplied <see cref="HttpClient"/>.
    /// </summary>
    internal ClaudeApi(HttpClient httpClient, string userAgent, string? originOverride = null, bool ownsHttpClient = false)
    {
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _userAgent = string.IsNullOrEmpty(userAgent)
            ? throw new ArgumentException("User-Agent must be non-empty.", nameof(userAgent))
            : userAgent;
        _ownsHttpClient = ownsHttpClient;
        _origin = originOverride ?? BaseUrl;
    }

    /// <summary>
    /// Test-only factory: a <see cref="ClaudeApi"/> over a real <c>SocketsHttpHandler</c> with the
    /// exact production cookie/credential configuration, but targeting <paramref name="origin"/>
    /// (a loopback server) so the shared <see cref="CookieContainer"/>'s <c>Set-Cookie</c>
    /// absorption (the <c>__cf_bm</c> rotation path) is exercised end-to-end. Disposes its handler.
    /// </summary>
    internal static ClaudeApi CreateForLoopbackTest(CookieContainer cookieJar, string userAgent, string origin)
    {
        var handler = new SocketsHttpHandler
        {
            UseCookies = true,
            CookieContainer = cookieJar,
            Credentials = null,
            PreAuthenticate = false,
            AutomaticDecompression = DecompressionMethods.All,
        };
        var client = new HttpClient(handler, disposeHandler: true)
        {
            Timeout = TimeSpan.FromSeconds(30),
        };
        return new ClaudeApi(client, userAgent, origin, ownsHttpClient: true);
    }

    /// <inheritdoc />
    public async Task<UsageApiResponse> GetUsageAsync(string organizationId, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(organizationId);
        var path = $"/api/organizations/{organizationId}/usage";
        return await SendAndDecodeAsync<UsageApiResponse>(path, throwOnAuth: true, cancellationToken).ConfigureAwait(false)
               ?? new UsageApiResponse();
    }

    /// <inheritdoc />
    public async Task<Credits?> GetCreditsAsync(string organizationId, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(organizationId);
        var path = $"/api/organizations/{organizationId}/prepaid/credits";

        // Credits degrade silently to null on ANY failure (non-2xx, decode error, transport throw)
        // so the caller renders no-credits rather than failing the whole poll (R13). The Mac uses
        // try? on both the fetch and the decode; mirror that by swallowing here.
        try
        {
            return await SendAndDecodeAsync<Credits>(path, throwOnAuth: false, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw; // Honor cancellation; only credits-specific failures degrade to null.
        }
        catch
        {
            return null;
        }
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<Organization>> GetOrganizationsAsync(CancellationToken cancellationToken)
    {
        const string path = "/api/organizations";
        var orgs = await SendAndDecodeAsync<List<Organization>>(path, throwOnAuth: true, cancellationToken).ConfigureAwait(false);
        return orgs ?? new List<Organization>();
    }

    /// <summary>
    /// Build, send, and decode a GET to <paramref name="path"/>. Maps 401/403 to
    /// <see cref="ClaudeAuthException"/> when <paramref name="throwOnAuth"/> is set; for any other
    /// non-2xx returns the default (null) so the caller can treat it as a soft failure.
    /// </summary>
    private async Task<T?> SendAndDecodeAsync<T>(string path, bool throwOnAuth, CancellationToken cancellationToken)
    {
        using var request = BuildRequest(path);

        using var response = await _httpClient
            .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);

        var status = (int)response.StatusCode;

        if (status is 401 or 403)
        {
            if (throwOnAuth)
            {
                throw new ClaudeAuthException(status);
            }

            return default;
        }

        if (!response.IsSuccessStatusCode)
        {
            DebugLogUnexpectedStatus(status);
            return default;
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        return await JsonSerializer
            .DeserializeAsync<T>(stream, JsonOptions, cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Construct the request with the exact header set and values from Mac <c>ClaudeAPI.swift</c>.
    /// Restricted headers (<c>User-Agent</c>, <c>Referer</c>, <c>Origin</c>, the <c>sec-fetch-*</c>
    /// set) go through <c>TryAddWithoutValidation</c> so .NET does not reject or reformat them.
    /// No <c>Cookie</c> header is set: the handler supplies it from the shared jar and updates the
    /// jar from <c>Set-Cookie</c>, preserving <c>__cf_bm</c> rotation (Mac makeRequest contract).
    /// </summary>
    private HttpRequestMessage BuildRequest(string path)
    {
        // The request target uses _origin (BaseUrl in production; a loopback origin only under the
        // cookie-rotation test). The origin/referer header VALUES stay the claude.ai literals so
        // the wire headers always match the Mac verbatim regardless of transport target.
        var request = new HttpRequestMessage(HttpMethod.Get, new Uri(_origin + path));
        var headers = request.Headers;

        headers.TryAddWithoutValidation("anthropic-client-platform", ClientPlatformValue);
        headers.TryAddWithoutValidation("anthropic-client-version", ClientVersionValue);
        headers.TryAddWithoutValidation("User-Agent", _userAgent);
        headers.TryAddWithoutValidation("sec-fetch-dest", SecFetchDestValue);
        headers.TryAddWithoutValidation("sec-fetch-mode", SecFetchModeValue);
        headers.TryAddWithoutValidation("sec-fetch-site", SecFetchSiteValue);
        headers.TryAddWithoutValidation("origin", BaseUrl);
        headers.TryAddWithoutValidation("referer", RefererValue);

        return request;
    }

    private static JsonSerializerOptions BuildJsonOptions()
    {
        var options = new JsonSerializerOptions
        {
            // Mac decoder.keyDecodingStrategy = .convertFromSnakeCase.
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
            PropertyNameCaseInsensitive = true,
            NumberHandling = JsonNumberHandling.AllowReadingFromString,
        };
        options.Converters.Add(new TolerantResetDateConverter());
        return options;
    }

    public void Dispose()
    {
        if (_ownsHttpClient)
        {
            _httpClient.Dispose();
        }
    }

    // --- Debug-only logging (Mac critical-pattern 4). -------------------------------------------
    // Every method that could touch a secret (cookie values, sessionKey, __cf_bm, raw bodies, raw
    // headers) is gated behind [Conditional("DEBUG")] so it is compiled out of Release builds
    // entirely - the release-build test asserts no such string can reach a log sink.

    [Conditional("DEBUG")]
    private static void DebugLogUnexpectedStatus(int status)
    {
        // Status code only - never the body, which may echo cookie/session material.
        Debug.WriteLine($"[ClaudeApi] Unexpected HTTP status: {status}");
    }
}

/// <summary>
/// Tolerant <c>resets_at</c> reader, the C# port of Mac <c>ResetDate.parse</c> (issue #23, KTD2).
/// Accepts: a JSON number (UNIX epoch seconds or milliseconds), a numeric string (epoch as text),
/// and an ISO8601 string with or without fractional seconds. Anything else - or an out-of-range
/// epoch - decodes to null so a malformed value degrades to "reset time unavailable" rather than
/// throwing the whole <c>/usage</c> decode or producing a date that traps the countdown math.
/// Values at or above 1e11 are treated as milliseconds; the result is bounded to roughly the
/// years 2001-2100, matching the Mac bounds verbatim.
/// </summary>
public sealed class TolerantResetDateConverter : JsonConverter<DateTimeOffset?>
{
    // Mac dateFromEpoch bounds: seconds > 978_307_200 (2001-01-01) and < 4_102_444_800 (2100-01-01).
    private const double MinEpochSeconds = 978_307_200d;
    private const double MaxEpochSeconds = 4_102_444_800d;
    private const double MillisThreshold = 1e11;

    public override DateTimeOffset? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.Null:
                return null;

            case JsonTokenType.Number:
                if (reader.TryGetDouble(out var epoch))
                {
                    return DateFromEpoch(epoch);
                }
                return null;

            case JsonTokenType.String:
            {
                var raw = reader.GetString();
                if (string.IsNullOrEmpty(raw))
                {
                    return null;
                }

                var trimmed = raw.Trim();

                // Epoch as a numeric string.
                if (double.TryParse(trimmed, System.Globalization.NumberStyles.Float,
                        System.Globalization.CultureInfo.InvariantCulture, out var epochFromString))
                {
                    return DateFromEpoch(epochFromString);
                }

                // ISO8601 with or without fractional seconds. DateTimeOffset.TryParse with
                // RoundtripKind handles both the 'Z' and offset forms.
                if (DateTimeOffset.TryParse(trimmed, System.Globalization.CultureInfo.InvariantCulture,
                        System.Globalization.DateTimeStyles.RoundtripKind, out var iso))
                {
                    return iso;
                }

                return null;
            }

            default:
                // Skip an unexpected object/array so the surrounding decode does not throw.
                reader.Skip();
                return null;
        }
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset? value, JsonSerializerOptions options)
    {
        if (value is null)
        {
            writer.WriteNullValue();
        }
        else
        {
            writer.WriteStringValue(value.Value);
        }
    }

    private static DateTimeOffset? DateFromEpoch(double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value))
        {
            return null;
        }

        var seconds = value >= MillisThreshold ? value / 1000d : value;
        if (seconds <= MinEpochSeconds || seconds >= MaxEpochSeconds)
        {
            return null;
        }

        return DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000d));
    }
}
