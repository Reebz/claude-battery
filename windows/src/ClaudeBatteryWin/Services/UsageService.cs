using System.Globalization;
using System.Net.NetworkInformation;
using System.Text.Json;
using ClaudeBatteryWin.Models;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// Background usage polling with exponential backoff, tolerant parsing, and Windows-correct
/// failure classification. Mirrors the Mac <c>UsageService</c> (Services/UsageService.swift):
/// same backoff constants, same stale threshold, same task-chaining restart model, same
/// auth-failure semantics.
///
/// Windows-specific deltas from the Mac (the platform reasons each one is here):
/// <list type="bullet">
///   <item><b>Connectivity gate.</b> <c>HttpClient</c> has no <c>waitsForConnectivity</c> equivalent,
///   so an offline poll is detected (<see cref="INetworkAvailability"/>) and deferred before any
///   request is issued. A deferral is not a failure: it does not advance backoff and never sets
///   <see cref="AuthFailed"/>. This is the "transport throw is a soft failure" case the plan names -
///   when there is no network, the poll never escalates backoff and never false-flags auth.</item>
///   <item><b>Soft vs hard failure.</b> SOFT (no escalation, never <see cref="AuthFailed"/>): an
///   offline poll (gated out above), and the first poll after resume/autostart even if it throws
///   (the network stack may not be up yet). HARD (advances backoff): an online poll whose request
///   throws a transport error (the adapter reports up but the connection/server still failed - a
///   5xx surfaced as an exception by U3, a Cloudflare block, a reset), or a decode/resolution
///   failure on a returned body. Mirrors the Mac catch arm, minus the offline/just-woke cases that
///   <c>waitsForConnectivity</c> absorbed on the Mac.</item>
///   <item><b>Resume re-poll.</b> Re-poll on <c>SystemEvents.PowerModeChanged</c> Resume; the first
///   post-resume or post-autostart poll tolerates no-network without penalty (the network stack may
///   not be up yet).</item>
/// </list>
///
/// This service consumes <see cref="IClaudeApi"/> (U3) for transport; it never builds a second HTTP
/// client. It uses an injected <see cref="ISchedulerClock"/> so the backoff cadence is testable
/// without real timers, and an injected <see cref="INetworkAvailability"/> so the connectivity gate
/// is testable without a real adapter.
/// </summary>
public sealed class UsageService : IDisposable
{
    private static class Constants
    {
        // Verbatim from the Mac Services/UsageService.swift Constants enum.
        public const double StaleThresholdSeconds = 660;
        public const double BaseInterval = 120;
        public const double BackoffInterval1 = 300;
        public const double BackoffInterval2 = 600;
        public const double MaxBackoffInterval = 1800;
        public const int StaleFailureThreshold = 3;
        public const int BackoffThreshold2 = 6;
        public const int ErrorFailureThreshold = 10;
        public const double DefaultNotificationThreshold = 20.0;
    }

    private readonly IClaudeApi _api;
    private readonly INetworkAvailability _network;
    private readonly ISchedulerClock _clock;

    private readonly object _gate = new();
    private bool _isPolling;
    private bool _disposed;

    /// Set true at construction and again after each resume, so the next poll tolerates a missing
    /// network without counting it as a deferral cancelling escalation. Mirrors "first post-resume
    /// /autostart poll tolerates no-network without penalty".
    private bool _firstPollAfterResume = false;

    /// Drives the chained restart: the in-flight poll task whose completion the next poll awaits,
    /// preventing the race where a new poll is silently dropped (Mac <c>restartPolling</c>).
    private Task _currentPoll = Task.CompletedTask;
    private CancellationTokenSource? _pollCts;

    /// The active organization id to poll. Set by the account-activation boundary (U5) before
    /// polling starts; a null id means "no active account", and a poll is skipped.
    private string? _organizationId;

    public UsageService(IClaudeApi api, INetworkAvailability network, ISchedulerClock clock)
    {
        _api = api ?? throw new ArgumentNullException(nameof(api));
        _network = network ?? throw new ArgumentNullException(nameof(network));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _network.AvailabilityChanged += OnNetworkAvailabilityChanged;
    }

