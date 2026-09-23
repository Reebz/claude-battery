using System.Diagnostics;
using ClaudeBatteryWin.Models;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The Windows port of the Mac <c>AuthManager</c> (Services/AuthManager.swift), encoding its nine
/// rounds of auth hardening (U6 login + capture, U7 org discovery). The Mac scars are preserved:
///
/// <list type="bullet">
/// <item><b>Capture guard.</b> Exactly-once capture via <see cref="_hasCapturedSession"/>. EVERY
/// failure edge (timeout, cancel, org-discovery failure, picker-cancel) resets the guard so a retry
/// can capture again. A guard left set once caused a permanent re-auth lockout on macOS.</item>
/// <item><b>Exact-domain validation.</b> <see cref="ShouldAllow(string)"/> matches
/// <c>claude.ai</c> / <c>.claude.ai</c> with <c>==</c> only - never <c>EndsWith</c>/<c>Contains</c>,
/// which would accept <c>evil-claude.ai</c> or <c>claude.ai.evil.com</c> (critical pattern #2).</item>
/// <item><b>Scheme before host.</b> <see cref="AllowsOAuthPopup(string)"/> checks the <c>about:</c>
/// scheme BEFORE the host so <c>about:blank</c>/<c>about:srcdoc</c> OAuth bootstrap frames (which
/// have no host) are permitted; a host-first guard silently blocked Google sign-in (round-9
/// regression, critical pattern #7).</item>
/// <item><b>Activity-based timeout.</b> A ~10-minute inactivity timer, re-armed on every navigation
/// (not wall-clock), so a user reading their email for a code is never timed out mid-flow.</item>
/// <item><b>Never <c>orgs[0]</c>.</b> Org selection goes through the pure <see cref="SelectOrg"/>
/// rule; multi-org presents a picker and a re-auth auto-matches an existing account in place (the
/// Mac multi-org 100%/100% bug).</item>
/// <item><b>Close only on success.</b> The login window tears down only after org discovery
/// succeeds; closing during capture cancels the pending discovery task and returns to idle with no
/// dangling async mutation.</item>
/// </list>
///
/// <para>
/// <b>Testability.</b> The login chrome (a real WebView2 + window) is abstracted behind
/// <see cref="ILoginWebView"/>, injected via <see cref="ILoginWebViewFactory"/>. The transport is
/// the U3 <see cref="IClaudeApi"/>. Org-add goes through the U5 <see cref="AccountStore"/>. So the
/// full state machine, capture funnel, timeout, popup gate, and org discovery are unit-testable on
/// any platform with a fake webview that raises cookie sets and navigations - no WebView2 needed.
/// The pure predicates (<see cref="ShouldAllow"/>, <see cref="AllowsOAuthPopup"/>,
/// <see cref="IsAllowedHost"/>, <see cref="SelectOrg"/>) are static and need no instance at all.
/// </para>
///
/// <para>
/// <b>Threading.</b> Like the Mac <c>@MainActor</c> manager, the instance methods are intended to be
/// driven from the UI thread (the WebView2 events arrive there). The state machine mutations are not
/// internally locked; the capture guard plus per-task cancellation provide the ordering guarantees.
/// </para>
/// </summary>
public sealed class AuthManager
{
    private readonly IClaudeApi _api;
    private readonly AccountStore _accountStore;
    private readonly ILoginWebViewFactory _loginWebViewFactory;
    private readonly IOrgPicker _orgPicker;

    /// <summary>Where blocked navigations are recorded. Resolved at emit time so the composition
    /// root's logger is used rather than the placeholder that exists at construction.</summary>
    private IDiagnosticsLogger _diagnostics => DiagnosticsLogger.Shared;

    /// Inactivity timeout. Ported verbatim from the Mac 10-minute login timeout.
    private readonly TimeSpan _loginTimeout;

    private ILoginWebView? _loginWebView;
    private CancellationTokenSource? _orgDiscoveryCts;
    private CancellationTokenSource? _timeoutCts;

    /// Exactly-once capture latch (Mac <c>hasCapturedSession</c>, critical pattern #3). Every failure
    /// edge resets it; the capture funnel and every navigation/cookie trigger guard on it.
    private bool _hasCapturedSession;

    // Latched when the login window's one-shot CoreWebView2 init fails (InitFailed). A dead-init
    // window can never navigate - a Navigate would only feed its pending-navigation latch, which
    // nothing will ever consume (the init success path already cannot run again) - so RetryLogin
    // keys on this to tear down and re-present a FRESH window instead of re-driving the dead one
    // (the blank-window trap). Reset when a new window is presented.
    private bool _loginInitFailed;

    private string? _pendingSessionKey;
    private string? _pendingCookieHeader;

    private LoginState _loginState = LoginState.Idle;

    /// <summary>
    /// The current login state. Setting it raises <see cref="LoginStateChanged"/>. The flyout's
    /// suppress-dismiss flag and signing-in panel both key on
    /// <see cref="LoginState.IsLoginInProgress"/> (signing-in / capturing / org-discovery / picker),
    /// not on <see cref="LoginStateKind.SigningIn"/> alone.
    /// </summary>
    public LoginState LoginState
    {
        get => _loginState;
        private set
        {
            if (_loginState == value)
            {
                return;
            }

            _loginState = value;

            // The state the sign-in reached, so a report can say where it stopped. An error message
            // can carry anything the page put in it, which is why every line is redacted.
            _diagnostics.EmitMilestone("login-state", () => new Dictionary<string, object?>
            {
                ["state"] = value.Kind == LoginStateKind.Error
                    ? "error: " + (value.Message ?? string.Empty)
                    : value.Kind.ToString(),
            });

            LoginStateChanged?.Invoke(value);
        }
    }

    /// <summary>Raised on every login-state transition (idle → signingIn → … → active/error).</summary>
    public event Action<LoginState>? LoginStateChanged;

    /// <summary>Invoked once a login fully succeeds (account added/reactivated and activated).</summary>
    public Action? OnAuthSuccess { get; set; }

    /// <summary>
    /// Hook the app wires to open Settings at the manual-paste section. The login error surface's
    /// "Sign in manually" affordance invokes it so a stuck user always reaches the universal floor.
    /// </summary>
    public Action? OnManualSignInRequested { get; set; }

    /// <summary>
    /// Raised with a sentence to show the user after a sign-in that repaired more than the account
    /// it signed in to (R16, R25). Null on a plain re-authentication, which has nothing to report.
    /// </summary>
    public Action<string>? OnSignInConfirmation { get; set; }

    /// <summary>
    /// Stops polling and waits for any in-flight poll to finish, before this sign-in writes to the
    /// shared cookie jar (R22, KTD3). Awaited, not fire-and-forget: the point is that nothing is
    /// reading the jar while it is rewritten.
    /// </summary>
    public Func<Task>? OnSuspendPolling { get; set; }

    /// <summary>
    /// Restarts polling. Runs on every exit of a sign-in route - success, every failure, and
    /// cancellation - because a missed resume leaves polling dead until the app restarts.
    /// </summary>
    public Action? OnResumePolling { get; set; }

    /// <summary>
    /// The WebView2 session User-Agent, read from <c>CoreWebView2.Settings.UserAgent</c> after the
    /// first <c>NavigationCompleted</c> and asserted non-empty. Handed to U3's <see cref="ClaudeApi"/>
    /// so the outbound poll UA equals the login session UA verbatim (necessary, not sufficient, for
    /// Cloudflare). Null until the first navigation completes.
    /// </summary>
    public string? CapturedUserAgent { get; private set; }

    public AuthManager(
        IClaudeApi api,
        AccountStore accountStore,
        ILoginWebViewFactory loginWebViewFactory,
        IOrgPicker orgPicker,
        TimeSpan? loginTimeout = null)
    {
        _api = api ?? throw new ArgumentNullException(nameof(api));
        _accountStore = accountStore ?? throw new ArgumentNullException(nameof(accountStore));
        _loginWebViewFactory = loginWebViewFactory ?? throw new ArgumentNullException(nameof(loginWebViewFactory));
        _orgPicker = orgPicker ?? throw new ArgumentNullException(nameof(orgPicker));
        _loginTimeout = loginTimeout ?? TimeSpan.FromMinutes(10);
    }

    // ---- Testing seams (internal; InternalsVisibleTo("ClaudeBatteryWin.Tests") via ClaudeApi.cs) --

    internal bool HasCapturedSession => _hasCapturedSession;
    internal string? PendingSessionKey => _pendingSessionKey;
    internal string? PendingCookieHeader => _pendingCookieHeader;
    internal bool HasActiveLoginWebView => _loginWebView is not null;

    /// The org-discovery task kicked off by the most recent capture. Tests await it to observe the
    /// terminal state deterministically without sleeping. Null until a capture fires.
    internal Task? LastDiscoveryTask { get; private set; }