    // MARK: - Observable state (mirrors the Mac @Published properties)

    /// The latest resolved snapshot, or null when none is usable (no poll yet, or auth failed).
    public UsageSnapshot? LatestUsage { get; private set; }

    /// Timestamp of the last successful fetch, or null if there has never been one.
    public DateTimeOffset? LastSuccessfulFetch { get; private set; }

    /// Consecutive HARD failures. Soft failures (offline/transport) never increment this.
    public int ConsecutiveFailures { get; private set; }

    /// True after a 401/403. Polling stops and usage is nulled until re-auth/switch resets it.
    public bool AuthFailed { get; private set; }

    /// Raised when a state-bearing field changes, so the icon/flyout can re-render. Mirrors the
    /// Mac <c>@Published</c> notifications collapsed into one event.
    public event EventHandler? StateChanged;

    /// Raised when a poll surfaces a 401/403, mirroring the Mac <c>onAuthFailure</c> callback so
    /// the auth layer can offer re-login.
    public event EventHandler? AuthFailureDetected;

    /// True when the last successful fetch is older than the stale threshold (or never happened).
    public bool IsStale
    {
        get
        {
            var last = LastSuccessfulFetch;
            if (last is null) return true;
            return (_clock.Now - last.Value).TotalSeconds > Constants.StaleThresholdSeconds;
        }
    }

    /// Current poll interval in seconds, stepped by the consecutive-failure count. Mirrors the
    /// Mac <c>pollInterval</c> exactly: &lt;3 → 120, &lt;6 → 300, &lt;10 → 600, else 1800.
    public double PollIntervalSeconds
    {
        get
        {
            if (ConsecutiveFailures < Constants.StaleFailureThreshold) return Constants.BaseInterval;
            if (ConsecutiveFailures < Constants.BackoffThreshold2) return Constants.BackoffInterval1;
            if (ConsecutiveFailures < Constants.ErrorFailureThreshold) return Constants.BackoffInterval2;
            return Constants.MaxBackoffInterval;
        }
    }

    // MARK: - Polling lifecycle

    /// Prime the active organization without arming the scheduler or running a poll. Used at the
    /// account-activation boundary (U5) when the caller wants to drive the first poll explicitly,
    /// and by tests for deterministic single-poll exercise. <see cref="StartPolling"/> primes and
    /// arms in one call.
    public void SetOrganization(string organizationId)
    {
        lock (_gate) { _organizationId = organizationId; }
    }

    /// Begin polling the given organization: prime it, run the first poll immediately (a zero-delay
    /// scheduler fire), and re-arm at the backoff interval thereafter. Mirrors the Mac
    /// <c>startPolling</c> (immediate poll + scheduled next).
    public void StartPolling(string organizationId)
    {
        lock (_gate) { _organizationId = organizationId; }
        RestartPolling();
    }

    /// Stop polling: cancel any in-flight poll and disarm the scheduler. Does not clear state.
    public void StopPolling()
    {
        lock (_gate)
        {
            _pollCts?.Cancel();
            _clock.Disarm();
        }
    }

    /// Switch to a different account: clear all prior state and restart polling for the new org.
    /// Mirrors the Mac <c>switchAccount</c>. The cookie jar priming and request-generation token
    /// bump happen in the AccountStore (U5) at the activation boundary, before this is called.
    public void SwitchAccount(string organizationId)
    {
        bool changed;
        lock (_gate)
        {
            _organizationId = organizationId;
            changed = LatestUsage is not null || LastSuccessfulFetch is not null
                      || ConsecutiveFailures != 0 || AuthFailed;
            LatestUsage = null;
            LastSuccessfulFetch = null;
            ConsecutiveFailures = 0;
            AuthFailed = false;
            _firstPollAfterResume = true;
        }
        if (changed) RaiseStateChanged();
        RestartPolling();
    }