    /// The inactivity-timeout task most recently armed. Tests await it to observe the timeout's
    /// terminal teardown deterministically. Null until a login is presented.
    internal Task? LastTimeoutTask { get; private set; }

    // ============================================================================================
    // Pure predicates - static, no WebView2, directly unit-testable.
    // ============================================================================================

    /// <summary>
    /// The login-WebView navigation allowlist for the MAIN frame: exact-domain claude.ai only, plus
    /// the <c>about:</c> bootstrap frames. This is the pure, testable core of
    /// <see cref="ILoginWebView"/>'s <c>NavigationStarting</c> handling.
    ///
    /// Scheme is checked BEFORE host (critical pattern #7): <c>about:blank</c>/<c>about:srcdoc</c>
    /// have no host, so a host guard placed first would silently block them and break the OAuth
    /// bootstrap. The host check is exact-label only (<c>==</c>) - never <c>EndsWith</c>/<c>Contains</c>
    /// - so <c>evil-claude.ai</c> and <c>claude.ai.evil.com</c> are rejected (pattern #2).
    /// </summary>
    public static bool ShouldAllow(string url) => AllowsUrl(url, IsExactClaudeHost);

    /// <summary>
    /// The shared validate-then-dispatch skeleton behind <see cref="ShouldAllow"/> and
    /// <see cref="AllowsOAuthPopup"/>: reject blank, allow the <c>about:</c> bootstrap frames (scheme
    /// BEFORE host, pattern #7), reject anything not an absolute URI, then gate the real host through
    /// <paramref name="hostPredicate"/> (exact-claude for the main frame, the broad OAuth allowlist for
    /// popups). One skeleton so the two callers cannot drift apart.
    /// </summary>
    private static bool AllowsUrl(string url, Func<string, bool> hostPredicate)
    {
        if (string.IsNullOrWhiteSpace(url))
        {
            return false;
        }

        // Scheme BEFORE host. Cheap string check first so a hostless about: URI that Uri.TryCreate
        // may parse oddly is handled deterministically.
        if (IsAboutBootstrap(url))
        {
            return true;
        }

        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            return false;
        }

        if (string.Equals(uri.Scheme, "about", StringComparison.OrdinalIgnoreCase))
        {
            return IsAboutBootstrap(url);
        }

        return hostPredicate(uri.Host);
    }

    /// <summary>
    /// Whether a popup/new-window request to <paramref name="url"/> should be allowed into the hosted
    /// OAuth popup WebView. Mirrors the Mac <c>allowsOAuthPopup</c>: the <c>about:</c> scheme check
    /// precedes the host check (pattern #7), then the broad OAuth-provider allowlist
    /// (<see cref="IsAllowedHost"/>) gates real hosts. The popup gets its own
    /// <c>NavigationStarting</c> handler enforcing this same allowlist so it cannot wander after the
    /// bootstrap.
    /// </summary>
    public static bool AllowsOAuthPopup(string url) => AllowsUrl(url, IsAllowedHost);

    /// <summary>
    /// True for the <c>about:</c> OAuth bootstrap frames Google's flow uses: <c>about:blank</c>
    /// (with or without a query/fragment suffix) and <c>about:srcdoc</c>. Matched on the raw string
    /// because these are not always parseable as a host-bearing <see cref="Uri"/>.
    /// </summary>
    private static bool IsAboutBootstrap(string url)
    {
        var s = url.TrimStart();
        // StartsWith("about:blank") already subsumes the exact "about:blank" match, so the prior
        // explicit `s == "about:blank"` arm was dead and was removed (R12); behavior is unchanged.
        return s.StartsWith("about:blank", StringComparison.OrdinalIgnoreCase)
            || s.StartsWith("about:srcdoc", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Exact claude.ai host: <c>claude.ai</c> or <c>.claude.ai</c> only. The leading-dot form is the
    /// cookie-domain spelling; either is accepted but NEVER a suffix/substring (pattern #2).
    /// </summary>
    private static bool IsExactClaudeHost(string host) =>
        host == "claude.ai" || host == ".claude.ai";

    /// <summary>
    /// True when the session cookie may legitimately come from <paramref name="domain"/>. The session
    /// cookie funnel calls this so only an exact claude.ai domain can deliver <c>sessionKey</c>
    /// (session-fixation guard, pattern #2). Ported from Mac <c>isSessionCookie</c>'s domain test.
    /// </summary>
    public static bool IsSessionCookieDomain(string domain) =>
        domain == "claude.ai" || domain == ".claude.ai";

    /// <summary>
    /// Any cookie scoped to claude.ai (exact or leading-dot only). Used when building the full Cookie
    /// header after capture. Mac <c>isClaudeCookie</c>; never a suffix match.
    /// </summary>
    public static bool IsClaudeCookieDomain(string domain) =>
        domain == "claude.ai" || domain == ".claude.ai";

    /// <summary>
    /// The full OAuth-provider navigation allowlist for popups, ported verbatim from the Mac
    /// <c>isAllowedDomain</c>. Exact apex match (<c>==</c>) plus leading-dot subdomain
    /// (<c>.X</c> via <c>EndsWith(".X")</c>) for multi-label domains - rejecting attacker-injected
    /// prefixes like <c>evil.googleapis.com.attacker.com</c> that a bare <c>EndsWith(".googleapis.com")</c>
    /// would accept. Localized Google ccTLD hosts are enumerated (issues #17/#25), never a structural
    /// <c>accounts.google.&lt;any-tld&gt;</c> wildcard.
    /// </summary>
    public static bool IsAllowedHost(string host)
    {
        if (string.IsNullOrEmpty(host))
        {
            return false;
        }

        return host == "claude.ai"
            || host.EndsWith(".claude.ai", StringComparison.Ordinal)
            || host.EndsWith(".anthropic.com", StringComparison.Ordinal)
            || host == "accounts.google.com"
            || host.EndsWith(".accounts.google.com", StringComparison.Ordinal)
            || IsLocalizedGoogleAccountsHost(host)
            || host == "google.com"
            || host.EndsWith(".google.com", StringComparison.Ordinal)
            || host.EndsWith(".gstatic.com", StringComparison.Ordinal)
            || host.EndsWith(".googleapis.com", StringComparison.Ordinal)
            || host.EndsWith(".googleusercontent.com", StringComparison.Ordinal)
            || host == "youtube.com"
            || host.EndsWith(".youtube.com", StringComparison.Ordinal)
            || host == "appleid.apple.com"
            || host.EndsWith(".appleid.apple.com", StringComparison.Ordinal)
            || host.EndsWith(".icloud.com", StringComparison.Ordinal)
            || host == "challenges.cloudflare.com"
            || host.EndsWith(".challenges.cloudflare.com", StringComparison.Ordinal)
            || host == "cf-chl-widget.cloudflare.com";
    }

    /// <summary>
    /// Google serves "Continue with Google" on country-specific accounts hosts (e.g.
    /// <c>accounts.google.com.tr</c>) that 302 back to <c>accounts.google.com</c>. The allowlist
    /// evaluates the localized host BEFORE the redirect fires, so each is enumerated and matched with
    /// <c>==</c> for the apex plus a leading-dot <c>EndsWith</c> for subdomains - never a structural
    /// <c>accounts.google.&lt;tld&gt;</c> wildcard (issues #17/#25). Ported verbatim from the Mac set.
    /// </summary>
    public static bool IsLocalizedGoogleAccountsHost(string host)
    {
        if (GoogleAccountsLocalizedHosts.Contains(host))
        {
            return true;
        }

        // Match against the leading-dot suffixes built ONCE at class init, instead of concatenating
        // "." + allowed on every non-matching call (~60 string allocations per login NavigationStarting
        // tick) (R13). Behavior is identical: a leading-dot EndsWith for each enumerated host.
        foreach (var suffix in GoogleAccountsLocalizedHostSuffixes)
        {
            if (host.EndsWith(suffix, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    /// Enumerated Google country accounts hosts (ported verbatim from Mac
    /// <c>googleAccountsLocalizedHosts</c>). Each entry is a Google-operated country domain.
    private static readonly HashSet<string> GoogleAccountsLocalizedHosts = new(StringComparer.Ordinal)
    {
        // Europe
        "accounts.google.co.uk", "accounts.google.de", "accounts.google.fr",
        "accounts.google.es", "accounts.google.it", "accounts.google.nl",
        "accounts.google.pl", "accounts.google.ru", "accounts.google.ch",
        "accounts.google.at", "accounts.google.be", "accounts.google.se",
        "accounts.google.no", "accounts.google.dk", "accounts.google.fi",
        "accounts.google.pt", "accounts.google.gr", "accounts.google.cz",
        "accounts.google.hu", "accounts.google.ro", "accounts.google.ie",
        "accounts.google.sk", "accounts.google.bg", "accounts.google.hr",
        "accounts.google.lt", "accounts.google.lv", "accounts.google.ee",
        "accounts.google.si", "accounts.google.com.ua",
        // Americas
        "accounts.google.ca", "accounts.google.com.br", "accounts.google.com.mx",
        "accounts.google.com.ar", "accounts.google.com.co", "accounts.google.com.pe",
        "accounts.google.cl",
        // Middle East & Africa
        "accounts.google.com.tr", "accounts.google.com.sa", "accounts.google.ae",
        "accounts.google.com.eg", "accounts.google.co.za", "accounts.google.com.ng",
        "accounts.google.co.ke", "accounts.google.co.il",
        // Asia-Pacific
        "accounts.google.co.jp", "accounts.google.co.kr", "accounts.google.co.in",
        "accounts.google.co.id", "accounts.google.co.th", "accounts.google.com.sg",
        "accounts.google.com.hk", "accounts.google.com.tw", "accounts.google.com.ph",
        "accounts.google.com.vn", "accounts.google.com.my", "accounts.google.com.pk",
        "accounts.google.com.au", "accounts.google.co.nz",
    };

    /// The leading-dot suffix forms (<c>"." + host</c>) of every localized Google accounts host,
    /// built ONCE so the subdomain <c>EndsWith</c> check in <see cref="IsLocalizedGoogleAccountsHost"/>
    /// does not allocate a fresh concatenation per host on every navigation (R13).
    private static readonly string[] GoogleAccountsLocalizedHostSuffixes =
        GoogleAccountsLocalizedHosts.Select(h => "." + h).ToArray();

    /// <summary>
    /// Pure org-selection rule (pattern #6: never blindly take <c>orgs[0]</c>) shared by the WebView
    /// and manual-paste paths. Single org → take it; else if an existing account's org is in the list
    /// → auto-select that match (re-auth in place); else the caller must show a picker. Ported from
    /// the Mac <c>selectOrg</c>.
    /// </summary>
    public static OrgSelection SelectOrg(IReadOnlyList<Organization> orgs, IReadOnlyList<Account> accounts)
    {
        if (orgs.Count == 1)
        {
            return OrgSelection.Single(orgs[0]);
        }

        var unadded = orgs.Where(o => accounts.All(a => a.OrganizationId != o.Uuid)).ToList();

        // Nothing left to choose: every organization in the response is already stored, so this
        // sign-in is a repair of all of them.
        if (unadded.Count == 0)
        {
            return OrgSelection.AllAlreadyAdded(orgs);
        }

        // Deliberately no silent match on an organization that is already stored, even when only one
        // of several is: reusing it is exactly what made a second organization of the same login
        // impossible to add (R17).
        return OrgSelection.NeedsChoice(orgs);
    }

    /// <summary>
    /// The address to label an account with (R19). The account endpoint first, because it is the
    /// signed-in user's own address; the organizations response second, because an organization's
    /// address is whoever set it up. Null when neither has one, and the caller falls back to
    /// "Account N".
    /// </summary>
    private Task<string?> ResolveEmailAsync(IReadOnlyList<Organization> orgs, CancellationToken token) =>
        ResolveEmailAsync(_api, orgs, token);

    /// <inheritdoc cref="ResolveEmailAsync(IReadOnlyList{Organization}, CancellationToken)"/>
    public static async Task<string?> ResolveEmailAsync(
        IClaudeApi api, IReadOnlyList<Organization> orgs, CancellationToken token)
    {
        try
        {
            var fromAccount = await api.GetAccountEmailAsync(token).ConfigureAwait(true);
            if (!string.IsNullOrEmpty(fromAccount))
            {
                return fromAccount;
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception)
        {
            // Nothing about this lookup is allowed to fail a sign-in that otherwise worked.
        }

        return ExtractEmail(orgs);
    }

    /// <summary>
    /// Whether a label is one the app made up rather than a real address (R21). Only the app's own
    /// "Account N" shape counts: "Accountant 2" and "Account 1 (work)" are things a user typed.
    /// </summary>
    public static bool IsPlaceholderEmail(string email)
    {
        var trimmed = email.Trim(' ', '\t');
        if (trimmed.Length == 0)
        {
            return true; // an empty label renders as nothing, so it is a placeholder too
        }

        const string prefix = "Account ";
        if (!trimmed.StartsWith(prefix, StringComparison.Ordinal))
        {
            return false;
        }

        var digits = trimmed[prefix.Length..];
        return digits.Length > 0 && digits.All(c => c is >= '0' and <= '9');
    }

    /// <summary>
    /// Replaces a made-up label with a real address, and never the other way round (R21).
    ///
    /// Two different logins can share one organization, and the account row is labelled by whoever
    /// added it first. Overwriting a real address on a later sign-in would rename someone else's
    /// row out from under them. A user-chosen nickname is untouched either way.
    /// </summary>
    private void RepairPlaceholderEmail(Account account, string? email) =>
        RepairPlaceholderEmail(_accountStore, account, email);

    /// <inheritdoc cref="RepairPlaceholderEmail(Account, string?)"/>
    public static void RepairPlaceholderEmail(AccountStore store, Account account, string? email)
    {
        if (email is null || IsPlaceholderEmail(email) || !IsPlaceholderEmail(account.Email))
        {
            return;
        }

        store.UpdateEmail(account.Id, email);
    }

    /// <summary>
    /// Revive every other stored organization that this login can reach, and return how many were
    /// touched (R16). The organization just signed in to is written by the caller, so it is excluded.
    /// </summary>
    private int RefreshSiblings(
        IReadOnlyList<Organization> orgs, string chosenOrgId, string sessionKey, string? resolvedEmail)
    {
        var siblings = MatchedAccounts(orgs, _accountStore.Accounts)
            .Where(a => a.OrganizationId != chosenOrgId)
            .ToList();

        foreach (var sibling in siblings)
        {
            // The captured WebView2 UA rides with the fresh cookies it was issued under, so the next
            // launch or switch to this sibling does not poll them with a stale UA (U1/U2).
            _accountStore.RepairFromSignIn(sibling, orgs, sessionKey, _pendingCookieHeader, CapturedUserAgent, resolvedEmail);
        }

        return siblings.Count;
    }

    /// <summary>
    /// Repairs every stored organization this login covers, when the response offered nothing new to
    /// add. The switch runs last, after all the writes, so it stays the only thing that re-primes the
    /// live cookie jar.
    /// </summary>
    private async Task RepairAllStoredOrganizationsAsync(
        IReadOnlyList<Organization> orgs, string sessionKey, CancellationToken token)
    {
        var resolvedEmail = await ResolveEmailAsync(orgs, token).ConfigureAwait(true);
        if (token.IsCancellationRequested)
        {
            return;
        }

        var target = MatchedAccount(orgs);
        if (target is null)
        {
            HandleOrgDiscoveryFailure("Account limit reached.");
            return;
        }

        var repaired = MatchedAccounts(orgs, _accountStore.Accounts);
        foreach (var account in repaired)
        {
            // Persist the captured WebView2 UA with the fresh cookies (U1/U2). OnAuthSuccess swaps it
            // into the live transport, but the activation re-seed and every later launch read the
            // STORED UA: leaving it stale polled the new cf_clearance under the old UA and got a 403.
            _accountStore.RepairFromSignIn(account, orgs, sessionKey, _pendingCookieHeader, CapturedUserAgent, resolvedEmail);
        }

        if (target.Id != _accountStore.ActiveAccountId)
        {
            _accountStore.SwitchTo(target.Id);
        }

        ReportRepair(repaired.Count - 1, signedInOrgRepaired: true);

        _pendingSessionKey = null;
        _pendingCookieHeader = null;
        LoginState = LoginState.Active;
        StopLoginWindow();
        OnAuthSuccess?.Invoke();
    }

    /// <summary>
    /// Tells the user how many organizations a sign-in revived, but only when it revived one other
    /// than the organization signed in to. A plain re-authentication of a single account has nothing
    /// worth saying.
    /// </summary>
    private void ReportRepair(int siblingsRepaired, bool signedInOrgRepaired)
    {
        if (siblingsRepaired < 1)
        {
            return;
        }

        var count = siblingsRepaired + (signedInOrgRepaired ? 1 : 0);
        OnSignInConfirmation?.Invoke(RepairConfirmation(count, viewedAccountRepaired: true));
    }

    /// <summary>
    /// Every stored account whose organization appears in this response, in stored order. This is
    /// the repair set: one sign-in refreshes all of them (R16).
    /// </summary>
    public static IReadOnlyList<Account> MatchedAccounts(
        IReadOnlyList<Organization> orgs, IReadOnlyList<Account> accounts)
    {
        var ids = orgs.Select(o => o.Uuid).ToHashSet(StringComparer.Ordinal);
        return accounts.Where(a => ids.Contains(a.OrganizationId)).ToList();
    }

    /// <summary>
    /// Which of the repaired accounts to end up on. The active account wins when its organization is
    /// in the response: only the active account's write re-primes the live cookie jar, so switching
    /// anywhere else would leave the session that is actually polling on stale cookies.
    /// </summary>
    private Account? MatchedAccount(IReadOnlyList<Organization> orgs)
    {
        var ids = orgs.Select(o => o.Uuid).ToHashSet(StringComparer.Ordinal);
        var active = _accountStore.ActiveAccount;
        if (active is not null && ids.Contains(active.OrganizationId))
        {
            return active;
        }
        return _accountStore.Accounts.FirstOrDefault(a => ids.Contains(a.OrganizationId));
    }

    /// <summary>
    /// What the user is told after a sign-in that repaired stored organizations (R16, R25).
    /// </summary>
    public static string RepairConfirmation(int refreshedCount, bool viewedAccountRepaired)
    {
        var label = refreshedCount == 1 ? "1 organization" : $"{refreshedCount} organizations";
        return viewedAccountRepaired
            ? $"Refreshed {label}."
            : $"Refreshed {label}, but not the one you're viewing - switch to a refreshed one, or paste that account's cookie header.";
    }

    /// <summary>What a manual paste reports on success.</summary>
    public static string SignInConfirmation(string name, int refreshedCount) =>
        refreshedCount <= 0
            ? $"Signed in as {name}."
            : $"Signed in as {name}. " + RepairConfirmation(refreshedCount, viewedAccountRepaired: true);

    // ============================================================================================
    // Login lifecycle (U6).
    // ============================================================================================

    /// <summary>
    /// Open the login window and begin the capture flow. No-ops if a sign-in is already in progress
    /// or a login window is already open (it is just re-focused). Mirrors the Mac <c>presentLogin</c>
    /// guard. The window stays open through capture and org discovery; it closes only on success or
    /// teardown.
    /// </summary>
    public void PresentLogin()
    {
        // No-op while a sign-in is already mid-flight - keyed on LoginState.IsLoginInProgress
        // (signing-in / capturing / org-discovery / picker), NOT SigningIn alone, so the four
        // in-progress kinds match the doc ("no-ops if a sign-in is already in progress") and cannot
        // drift. Re-focus the existing window instead of opening a second (U3).
        if (LoginState.IsLoginInProgress)
        {
            _loginWebView?.Focus();
            return;
        }

        // Belt-and-suspenders: an open login window in any other state is just re-focused.
        if (_loginWebView is not null)
        {
            _loginWebView.Focus();
            return;
        }

        LoginState = LoginState.Idle;
        _hasCapturedSession = false;
        _pendingSessionKey = null;
        _pendingCookieHeader = null;
        CapturedUserAgent = null;
        _loginInitFailed = false;

        var webView = _loginWebViewFactory.Create();
        _loginWebView = webView;

        // Wire every capture trigger and the navigation/popup gates through this manager's funnel.
        webView.NavigationStarting += OnNavigationStarting;
        webView.NavigationCompleted += OnNavigationCompleted;
        webView.HistoryChanged += OnHistoryChanged;
        webView.CookiesObserved += OnCookiesObserved;
        webView.NewWindowRequested += OnNewWindowRequested;
        webView.InitFailed += OnLoginInitFailed;
        webView.Closed += OnWindowClosed;

        // Arm the inactivity timeout BEFORE navigating so an un-loaded window cannot wedge open.
        ArmLoginTimeout();

        webView.Show();
        // Start the cookie poll + load the login page. The fake webview in tests is driven manually.
        webView.StartCookiePolling();
        webView.Navigate("https://claude.ai/login");
    }

    /// <summary>
    /// Tear down the login window and all its timers/tasks. Single teardown path (Mac
    /// <c>stopLoginWindow</c>): cancels org discovery and the timeout, resumes any suspended picker
    /// with null, detaches handlers, and disposes the webview. Does NOT reset the capture guard -
    /// the failure-edge handlers do that explicitly so a success teardown leaves it set.
    /// </summary>
    public void StopLoginWindow()
    {
        // A new window is a new attempt: the same blocked hop is worth recording again.
        _lastBlockedNavigation = null;

        // Resume any suspended org-picker await so a teardown never leaks the awaiting task.
        _orgPicker.CancelPending();

        _timeoutCts?.Cancel();
        _timeoutCts?.Dispose();
        _timeoutCts = null;

        _orgDiscoveryCts?.Cancel();
        _orgDiscoveryCts?.Dispose();
        _orgDiscoveryCts = null;

        var webView = _loginWebView;
        _loginWebView = null;
        if (webView is not null)
        {
            webView.NavigationStarting -= OnNavigationStarting;
            webView.NavigationCompleted -= OnNavigationCompleted;
            webView.HistoryChanged -= OnHistoryChanged;
            webView.CookiesObserved -= OnCookiesObserved;
            webView.NewWindowRequested -= OnNewWindowRequested;
            webView.InitFailed -= OnLoginInitFailed;
            webView.Closed -= OnWindowClosed;
            webView.Dispose();
        }
    }

    /// <summary>
    /// User closed the login window. Mirrors the Mac <c>windowWillClose</c>: while signing in, reset
    /// the capture state so a retry can capture again, return to idle, and run the single teardown
    /// path. Closing during capture cancels the in-flight org discovery with no dangling mutation
    /// (the discovery task observes the cancelled token and bails before touching state).
    /// </summary>
    private void OnWindowClosed()
    {
        // Resetting on cancel is the lockout-prevention scar: a guard left set blocks re-capture. The
        // Mac reset only when signingIn; resetting unconditionally here is strictly safer (a closed
        // window is always a fresh-start point) and never leaves the guard latched after a cancel.
        _hasCapturedSession = false;
        _pendingSessionKey = null;
        _pendingCookieHeader = null;

        // Undo any PrimeCookies done during this (now-abandoned) login: a capture may have clobbered
        // the active account's cookies in the shared jar. Mirror ManualSignIn's jar discipline so a
        // healthy active account is never left signed out by a cancelled add. No-op / clears when
        // there is no active account (first-login cancel).
        _accountStore.RestoreActiveCookies();

        LoginState = LoginState.Idle;
        StopLoginWindow();
    }

    /// <summary>
    /// Reset capture state and reload claude.ai/login in the existing login WebView (the error
    /// surface's "Try again"). Re-arms the inactivity clock so a stale near-expiry timeout cannot
    /// tear the window down mid-retry. Mirrors the Mac <c>retryLogin</c>.
    /// </summary>
    public void RetryLogin()
    {
        _lastBlockedNavigation = null;
        _hasCapturedSession = false;
        _pendingSessionKey = null;
        _pendingCookieHeader = null;
        LoginState = LoginState.Idle;

        // Two shapes where navigating the existing window cannot work, and only a fresh window
        // (whose one-shot CoreWebView2 init runs again) is a real retry:
        // 1. The window's init FAILED: its core is permanently null, so Navigate would only latch
        //    the URL into the pending-navigation slot nothing will ever consume - the overlay hides
        //    and the window sits blank at about:blank forever (the blank-window trap).
        // 2. No window is alive (the user closed it): the old `_loginWebView?.Navigate` was a
        //    silent no-op, leaving "Try again" doing nothing.
        if (_loginInitFailed || _loginWebView is null)
        {
            StopLoginWindow();
            PresentLogin();
            return;
        }

        ArmLoginTimeout();
        _loginWebView.Navigate("https://claude.ai/login");
    }

    /// <summary>
    /// The "Sign in manually" affordance: route the user to the Settings paste floor and tear down
    /// the login window. Mirrors the Mac <c>overlayManualTapped</c>.
    /// </summary>
    public void RequestManualSignIn()
    {
        _lastBlockedNavigation = null;
        OnManualSignInRequested?.Invoke();
        LoginState = LoginState.Idle;
        StopLoginWindow();
    }

    // ---- Blocked navigations (U10, R49, R50) ---------------------------------------------------

    /// <summary>
    /// What the sign-in window tells a user when it cancels a hop to a company identity provider
    /// (R49). Deliberately a fixed string with no host in it: the host is a company's identity
    /// provider and belongs only in the opt-in diagnostics record, never in always-on error text.
    /// </summary>
    public const string SsoBlockedMessage =
        "This sign-in window can't complete single sign-on (SSO). Choose \"Continue with email\" and "
        + "enter the code Claude sends you, or use Sign in manually to paste your cookie header under Settings.";

    /// <summary>The last blocked navigation recorded, so a page retrying the same hop writes once.</summary>
    private (string Host, NavigationBlockKind Kind)? _lastBlockedNavigation;

    /// <summary>
    /// Validates a host before it is ever written to a diagnostics record (R50).
    ///
    /// Anything that is not a plain domain name reads as "(invalid)". The value comes from a page
    /// the app does not control, and the record is meant to be attached to a public issue, so a
    /// malformed host must not be able to smuggle anything into the file under the host key.
    /// </summary>
    public static string HostForDiagnostics(string host)
    {
        if (host.Length == 0 || host.Length > 253)
        {
            return "(invalid)";
        }

        foreach (var label in host.Split('.'))
        {
            if (label.Length is 0 or > 63)
            {
                return "(invalid)";
            }
            foreach (var c in label)
            {
                var ok = c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-';
                if (!ok)
                {
                    return "(invalid)";
                }
            }
        }

        return host;
    }

    /// <summary>The host of a URL, or an empty string when it has none.</summary>
    /// <summary>
    /// Records how organization discovery answered: the status code and which route asked. Never the
    /// body, which carries the address and the organization names.
    /// </summary>
    internal static void EmitOrgDiscoveryStatus(int status, string path) =>
        DiagnosticsLogger.Shared.EmitMilestone("org-discovery-status", () => new Dictionary<string, object?>
        {
            ["status"] = status,
            ["path"] = path,
        });

    /// <summary>The host of a URL, or an empty string when it has none.</summary>
    private static string HostOf(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) ? uri.Host : string.Empty;

    /// <summary>
    /// Records one blocked navigation and, where it matters to the user, says so on screen.
    ///
    /// Before this, a blocked single sign-on redirect cancelled silently and the page just sat
    /// there, which is the complaint in issue #49: nothing said what happened or what to do instead.
    ///
    /// Repeats collapse. A page retrying the same hop fifty times writes one record, not fifty. The
    /// message only appears when the window is still waiting for a sign-in: a block that arrives
    /// after a session was already captured must not replace "finishing sign-in" with an error and a
    /// stale "Try again".
    /// </summary>
    private void RecordBlockedNavigation(string host, NavigationBlockKind kind)
    {
        var safeHost = HostForDiagnostics(host);

        if (_lastBlockedNavigation != (safeHost, kind))
        {
            _lastBlockedNavigation = (safeHost, kind);
            _diagnostics.EmitMilestone("nav-decision", () => new Dictionary<string, object?>
            {
                ["decision"] = "block",
                ["kind"] = NavigationBlockKindName(kind),
                ["host"] = safeHost,
            });
        }

        if (kind is NavigationBlockKind.Link)
        {
            return; // the page's own policy links open in a new window; not a sign-in failure
        }

        if (kind is NavigationBlockKind.PopupMain)
        {
            // A dead popup showing nothing is worse than no popup: close it, so the message below
            // lands on the window the user is actually looking at.
            _loginWebView?.ClosePopup();
        }

        if (LoginState.Kind == LoginStateKind.Idle && !_hasCapturedSession)
        {
            LoginState = LoginState.ErrorWith(SsoBlockedMessage);
        }
    }

    /// <summary>The value written to the diagnostics record for each kind.</summary>
    private static string NavigationBlockKindName(NavigationBlockKind kind) => kind switch
    {
        NavigationBlockKind.Main => "main",
        NavigationBlockKind.PopupMain => "popup-main",
        NavigationBlockKind.Popup => "popup",
        NavigationBlockKind.Link => "link",
        _ => "main"
    };

    /// <summary>
    /// Which kind a refused new-window request is: <see cref="NavigationBlockKind.Popup"/> (a sign-in
    /// attempt, which shows the SSO card) or <see cref="NavigationBlockKind.Link"/> (an ordinary page,
    /// recorded only). Either way the window is refused, as on the Mac.
    ///
    /// The Mac splits these on the navigation type: a clicked link (<c>.linkActivated</c>) is a link,
    /// anything else is a popup. WebView2's <c>NewWindowRequested</c> carries no navigation type, and
    /// <c>IsUserInitiated</c> cannot stand in for it: a "Continue with SSO" button is a user gesture
    /// too. So the split is made on what the request asks for instead. Before this, every refused new
    /// window counted as a popup, so a help or terms link opening in a new tab to a host outside the
    /// allowlist (claude.com, say) showed the SSO error and blocked capture of a sign-in completed
    /// behind it until "Try again".
    ///
    /// A request counts as a sign-in attempt when its host is a well-known identity provider, its
    /// first host label names a sign-in service (a company's own "sso.acme.com" or "login.acme.com"),
    /// its query carries an OAuth/OIDC/SAML/WS-Fed request parameter, or a path segment names a
    /// sign-in endpoint. Anything else, including a URL that does not parse or is not http(s), is a
    /// link.
    /// </summary>
    public static NavigationBlockKind ClassifyBlockedNewWindow(string url)
    {
        if (!Uri.TryCreate(url?.Trim(), UriKind.Absolute, out var uri)
            || (uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeHttp))
        {
            return NavigationBlockKind.Link;
        }

        return IsIdentityProviderHost(uri.Host)
            || HasSignInHostLabel(uri.Host)
            || HasSignInQueryParameter(uri.Query)
            || HasSignInPathSegment(uri.AbsolutePath)
            ? NavigationBlockKind.Popup
            : NavigationBlockKind.Link;
    }

    /// Hosted identity providers a company SSO popup commonly lands on. Exact apex or leading-dot
    /// subdomain only (the same never-a-bare-suffix rule as <see cref="IsAllowedHost"/>).
    private static readonly string[] IdentityProviderDomains =
    {
        "okta.com", "oktapreview.com", "okta-emea.com", "microsoftonline.com", "login.microsoft.com",
        "login.live.com", "onelogin.com", "auth0.com", "workos.com", "pingone.com", "pingidentity.com",
        "duosecurity.com", "jumpcloud.com",
    };

    /// Query parameter names that only an OAuth/OIDC, SAML, or WS-Federation request carries.
    private static readonly HashSet<string> SignInQueryParameters = new(StringComparer.OrdinalIgnoreCase)
    {
        "client_id", "redirect_uri", "response_type", "code_challenge", "SAMLRequest", "RelayState", "wtrealm",
    };

    /// Path segments (and first host labels) that name a sign-in endpoint. Whole segments only, so
    /// "/legal/authors" is not read as "auth".
    private static readonly HashSet<string> SignInPathSegments = new(StringComparer.OrdinalIgnoreCase)
    {
        "oauth", "oauth2", "authorize", "auth", "sso", "saml", "saml2", "adfs", "idp", "oidc",
        "openid-connect", "login", "signin", "sign-in",
    };

    private static bool IsIdentityProviderHost(string host)
    {
        var h = host.TrimEnd('.').ToLowerInvariant();
        foreach (var domain in IdentityProviderDomains)
        {
            if (h == domain || h.EndsWith("." + domain, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    /// The first label only, and only when there is a registered domain under it, so a company IdP
    /// on its own subdomain ("sso.acme.com") counts but a bare "login.com" does not.
    private static bool HasSignInHostLabel(string host)
    {
        var labels = host.TrimEnd('.').Split('.');
        return labels.Length >= 3 && SignInPathSegments.Contains(labels[0]);
    }

    private static bool HasSignInQueryParameter(string query)
    {
        foreach (var pair in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var name = pair.Split('=', 2)[0];
            if (SignInQueryParameters.Contains(Uri.UnescapeDataString(name)))
            {
                return true;
            }
        }

        return false;
    }

    private static bool HasSignInPathSegment(string path)
    {
        foreach (var segment in path.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (SignInPathSegments.Contains(Uri.UnescapeDataString(segment)))
            {
                return true;
            }
        }

        return false;
    }

    // ---- Timeout ------------------------------------------------------------------------------

    /// <summary>
    /// Arm (or re-arm) the inactivity timeout. Re-armed on every navigation so an actively
    /// signing-in user is never timed out mid-flow (Mac <c>armLoginTimeout</c>). On expiry, every
    /// pending bit of state is reset and the window torn down (a persistent Cloudflare challenge ends
    /// as a terminal idle, not an infinite spinner - the error surface stays only if a discovery
    /// failure set it).
    /// </summary>
    private void ArmLoginTimeout()
    {
        _timeoutCts?.Cancel();
        _timeoutCts?.Dispose();
        var cts = new CancellationTokenSource();
        _timeoutCts = cts;

        LastTimeoutTask = RunTimeoutAsync(cts.Token);
    }

    private async Task RunTimeoutAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(_loginTimeout, token).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            return; // Re-armed or torn down; this timer is superseded.
        }

        if (token.IsCancellationRequested)
        {
            return;
        }

        _orgDiscoveryCts?.Cancel();
        _hasCapturedSession = false;
        _pendingSessionKey = null;
        _pendingCookieHeader = null;
        // Same jar restore as the cancel path: a timeout after capture must not leave the active
        // account's cookies clobbered by the abandoned add.
        _accountStore.RestoreActiveCookies();
        LoginState = LoginState.Idle;
        StopLoginWindow();
    }

    // ---- WebView event funnel -----------------------------------------------------------------

    /// <summary>
    /// Main-frame navigation gate. Cancels (returns false) any navigation outside the exact-domain
    /// claude.ai allowlist plus the about: bootstrap frames. The real <see cref="ILoginWebView"/>
    /// implementation sets <c>e.Cancel = !allowed</c>.
    /// </summary>
    private bool OnNavigationStarting(string url)
    {
        if (ShouldAllow(url))
        {
            return true;
        }

        RecordBlockedNavigation(HostOf(url), NavigationBlockKind.Main);
        return false;
    }

    private void OnNavigationCompleted(NavigationCompletedInfo info)
    {
        // Capture the WebView2 UA exactly once, after the first completed navigation. Asserted
        // non-empty: an empty UA would make the U3 poll's UA-match impossible.
        if (CapturedUserAgent is null && !string.IsNullOrEmpty(info.UserAgent))
        {
            CapturedUserAgent = info.UserAgent;
        }

        // Check cookies on every page load and reset the inactivity timeout (proves the user is
        // still actively signing in). Mirrors the Mac didFinish.
        TryCaptureFromCookies(info.Cookies);
        ArmLoginTimeout();
    }

    /// <summary>
    /// SPA route changes that do not fire a full navigation (Mac KVO on <c>url</c>): re-read cookies
    /// so a session cookie that appears only after a client-side route change is still captured.
    /// </summary>
    private void OnHistoryChanged(IReadOnlyList<CapturedCookie> cookies) => TryCaptureFromCookies(cookies);

    /// The 0.2s cookie poll and the cookie-store observer both route here (Mac poll + observer).
    private void OnCookiesObserved(IReadOnlyList<CapturedCookie> cookies) => TryCaptureFromCookies(cookies);

    /// <summary>
    /// A <c>window.open()</c> from the login page (Google "Continue with Google"). Allow it into the
    /// hosted popup WebView only when <see cref="AllowsOAuthPopup"/> passes; the popup then gets its
    /// own navigation gate enforcing <see cref="ShouldAllow"/>-equivalent allowlisting via
    /// <see cref="AllowsOAuthPopup"/> on each subsequent navigation. Returns the decision to the
    /// webview shell, which creates or refuses the popup.
    /// </summary>
    private NewWindowDecision OnNewWindowRequested(string url)
    {
        if (!AllowsOAuthPopup(url))
        {
            // Still refused either way; the classification only decides whether the SSO card shows.
            RecordBlockedNavigation(HostOf(url), ClassifyBlockedNewWindow(url));
            return NewWindowDecision.Block;
        }

        // The popup's own navigations must stay inside the allowlist so it cannot wander after the
        // OAuth bootstrap. Hand the shell the per-navigation gate to wire onto the popup WebView.
        return NewWindowDecision.AllowWithGate(OnPopupNavigationStarting);
    }

    /// <summary>
    /// The popup's own navigation gate. A block here used to show nothing at all: the popup went
    /// blank and the user was left with two windows and no explanation.
    /// </summary>
    private bool OnPopupNavigationStarting(string url)
    {
        if (AllowsOAuthPopup(url))
        {
            return true;
        }

        RecordBlockedNavigation(HostOf(url), NavigationBlockKind.PopupMain);
        return false;
    }

    /// <summary>
    /// The login WebView2 (or its OAuth popup) failed to initialize. Surface a visible error with a
    /// retry instead of a silent blank window / dead button (U6/U8). Routes through the shared
    /// failure handler so the capture guard is reset and the window stays open showing the error
    /// (Try again / Sign in manually); it is not torn down here.
    /// </summary>
    private void OnLoginInitFailed(string message)
    {
        // Remember that THIS window's init is dead before surfacing the error: the window stays
        // open showing the error + retry (the HandleOrgDiscoveryFailure contract), but a retry must
        // re-present a fresh window rather than navigate this one (see RetryLogin).
        _loginInitFailed = true;
        HandleOrgDiscoveryFailure(message);
    }

    // ============================================================================================
    // Capture funnel (U6).
    // ============================================================================================

    /// <summary>
    /// Single capture funnel (Mac <c>captureSessionCookie</c>). Every trigger (poll, history change,
    /// navigation, popup close) routes its cookie set through here so the <see cref="_hasCapturedSession"/>
    /// guard enforces exactly-once capture. Skipped while an error card is shown (Mac
    /// <c>!loginState.isError</c>): a cancelled/failed login leaves the session cookie live and the
    /// poll armed; without this gate the next tick would re-capture and re-launch discovery, silently
    /// undoing the user's Cancel. <see cref="RetryLogin"/> clears the error first, so the
    /// user-initiated retry path still captures.
    /// </summary>
    internal void TryCaptureFromCookies(IReadOnlyList<CapturedCookie> cookies)
    {
        if (_hasCapturedSession || LoginState.IsError)
        {
            return;
        }

        var session = cookies.FirstOrDefault(IsCapturableSessionCookie);
        if (session is null)
        {
            return;
        }

        _diagnostics.EmitMilestone("session-cookie-captured", () => new Dictionary<string, object?>
        {
            ["domain"] = session.Domain,
            ["isSecure"] = session.IsSecure,
        });

        HandleCookieCaptured(session, cookies);
    }

    /// <summary>
    /// A capturable session cookie: name <c>sessionKey</c>, exact claude.ai domain, Secure, path
    /// <c>/</c>. Mirrors the Mac <c>isSessionCookie</c> + <c>handleCookieCaptured</c> validation
    /// (a non-Secure or non-root-path cookie is rejected, never captured).
    /// </summary>
    internal static bool IsCapturableSessionCookie(CapturedCookie cookie) =>
        cookie.Name == "sessionKey"
        && IsSessionCookieDomain(cookie.Domain)
        && cookie.IsSecure
        && cookie.Path == "/";

    private void HandleCookieCaptured(CapturedCookie sessionCookie, IReadOnlyList<CapturedCookie> allCookies)
    {
        if (_hasCapturedSession)
        {
            return;
        }

        _hasCapturedSession = true;
        _pendingSessionKey = sessionCookie.Value;

        // Build the full .claude.ai Cookie header so the org-discovery request carries the whole set
        // (including HttpOnly __cf_bm), not sessionKey alone. Mac handleCookieCaptured enumeration.
        var header = string.Join("; ",
            allCookies
                .Where(c => IsClaudeCookieDomain(c.Domain))
                .Select(c => $"{c.Name}={c.Value}"));
        _pendingCookieHeader = string.IsNullOrEmpty(header) ? null : header;

        LoginState = LoginState.SigningIn;
        DebugLog("Session cookie captured");

        // The cookie poll is deliberately left armed (its closure no-ops on the guard). If discovery
        // fails (the failure handler resets the guard) or the user taps Try again, the poll backstop
        // resumes automatically without being re-created. Mirrors the Mac note.

        // Prime the shared jar so the discovery request and the first poll carry the captured set.
        if (_pendingSessionKey is { } key)
        {
            _accountStore.PrimeCookies(key, _pendingCookieHeader);
        }

        _orgDiscoveryCts?.Cancel();
        _orgDiscoveryCts?.Dispose();
        var cts = new CancellationTokenSource();
        _orgDiscoveryCts = cts;
        LastDiscoveryTask = DiscoverOrganizationsAsync(cts.Token);
    }

    // ============================================================================================
    // Org discovery (U7).
    // ============================================================================================

    /// <summary>
    /// Discover organizations after capture, choose one via the pure <see cref="SelectOrg"/> rule
    /// (never <c>orgs[0]</c>), add or re-auth the account, and close the window ONLY on success.
    /// Every failure edge (401/403, empty orgs, network/decode error, picker cancel, a secret-blob
    /// write failure, any unexpected throw in the commit tail) surfaces a visible error and resets
    /// the capture guard so a retry can capture again. This task is fire-and-forget from the capture
    /// funnel with no observer, so an uncaught throw here would not crash - it would leave the
    /// signing-in overlay up until the inactivity timeout with no message at all. Mirrors the Mac
    /// <c>fetchOrganizationId</c>.
    /// </summary>
    internal async Task DiscoverOrganizationsAsync(CancellationToken token)
    {
        var sessionKey = _pendingSessionKey;
        if (sessionKey is null)
        {
            LoginState = LoginState.Idle;
            StopLoginWindow();
            return;
        }

        LoginState = LoginState.OrgDiscovery;

        // Nothing may be polling while this rewrites the jar (R22). The resume in the finally below
        // covers every exit, including the ones that throw.
        await SuspendPollingAsync().ConfigureAwait(true);
        try
        {
            await DiscoverOrganizationsCoreAsync(sessionKey, token).ConfigureAwait(true);
        }
        finally
        {
            OnResumePolling?.Invoke();
        }
    }

    private async Task SuspendPollingAsync()
    {
        if (OnSuspendPolling is { } suspend)
        {
            await suspend().ConfigureAwait(true);
        }
    }

    private async Task DiscoverOrganizationsCoreAsync(string sessionKey, CancellationToken token)
    {
        IReadOnlyList<Organization> orgs;
        try
        {
            orgs = await _api.GetOrganizationsAsync(token).ConfigureAwait(true);
            EmitOrgDiscoveryStatus(200, "webview");
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            // Window closed / timed out / superseded mid-request: the teardown owns state. Do not
            // fight it by re-driving login state here.
            // Filtered on OUR token: an HTTP request timeout (ClaudeApi's own 30s deadline) also
            // throws TaskCanceledException, but with this token un-cancelled and no teardown coming.
            // Swallowing that left the spinner up until the inactivity timer, the capture guard set,
            // and the shared jar primed with the new identity while polling resumed. It falls to the
            // generic catch below instead, which restores the active account's cookies.
            return;
        }
        catch (ClaudeAuthException authEx)
        {
            EmitOrgDiscoveryStatus(authEx.StatusCode, "webview");
            HandleOrgDiscoveryFailure("Sign-in failed. Please try again.");
            return;
        }
        catch (Exception)
        {
            HandleOrgDiscoveryFailure("Connection error. Please try again.");
            return;
        }

        if (token.IsCancellationRequested)
        {
            return;
        }

        // Everything from here to the success notification runs inside one guard. This task has no
        // observer (LastDiscoveryTask is awaited only by tests), so any throw in this tail - a
        // secret-blob write failure in UpsertAccount, or anything unexpected - would otherwise fault
        // silently and leave LoginState stuck at OrgDiscovery / Picker with the overlay spinning.
        try
        {
            if (orgs.Count == 0)
            {
                HandleOrgDiscoveryFailure("No Claude organizations were found for this account. A Pro or Max plan may be required.");
                return;
            }

            Organization chosenOrg;
            switch (SelectOrg(orgs, _accountStore.Accounts))
            {
                case { Kind: OrgSelectionKind.Single } single:
                    chosenOrg = single.Org!;
                    break;

                case { Kind: OrgSelectionKind.AllAlreadyAdded } all:
                    // Every organization in the response is already stored, so there is nothing to
                    // choose: this sign-in repairs all of them at once (R16, F2).
                    await RepairAllStoredOrganizationsAsync(all.Orgs!, sessionKey, token).ConfigureAwait(true);
                    return;

                case { Kind: OrgSelectionKind.NeedsChoice } choice:
                {
                    LoginState = LoginState.Picker;
                    // Discovery already ran on the primed new-identity jar; the org picker is a user-paced
                    // wait. Restore the active account's cookies for its duration so its poll is undisturbed
                    // (the chosen account re-primes on commit via UpsertAccount/SwitchTo). On cancel/timeout
                    // the teardown paths restore again; on pick-cancel HandleOrgDiscoveryFailure does.
                    _accountStore.RestoreActiveCookies();
                    // The picker waits on a person and can sit open for minutes. Polling resumes for
                    // that wait and is suspended again once the choice triggers the next write.
                    OnResumePolling?.Invoke();
                    Organization? picked;
                    try
                    {
                        picked = await _orgPicker.PickAsync(choice.Orgs!, token).ConfigureAwait(true);
                    }
                    catch (OperationCanceledException) when (token.IsCancellationRequested)
                    {
                        return; // Teardown resumed the picker; do not re-drive state.
                    }
                    finally
                    {
                        await SuspendPollingAsync().ConfigureAwait(true);
                    }

                    if (token.IsCancellationRequested)
                    {
                        return;
                    }

                    if (picked is null)
                    {
                        HandleOrgDiscoveryFailure("Sign-in cancelled.");
                        return;
                    }

                    chosenOrg = picked;
                    break;
                }

                default:
                    HandleOrgDiscoveryFailure("Connection error. Please try again.");
                    return;
            }

            if (token.IsCancellationRequested)
            {
                return;
            }

            var resolvedEmail = await ResolveEmailAsync(orgs, token).ConfigureAwait(true);
            if (token.IsCancellationRequested)
            {
                return;
            }
            var email = resolvedEmail ?? $"Account {_accountStore.Accounts.Count + 1}";

            var account = new Account
            {
                Email = email,
                SessionKey = sessionKey,
                OrganizationId = chosenOrg.Uuid,
                // Kept so two organizations of one login can be told apart in every list (R20).
                OrganizationName = chosenOrg.DisplayName,
                AllCookieHeader = _pendingCookieHeader,
                // Persist the session UA so a cold-start restore seeds the poll transport with the same
                // UA the login captured (U1/U2). Null until the first NavigationCompleted captures it.
                UserAgent = CapturedUserAgent,
                // A brand-new account takes its plan straight from the organization that was just
                // fetched; an account that already existed is refreshed through UpdatePlan below, which
                // is where the plan-change rule lives (R9).
                RateLimitTier = chosenOrg.RateLimitTier,
                Capabilities = chosenOrg.Capabilities,
                BillingType = chosenOrg.BillingType,
                PlanUpdatedAt = DateTimeOffset.UtcNow,
            };

            // Whether this organization already had an account decides whether it counts as repaired
            // in the confirmation below: a brand-new add is not a repair.
            var existedBefore = _accountStore.Accounts.Any(a => a.OrganizationId == chosenOrg.Uuid);

            // UpsertAccount returns false ONLY when a genuinely new account would exceed the account
            // limit; a duplicate org id updates the existing account in place (re-auth, no lockout),
            // so repairing an account at the limit always succeeds (R58).
            // A secret-blob write failure throws AccountPersistenceException (caught below) with
            // nothing changed in the store.
            if (!_accountStore.UpsertAccount(account))
            {
                HandleOrgDiscoveryFailure("Account limit reached.");
                return;
            }

            // Activate whichever account now owns this org (new id, or the pre-existing one on re-auth),
            // but ONLY when it is not already active. UpsertAccount already activates+bumps the active
            // account on an in-place re-auth, and auto-activates the very first account; calling SwitchTo
            // again would double-bump the request generation and superfluously re-activate (issue #18).
            // Mac parity: fetchOrganizationId switches to the logged-in account (incl. a re-auth of a
            // non-active one); the only change here is dropping the redundant second bump.
            var owning = _accountStore.Accounts.FirstOrDefault(a => a.OrganizationId == chosenOrg.Uuid);
            if (owning is not null)
            {
                // Refresh the stored plan from this response. On a re-authentication this is the only
                // thing that updates it, and it is where a plan change discards a measurement taken
                // on the old plan (R9, R56).
                _accountStore.UpdatePlan(owning.Id, chosenOrg.RateLimitTier, chosenOrg.Capabilities, chosenOrg.BillingType);
            }

            // Every OTHER stored organization under this login is revived by the same credentials.
            // Done before the switch below, so the switch stays the last thing to touch the jar.
            var siblings = RefreshSiblings(orgs, chosenOrg.Uuid, sessionKey, resolvedEmail);

            // A row still carrying "Account N" gets the real address; a row that already has one
            // keeps it (R21).
            if (owning is not null)
            {
                RepairPlaceholderEmail(owning, resolvedEmail);
            }

            if (owning is not null && owning.Id != _accountStore.ActiveAccountId)
            {
                _accountStore.SwitchTo(owning.Id);
            }

            ReportRepair(siblings, signedInOrgRepaired: existedBefore);

            // Success: clear pending state, close the window, notify.
            _pendingSessionKey = null;
            _pendingCookieHeader = null;
            LoginState = LoginState.Active;
            StopLoginWindow();
            OnAuthSuccess?.Invoke();
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            // Teardown owns state after a cancel; never re-drive it from here. Only a cancel of OUR
            // token means a teardown is coming; any other cancellation (a request timeout) is a
            // failure and lands in the generic catch below.
            return;
        }
        catch (AccountPersistenceException)
        {
            HandleOrgDiscoveryFailure("Could not save sign-in data. Check that your user folder is writable, then try again.");
        }
        catch (Exception)
        {
            HandleOrgDiscoveryFailure("Sign-in could not be completed. Please try again.");
        }
    }

    /// <summary>
    /// Every org-discovery failure edge: clear pending credentials, RESET the capture guard (so the
    /// still-live session cookie can be re-captured on retry - the lockout-prevention scar), and move
    /// to the error state. The window stays open showing the error; it is NOT torn down here. Mirrors
    /// the Mac <c>handleOrgDiscoveryFailure</c>.
    /// </summary>
    private void HandleOrgDiscoveryFailure(string message)
    {
        _pendingSessionKey = null;
        _pendingCookieHeader = null;
        _hasCapturedSession = false;
        // Discovery failed after the capture primed the jar with the (possibly invalid) new identity.
        // Restore the active account's cookies so it keeps polling normally behind the error card,
        // instead of being clobbered until the user retries or restarts (mirrors ManualSignIn).
        _accountStore.RestoreActiveCookies();
        LoginState = LoginState.ErrorWith(message);
    }

    /// <summary>
    /// Prefer the enriched org's <c>email_address</c>; fall back to the first non-empty one. Mirrors
    /// the Mac <c>extractEmail</c> first pass (the raw-JSON fallback is unnecessary here since the
    /// decoder already surfaces <c>EmailAddress</c>). Shared by the WebView (here) and manual-paste
    /// (<see cref="ManualSignIn"/>) paths so the two cannot diverge again (they did once, issue #16).
    /// </summary>
    internal static string? ExtractEmail(IReadOnlyList<Organization> orgs)
    {
        foreach (var org in orgs)
        {
            if (!string.IsNullOrEmpty(org.EmailAddress))
            {
                return org.EmailAddress;
            }
        }

        return null;
    }

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[AuthManager] {message}");
}

// ================================================================================================
// Pure-value supporting types.
// ================================================================================================

/// <summary>
/// The outcome of <see cref="AuthManager.SelectOrg"/> (pattern #6). A discriminated value so the
/// call site supplies its own imperative shell (a WPF picker vs a manual-paste result) - the rule
/// itself stays pure and unit-testable.
/// </summary>
public enum OrgSelectionKind
{
    Single,

    /// <summary>Every organization in the response already has a stored account: there is nothing to
    /// choose, only accounts to repair.</summary>
    AllAlreadyAdded,

    NeedsChoice
}

/// <summary>Result of the pure org-selection rule. See <see cref="AuthManager.SelectOrg"/>.</summary>
public sealed record OrgSelection
{
    public OrgSelectionKind Kind { get; private init; }

    /// Non-null for <see cref="OrgSelectionKind.Single"/>.
    public Organization? Org { get; private init; }

    /// <summary>
    /// The organizations from the response, in the order they arrived. Set for
    /// <see cref="OrgSelectionKind.NeedsChoice"/> (what to show in the picker) and for
    /// <see cref="OrgSelectionKind.AllAlreadyAdded"/> (what to repair).
    /// </summary>
    public IReadOnlyList<Organization>? Orgs { get; private init; }

    public static OrgSelection Single(Organization org) =>
        new() { Kind = OrgSelectionKind.Single, Org = org };

    public static OrgSelection AllAlreadyAdded(IReadOnlyList<Organization> orgs) =>
        new() { Kind = OrgSelectionKind.AllAlreadyAdded, Orgs = orgs };

    public static OrgSelection NeedsChoice(IReadOnlyList<Organization> orgs) =>
        new() { Kind = OrgSelectionKind.NeedsChoice, Orgs = orgs };
}

/// <summary>
/// A cookie observed in the login WebView, reduced to the fields the capture funnel needs. The real
/// <see cref="ILoginWebView"/> maps <c>CoreWebView2Cookie</c> onto this; tests construct it directly.
/// The cookie <c>Value</c> is a secret and is never logged.
/// </summary>
public sealed record CapturedCookie
{
    public required string Name { get; init; }
    public required string Value { get; init; }
    public required string Domain { get; init; }
    public string Path { get; init; } = "/";
    public bool IsSecure { get; init; }
    public bool IsHttpOnly { get; init; }
}

/// <summary>Payload of a completed navigation: the cookie snapshot plus the session UA to capture.</summary>
public sealed record NavigationCompletedInfo
{
    public required IReadOnlyList<CapturedCookie> Cookies { get; init; }

    /// The WebView2 session User-Agent (<c>CoreWebView2.Settings.UserAgent</c>), captured once.
    public string? UserAgent { get; init; }
}

/// <summary>
/// Where a blocked navigation came from (R50). Written verbatim into the diagnostics record, and
/// what decides whether the user sees anything: the page's own policy links opening in a new window
/// are recorded and otherwise ignored, while a blocked main-frame or popup hop is what the single
/// sign-on message exists for.
///
/// The Mac also distinguishes a blocked sub-frame. WebView2 raises frame navigations on a separate
/// event this port does not subscribe to, so that case cannot arise here; recorded as a deliberate
/// difference rather than carried as a gap.
/// </summary>
public enum NavigationBlockKind
{
    /// The sign-in window's own page tried to go somewhere it is not allowed.
    Main,

    /// A page inside the hosted sign-in popup tried to go somewhere it is not allowed.
    PopupMain,

    /// A new window that looks like a sign-in attempt was requested for a host that is not allowed.
    Popup,

    /// A new window for an ordinary page (a help or terms link) was requested for a host that is not
    /// allowed. Recorded, never shown. WebView2 gives no navigation type for a new window, so the
    /// split from <see cref="Popup"/> is made by <see cref="AuthManager.ClassifyBlockedNewWindow"/>.
    Link,
}

/// <summary>The decision for a <c>window.open()</c>/<c>NewWindowRequested</c> from the login page.</summary>
public sealed record NewWindowDecision
{
    public bool Allowed { get; private init; }

    /// When allowed, the per-navigation gate the shell must wire onto the popup WebView so it cannot
    /// wander outside the OAuth allowlist after the bootstrap.
    public Func<string, bool>? PopupNavigationGate { get; private init; }

    public static readonly NewWindowDecision Block = new() { Allowed = false };

    public static NewWindowDecision AllowWithGate(Func<string, bool> gate) =>
        new() { Allowed = true, PopupNavigationGate = gate };
}

/// <summary>
/// The login-window abstraction over a real WebView2 + host window. Lets the
/// <see cref="AuthManager"/> state machine, capture funnel, timeout, and org discovery be unit-tested
/// with a fake that raises the events on demand - no WebView2 process required. The WPF
/// <c>LoginWindow</c> (this folder's .xaml.cs) implements it: ephemeral InPrivate environment,
/// isolated user-data folder, finally/Dispose deletion, <c>GetCookiesAsync(null)</c> on a 0.2s timer,
/// and the navigation/popup gates.
/// </summary>
public interface ILoginWebView : IDisposable
{
    /// Show the login window.
    void Show();

    /// Re-focus an already-open window (the Mac re-focus-on-re-present path).
    void Focus();

    /// Navigate the main frame to <paramref name="url"/>.
    void Navigate(string url);

    /// Begin polling cookies on the 0.2s timer while the window is open.
    void StartCookiePolling();

    /// <summary>
    /// Close the hosted sign-in popup, if one is open. Called when a navigation inside it is
    /// blocked: a popup left showing a blank page with a dead "Try again" is worse than no popup
    /// (R49).
    /// </summary>
    void ClosePopup();

    /// <summary>
    /// Main-frame navigation gate. The handler returns true to allow, false to cancel; the
    /// implementation sets <c>e.Cancel</c> accordingly. Carries the target URL.
    /// </summary>
    event Func<string, bool> NavigationStarting;

    /// A navigation completed: cookie snapshot + the session UA to capture once.
    event Action<NavigationCompletedInfo> NavigationCompleted;

    /// An SPA route change (no full navigation): cookie snapshot.
    event Action<IReadOnlyList<CapturedCookie>> HistoryChanged;

    /// A cookie poll tick or store-change observation: cookie snapshot.
    event Action<IReadOnlyList<CapturedCookie>> CookiesObserved;

    /// A <c>window.open()</c> request; the handler returns the allow/block decision + popup gate.
    event Func<string, NewWindowDecision> NewWindowRequested;

    /// <summary>
    /// The WebView2 (or its OAuth popup) failed to initialize (runtime/profile error). Carries a
    /// user-facing message. Without this the window stayed blank with no error and no retry while the
    /// cookie poll spun (U6/U8). The host raises it once; the manager surfaces an error+retry surface.
    /// </summary>
    event Action<string> InitFailed;

    /// The user closed the window (the cancel path).
    event Action Closed;
}

/// <summary>
/// Creates a fresh ephemeral login WebView per sign-in attempt. The production factory builds a real
/// WebView2 with an isolated InPrivate user-data folder (deleted on Dispose, with a startup sweep of
/// stale login UDFs); tests inject a fake.
/// </summary>
public interface ILoginWebViewFactory
{
    ILoginWebView Create();
}

/// <summary>
/// Presents the multi-org picker and awaits the user's choice (U7). Returns null on cancel. The
/// production implementation hosts <c>OrgPickerView</c>; a teardown calls <see cref="CancelPending"/>
/// so a suspended pick is resumed (with null) instead of leaking the awaiting task - the
/// resume-once contract from the Mac <c>resumeOrgPicker</c>.
/// </summary>
public interface IOrgPicker
{
    Task<Organization?> PickAsync(IReadOnlyList<Organization> orgs, CancellationToken cancellationToken);

    /// Resume any in-flight pick with null (cancel). Idempotent; a no-op when none is pending.
    void CancelPending();
}