    /// <summary>
    /// Cancel any in-flight poll, bump the cancellation generation, and arm an immediate first
    /// fire. Mirrors the Mac <c>restartPolling</c>: the cancellation token bump is the request
    /// generation - a late response from the prior generation is discarded and cannot mutate state
    /// (the account-switch correctness model). The poll itself runs only through the scheduler
    /// (<see cref="OnTimerFired"/>), so there is no inline background poll racing an explicit one.
    /// </summary>
    private void RestartPolling()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _pollCts?.Cancel();
            _pollCts = new CancellationTokenSource();
            _clock.Disarm();
        }
        // Immediate first poll = a zero-delay scheduler fire (real timer fires near-instantly; the
        // test scheduler stores the callback for deterministic, explicit firing).
        ArmFirst();
    }

    private async Task ChainAsync(Task previous, CancellationToken token)
    {
        try { await previous.ConfigureAwait(false); }
        catch { /* a prior poll's failure must not block the next; it is already classified */ }
        if (token.IsCancellationRequested) return;
        await PollUsageAsync(token).ConfigureAwait(false);
    }

    private void ArmFirst()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _clock.Arm(TimeSpan.Zero, OnTimerFired);
        }
    }

    /// Arm the scheduler to fire the next poll after <see cref="PollIntervalSeconds"/>. The
    /// callback chains a fresh poll onto the running one, then re-arms - the Mac
    /// <c>scheduleNextPoll</c> recursion.
    private void ArmNext()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _clock.Arm(TimeSpan.FromSeconds(PollIntervalSeconds), OnTimerFired);
        }
    }

    private void OnTimerFired()
    {
        Task previous;
        CancellationToken token;
        lock (_gate)
        {
            if (_disposed) return;
            previous = _currentPoll;
            token = _pollCts?.Token ?? CancellationToken.None;
            _currentPoll = ChainAsync(previous, token);
        }
        // Re-arm after the chained poll completes, matching the Mac sequencing. Awaiting the
        // previous task before the next poll prevents the dropped-poll race the Mac documents.
        _ = _currentPoll.ContinueWith(_ => ArmNext(), TaskScheduler.Default);
    }

    // MARK: - The poll

    /// <summary>
    /// One poll. Public for testing the cadence/parse/failure-classification without timers; the
    /// scheduler drives it in production. Honors the <c>_isPolling</c> re-entrancy guard.
    /// </summary>
    public async Task PollUsageAsync(CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            if (_isPolling) return;
            _isPolling = true;
        }

        try
        {
            string? org;
            lock (_gate) { org = _organizationId; }
            if (org is null) return; // no active account; mirror the Mac "Poll skipped" guard

            // Connectivity gate: offline polls are DEFERRED, not failed. They do not advance
            // backoff and never set authFailed. HttpClient has no waitsForConnectivity, so this
            // is the explicit Windows analog. An offline deferral does NOT consume the
            // first-post-resume tolerance below - that tolerance is for the first poll that
            // actually issues a request, so a "woke up offline" sequence still gets one
            // penalty-free attempt once the network is back.
            if (!_network.IsAvailable) return;

            // Past the gate: a request is about to be issued. Consume the first-post-resume flag
            // here so exactly one real attempt after resume/autostart is penalty-free.
            bool tolerateNoNetwork;
            lock (_gate)
            {
                tolerateNoNetwork = _firstPollAfterResume;
                _firstPollAfterResume = false;
            }

            UsageApiResponse response;
            try
            {
                response = await _api.GetUsageAsync(org, cancellationToken).ConfigureAwait(false);
            }
            catch (ClaudeAuthException)
            {
                // 401/403: hard auth failure. Mirror the Mac: increment, set authFailed, null
                // usage, stop polling, notify. This is the one HTTP outcome that stops the loop.
                if (cancellationToken.IsCancellationRequested) return;
                MarkAuthFailed();
                return;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return; // superseded by a switch/restart; discard silently (never touch state)
            }
            catch
            {
                // The adapter reported the network up, but the request still threw (5xx surfaced
                // by U3, a Cloudflare block, a connection reset/timeout). This is a HARD failure
                // that advances backoff - UNLESS this is the first poll after resume/autostart,
                // which tolerates a flaky-just-woke network without penalty. Never sets authFailed
                // (only the 401/403 arm does). An offline poll never reaches here: it is gated out
                // above before any request is issued.
                if (cancellationToken.IsCancellationRequested) return;
                if (!tolerateNoNetwork) RecordHardFailure();
                return;
            }

            if (cancellationToken.IsCancellationRequested) return;

            // Credits is a separate, optional endpoint: it degrades silently to null and never
            // fails the poll (R13). IClaudeApi.GetCreditsAsync swallows non-2xx/decode internally.
            Credits? credits = null;
            try
            {
                credits = await _api.GetCreditsAsync(org, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch
            {
                credits = null; // belt-and-suspenders: never let credits sink the poll
            }

            if (cancellationToken.IsCancellationRequested) return;

            UsageSnapshot snapshot;
            try
            {
                snapshot = UsageSnapshotResolver.Resolve(response, credits);
            }
            catch
            {
                // A decode/resolution failure on a real 2xx body is a HARD failure (the server
                // answered but the shape was unusable): advance backoff like the Mac catch arm.
                if (cancellationToken.IsCancellationRequested) return;
                RecordHardFailure();
                return;
            }

            if (cancellationToken.IsCancellationRequested) return;

            // Success: publish, reset failure count and authFailed. Mirror the Mac success arm.
            bool changed;
            lock (_gate)
            {
                LatestUsage = snapshot;
                LastSuccessfulFetch = _clock.Now;
                changed = ConsecutiveFailures != 0 || AuthFailed;
                ConsecutiveFailures = 0;
                AuthFailed = false;
            }
            RaiseStateChanged(); // snapshot itself changed; always notify
            _ = changed;
        }
        finally
        {
            lock (_gate) { _isPolling = false; }
        }
    }

    private void MarkAuthFailed()
    {
        lock (_gate)
        {
            ConsecutiveFailures++;
            AuthFailed = true;
            LatestUsage = null;
        }
        StopPolling();
        RaiseStateChanged();
        AuthFailureDetected?.Invoke(this, EventArgs.Empty);
    }

    private void RecordHardFailure()
    {
        lock (_gate) { ConsecutiveFailures++; }
        RaiseStateChanged();
    }

    private void RaiseStateChanged() => StateChanged?.Invoke(this, EventArgs.Empty);

    // MARK: - Resume / connectivity

    /// Call on <c>SystemEvents.PowerModeChanged</c> Resume (wired by the app shell). Mirrors the
    /// Mac <c>handleWake</c>: skip when there is no active account or auth has failed; otherwise
    /// re-poll. The first poll after resume tolerates no-network without penalty.
    public void HandleResume()
    {
        lock (_gate)
        {
            if (_organizationId is null || AuthFailed) return;
            _firstPollAfterResume = true;
        }
        RestartPolling();
    }

    private void OnNetworkAvailabilityChanged(object? sender, EventArgs e)
    {
        // Coming back online: re-poll immediately rather than waiting out a long backoff window
        // accrued from (now-resolved) hard failures. Skip when idle or auth-failed.
        bool available = _network.IsAvailable;
        lock (_gate)
        {
            if (!available || _organizationId is null || AuthFailed) return;
        }
        RestartPolling();
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _pollCts?.Cancel();
            _clock.Disarm();
        }
        _network.AvailabilityChanged -= OnNetworkAvailabilityChanged;
    }
}

// MARK: - Connectivity abstraction

/// <summary>
/// Connectivity probe for the poll gate. The production implementation wraps
/// <see cref="NetworkInterface.GetIsNetworkAvailable"/> and <c>NetworkChange.NetworkAvailabilityChanged</c>;
/// tests provide a fake so the offline-deferral path is exercised without a real adapter.
/// </summary>
public interface INetworkAvailability
{
    bool IsAvailable { get; }
    event EventHandler? AvailabilityChanged;
}

/// <summary>
/// Default <see cref="INetworkAvailability"/> over the .NET network stack. WPF/desktop only; not
/// referenced by tests, which use a fake.
/// </summary>
public sealed class SystemNetworkAvailability : INetworkAvailability, IDisposable
{
    public SystemNetworkAvailability()
    {
        NetworkChange.NetworkAvailabilityChanged += OnChanged;
    }

    public bool IsAvailable => NetworkInterface.GetIsNetworkAvailable();

    public event EventHandler? AvailabilityChanged;

    private void OnChanged(object? sender, NetworkAvailabilityEventArgs e)
        => AvailabilityChanged?.Invoke(this, EventArgs.Empty);

    public void Dispose() => NetworkChange.NetworkAvailabilityChanged -= OnChanged;
}

// MARK: - Scheduler abstraction

/// <summary>
/// The clock + one-shot timer the poll loop arms. Mirrors the Mac single non-repeating
/// <c>Timer.scheduledTimer</c> that re-arms itself. The production implementation uses a
/// <see cref="System.Threading.Timer"/>; tests use a manual fake that fires on demand, so the
/// backoff cadence is asserted without wall-clock waits.
/// </summary>
public interface ISchedulerClock
{
    DateTimeOffset Now { get; }

    /// Arm a single fire after <paramref name="delay"/>. Replaces any prior pending fire.
    void Arm(TimeSpan delay, Action onFire);

    /// Cancel any pending fire.
    void Disarm();
}

/// <summary>
/// Default <see cref="ISchedulerClock"/> over the system clock and a re-armable timer. WPF/desktop
/// only; tests use a manual fake.
/// </summary>
public sealed class SystemSchedulerClock : ISchedulerClock, IDisposable
{
    private readonly object _lock = new();
    private System.Threading.Timer? _timer;

    public DateTimeOffset Now => DateTimeOffset.UtcNow;

    public void Arm(TimeSpan delay, Action onFire)
    {
        lock (_lock)
        {
            _timer?.Dispose();
            _timer = new System.Threading.Timer(_ => onFire(), null, delay, Timeout.InfiniteTimeSpan);
        }
    }

    public void Disarm()
    {
        lock (_lock)
        {
            _timer?.Dispose();
            _timer = null;
        }
    }

    public void Dispose() => Disarm();
}

// MARK: - Tolerant resets_at parsing (KTD2, mirrors the Mac ResetDate enum)

/// <summary>
/// Tolerant <c>resets_at</c> parsing shared by every limit/tier. Mirrors the Mac <c>ResetDate</c>
/// (Services/UsageService.swift, issue #23, KTD2).
///
/// <c>resets_at</c> arrives in shapes a single date strategy cannot all cover: ISO8601 with or
/// without fractional seconds, AND a UNIX epoch as a JSON number or a numeric string. A value that
/// is present but unmappable yields null ("reset times unavailable"), never a throw. Absent or
/// explicit null is normal - a tier/limit may simply have no reset window.
/// </summary>
public static class ResetDateParser
{
    private const double EpochMilliCutoff = 1e11;       // values >= this are milliseconds
    private const double EpochLowerBoundSeconds = 978_307_200;   // ~2001-01-01
    private const double EpochUpperBoundSeconds = 4_102_444_800; // ~2100-01-01

    /// Parse a <see cref="JsonElement"/> that may be a number (epoch s/ms), a numeric string,
    /// an ISO8601 string, or null/absent. Returns null for absent/null/unparseable.
    public static DateTimeOffset? Parse(JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Null:
            case JsonValueKind.Undefined:
                return null;

            case JsonValueKind.Number:
                return element.TryGetDouble(out var epoch) ? FromEpoch(epoch) : null;

            case JsonValueKind.String:
                return ParseString(element.GetString());

            default:
                return null;
        }
    }

    /// Parse a raw string value: epoch-as-string, or ISO8601 with/without fractional seconds.
    public static DateTimeOffset? ParseString(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var trimmed = raw.Trim();

        if (double.TryParse(trimmed, NumberStyles.Float, CultureInfo.InvariantCulture, out var epoch))
        {
            return FromEpoch(epoch);
        }

        // Round-trip / ISO8601 covers both fractional and plain forms in one parse on .NET.
        if (DateTimeOffset.TryParse(
                trimmed,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var parsed))
        {
            return parsed;
        }

        return null;
    }

    /// <summary>
    /// Parse a UNIX epoch, returning null for non-finite or implausibly out-of-range values so a
    /// malformed numeric <c>resets_at</c> degrades to "unavailable" rather than a date that traps
    /// the downstream countdown conversion. Values at or above 1e11 are milliseconds; the result
    /// is bounded to roughly years 2001-2100. Verbatim bounds from the Mac <c>dateFromEpoch</c>.
    /// </summary>
    public static DateTimeOffset? FromEpoch(double value)
    {
        if (double.IsNaN(value) || double.IsInfinity(value)) return null;
        var seconds = value >= EpochMilliCutoff ? value / 1000 : value;
        if (seconds <= EpochLowerBoundSeconds || seconds >= EpochUpperBoundSeconds) return null;
        return DateTimeOffset.FromUnixTimeMilliseconds((long)(seconds * 1000));
    }
}

// MARK: - Tolerant /usage decode (mirrors the Mac UsageResponse lenient init(from:))

/// <summary>
/// Decodes raw <c>/usage</c> JSON bytes into a <see cref="UsageApiResponse"/>, tolerating both the
/// legacy per-tier shape and the newer <c>limits[]</c>/<c>spend</c> shape, and handling the
/// polymorphic <c>resets_at</c> field via <see cref="ResetDateParser"/>. Every field is optional;
/// a missing or malformed field yields null rather than throwing the whole decode (KTD1). U3's
/// transport delegates its <c>/usage</c> decode here so the tolerant logic and its tests live in
/// one place (U4).
/// </summary>
public static class UsageResponseParser
{
    public static UsageApiResponse Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return Parse(doc.RootElement);
    }

    public static UsageApiResponse Parse(ReadOnlySpan<byte> utf8Json)
    {
        var reader = new Utf8JsonReader(utf8Json);
        using var doc = JsonDocument.ParseValue(ref reader);
        return Parse(doc.RootElement);
    }

    public static UsageApiResponse Parse(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) return new UsageApiResponse();

        return new UsageApiResponse
        {
            FiveHour = ParseTier(root, "five_hour"),
            SevenDay = ParseTier(root, "seven_day"),
            SevenDayOpus = ParseTier(root, "seven_day_opus"),
            SevenDaySonnet = ParseTier(root, "seven_day_sonnet"),
            ExtraUsage = ParseExtraUsage(root, "extra_usage"),
            Limits = ParseLimits(root),
            Spend = ParseSpend(root, "spend"),
        };
    }

    private static UsageTier? ParseTier(JsonElement root, string key)
    {
        if (!TryGetObject(root, key, out var el)) return null;
        return new UsageTier
        {
            Utilization = GetDouble(el, "utilization"),
            ResetsAt = el.TryGetProperty("resets_at", out var r) ? ResetDateParser.Parse(r) : null,
        };
    }

    private static ExtraUsageTier? ParseExtraUsage(JsonElement root, string key)
    {
        if (!TryGetObject(root, key, out var el)) return null;
        return new ExtraUsageTier
        {
            IsEnabled = GetBool(el, "is_enabled"),
            MonthlyLimit = GetDouble(el, "monthly_limit"),
            UsedCredits = GetDouble(el, "used_credits"),
            Utilization = GetDouble(el, "utilization"),
        };
    }

    private static IReadOnlyList<UsageLimit>? ParseLimits(JsonElement root)
    {
        if (!root.TryGetProperty("limits", out var arr) || arr.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var list = new List<UsageLimit>();
        foreach (var el in arr.EnumerateArray())
        {
            if (el.ValueKind != JsonValueKind.Object) continue;
            list.Add(new UsageLimit
            {
                Kind = GetString(el, "kind"),
                Group = GetString(el, "group"),
                Percent = GetDouble(el, "percent"),
                Severity = GetString(el, "severity"),
                ResetsAt = el.TryGetProperty("resets_at", out var r) ? ResetDateParser.Parse(r) : null,
                Scope = ParseScope(el, "scope"),
                IsActive = GetBool(el, "is_active"),
            });
        }
        return list;
    }

    private static LimitScope? ParseScope(JsonElement parent, string key)
    {
        if (!TryGetObject(parent, key, out var el)) return null;
        return new LimitScope
        {
            Model = ParseModelScope(el, "model"),
            Surface = GetString(el, "surface"),
        };
    }

    private static ModelScope? ParseModelScope(JsonElement parent, string key)
    {
        if (!TryGetObject(parent, key, out var el)) return null;
        return new ModelScope
        {
            Id = GetString(el, "id"),
            DisplayName = GetString(el, "display_name"),
        };
    }

    private static SpendInfo? ParseSpend(JsonElement root, string key)
    {
        if (!TryGetObject(root, key, out var el)) return null;
        return new SpendInfo
        {
            Used = ParseMoney(el, "used"),
            Limit = ParseMoney(el, "limit"),
            Percent = GetDouble(el, "percent"),
            Severity = GetString(el, "severity"),
            Enabled = GetBool(el, "enabled"),
            DisabledReason = GetString(el, "disabled_reason"),
        };
    }

    private static Money? ParseMoney(JsonElement parent, string key)
    {
        if (!TryGetObject(parent, key, out var el)) return null;
        return new Money
        {
            AmountMinor = GetDouble(el, "amount_minor"),
            Currency = GetString(el, "currency"),
            Exponent = GetInt(el, "exponent"),
        };
    }

    // --- lenient field readers: a wrong kind or absent field yields null, never a throw ---

    private static bool TryGetObject(JsonElement parent, string key, out JsonElement value)
    {
        if (parent.TryGetProperty(key, out value) && value.ValueKind == JsonValueKind.Object)
        {
            return true;
        }
        value = default;
        return false;
    }

    private static string? GetString(JsonElement parent, string key)
        => parent.TryGetProperty(key, out var el) && el.ValueKind == JsonValueKind.String
            ? el.GetString()
            : null;

    private static double? GetDouble(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var el)) return null;
        if (el.ValueKind == JsonValueKind.Number && el.TryGetDouble(out var d)) return d;
        if (el.ValueKind == JsonValueKind.String
            && double.TryParse(el.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var s))
        {
            return s;
        }
        return null;
    }

    private static int? GetInt(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var el)) return null;
        if (el.ValueKind == JsonValueKind.Number && el.TryGetInt32(out var i)) return i;
        if (el.ValueKind == JsonValueKind.String
            && int.TryParse(el.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var s))
        {
            return s;
        }
        return null;
    }

    private static bool? GetBool(JsonElement parent, string key)
    {
        if (!parent.TryGetProperty(key, out var el)) return null;
        return el.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }
}

// MARK: - Snapshot resolution (mirrors the Mac UsageData.init(from:))

/// <summary>
/// Maps a decoded <see cref="UsageApiResponse"/> plus an optional <see cref="Credits"/> into the
/// shared <see cref="UsageSnapshot"/>. Mirrors the Mac <c>UsageData.init(from:prepaidCredits:)</c>
/// exactly: prefer the newer <c>limits[]</c>/<c>spend</c> shape, fall back to the legacy per-tier
/// fields; remaining = clamp(100 - utilization/percent); per-model bars come from
/// <c>weekly_scoped</c> limits (or legacy <c>seven_day_*</c>), gated on non-null so an absent model
/// hides its bar rather than faking 100% (KTD3).
/// </summary>
public static class UsageSnapshotResolver
{
    public static UsageSnapshot Resolve(UsageApiResponse response, Credits? credits)
    {
        var limits = response.Limits;

        // Session / weekly: prefer limits[] (newer shape), else legacy per-field tiers.
        double sessionRemaining;
        DateTimeOffset? sessionResetDate;
        var sessionLimit = FirstWithPercent(limits, "session");
        if (sessionLimit is not null)
        {
            sessionRemaining = Clamp(100 - sessionLimit.Percent!.Value);
            sessionResetDate = sessionLimit.ResetsAt;
        }
        else
        {
            sessionRemaining = Clamp(100 - (response.FiveHour?.Utilization ?? 0));
            sessionResetDate = response.FiveHour?.ResetsAt;
        }

        double weeklyRemaining;
        DateTimeOffset? weeklyResetDate;
        var weeklyLimit = FirstWithPercent(limits, "weekly_all");
        if (weeklyLimit is not null)
        {
            weeklyRemaining = Clamp(100 - weeklyLimit.Percent!.Value);
            weeklyResetDate = weeklyLimit.ResetsAt;
        }
        else
        {
            weeklyRemaining = Clamp(100 - (response.SevenDay?.Utilization ?? 0));
            weeklyResetDate = response.SevenDay?.ResetsAt;
        }

        // Per-model: from weekly_scoped when limits[] present, else legacy seven_day_* gated on
        // non-null so an absent model hides its bar rather than faking 100% (KTD3).
        IReadOnlyList<ModelUsage> modelUsages;
        if (limits is not null)
        {
            modelUsages = limits
                .Where(l => l.Kind == "weekly_scoped")
                .Select(l => (limit: l, name: l.Scope?.Model?.DisplayName, percent: l.Percent))
                .Where(t => t.name is not null && t.percent is not null)
                .Select(t => new ModelUsage
                {
                    DisplayName = t.name!,
                    RemainingPercent = Clamp(100 - t.percent!.Value),
                    ResetDate = t.limit.ResetsAt,
                    ModelId = t.limit.Scope?.Model?.Id,
                })
                .ToList();
        }
        else
        {
            modelUsages = LegacyModelUsages(response);
        }

        return new UsageSnapshot
        {
            SessionRemaining = sessionRemaining,
            SessionResetDate = sessionResetDate,
            WeeklyRemaining = weeklyRemaining,
            WeeklyResetDate = weeklyResetDate,
            ModelUsages = modelUsages,
            Credits = DeriveCredits(response.Spend, credits),
        };
    }

    private static UsageLimit? FirstWithPercent(IReadOnlyList<UsageLimit>? limits, string kind)
        => limits?.FirstOrDefault(l => l.Kind == kind && l.Percent is not null);

    private static List<ModelUsage> LegacyModelUsages(UsageApiResponse response)
    {
        var models = new List<ModelUsage>();
        if (response.SevenDayOpus is { Utilization: { } opusUtil } opus)
        {
            models.Add(new ModelUsage
            {
                DisplayName = "Opus",
                RemainingPercent = Clamp(100 - opusUtil),
                ResetDate = opus.ResetsAt,
                ModelId = null,
            });
        }
        if (response.SevenDaySonnet is { Utilization: { } sonnetUtil } sonnet)
        {
            models.Add(new ModelUsage
            {
                DisplayName = "Sonnet",
                RemainingPercent = Clamp(100 - sonnetUtil),
                ResetDate = sonnet.ResetsAt,
                ModelId = null,
            });
        }
        return models;
    }

    /// Derive the unified credits display model. Mirrors the Mac
    /// <c>UsageCreditsData.derive(spend:prepaidCredits:)</c> (KTD4/KTD5/KTD7). Returns null when
    /// neither a spend object nor a positive prepaid balance exists.
    private static UsageCredits? DeriveCredits(SpendInfo? spend, Credits? prepaidCredits)
    {
        double? balanceMajor = null;
        string balanceCurrency = "USD";
        if (prepaidCredits?.Amount is { } cents && cents > 0)
        {
            balanceMajor = cents / 100.0; // minor units -> major; Mac divides by 100 (KTD6)
            balanceCurrency = prepaidCredits.Currency ?? "USD";
        }

        UsageCredits? withState = null;
        if (spend is not null)
        {
            if (spend.Enabled == true)
            {
                var currency = spend.Used?.Currency ?? "USD";
                var spent = spend.Used?.ToMajor() ?? 0;       // minor -> major once (KTD4)
                var limit = spend.Limit?.ToMajor();
                withState = new UsageCredits
                {
                    StateKind = CreditsStateKind.Enabled,
                    Spent = spent,
                    SpendLimit = limit,
                    SpendPercent = spend.Percent ?? 0,         // uncapped (KTD7)
                    SpendCurrency = currency,
                    StateResetDate = null,                     // captured shape carries none (A3)
                };
            }
            else
            {
                withState = new UsageCredits
                {
                    StateKind = CreditsStateKind.Disabled,
                    DisabledReason = spend.DisabledReason ?? "disabled",
                    StateResetDate = null,
                };
            }
        }

        // Nothing to show: no spend state and no positive balance.
        if (withState is null && balanceMajor is null) return null;

        var result = withState ?? new UsageCredits { StateKind = CreditsStateKind.None };
        return result with { BalanceMajor = balanceMajor, BalanceCurrency = balanceCurrency };
    }

    private static double Clamp(double value) => Math.Max(0, Math.Min(100, value));
}
