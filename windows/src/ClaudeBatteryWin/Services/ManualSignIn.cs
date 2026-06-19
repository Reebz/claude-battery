using System.Diagnostics;
using ClaudeBatteryWin.Models;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The manual-cookie sign-in floor (U11), the Windows port of the Mac
/// <c>AuthManager.manualSignIn</c> / <c>parsePastedCredentials</c> / <c>discoverAndAddManualAccount</c>
/// (Services/AuthManager.swift, "the universal paste floor"). It is the path that works without the
/// WebView2 login window, so it covers accounts the embedded flow cannot complete (Google-federated,
/// passkey-only) - the same role it plays on the Mac.
///
/// The actual WebView2 login lives in the (not-yet-written) U6/U7 AuthManager. This unit owns ONLY
/// the manual path, built on the same primitives the AuthManager will reuse: the shared
/// <see cref="IClaudeApi"/> for org discovery and the <see cref="AccountStore"/> for add/re-auth
/// and cookie priming. The pure validation (<see cref="ParsePastedCredentials"/>,
/// <see cref="Sanitize"/>, <see cref="SelectOrg"/>) is static so it unit-tests without any network
/// or registry, and the async router (<see cref="SignInAsync"/>) drives the picker contract.
///
/// <para>
/// <b>Windows-added validation the Mac did not need.</b> Beyond the Mac's parse, the pasted value is
/// first run through <see cref="Sanitize"/> to STRIP any CR/LF before use. On .NET a CR/LF inside a
/// cookie value is a header-injection / request-splitting vector when the value is later replayed
/// through <c>HttpClient</c>; the Mac's Foundation cookie path tolerates it differently, but here we
/// remove it up front. Domain scope is enforced by the AccountStore's cookie priming, which only
/// ever injects to <c>.claude.ai</c>.
/// </para>
/// </summary>
public sealed class ManualSignIn
{
    private readonly IClaudeApi _api;
    private readonly AccountStore _accountStore;

    /// <summary>
    /// Context stashed between <see cref="SignInAsync"/> and <see cref="CompleteWithChosenOrg"/>
    /// when a paste resolves to multiple orgs with no existing match and the user must pick one
    /// (the Mac <c>pendingManualSignIn</c>). Cleared on every fresh <see cref="SignInAsync"/> so a
    /// stale credential is never retained.
    /// </summary>
    private (string SessionKey, string? CookieHeader, string Email)? _pending;

    public ManualSignIn(IClaudeApi api, AccountStore accountStore)
    {
        _api = api ?? throw new ArgumentNullException(nameof(api));
        _accountStore = accountStore ?? throw new ArgumentNullException(nameof(accountStore));
    }

    // MARK: - Pure validation (static, no I/O)

    /// <summary>
    /// Strip every CR and LF from a pasted credential before any further use. A cookie value
    /// containing a CRLF is a header-injection vector once replayed through <c>HttpClient</c>; the
    /// Mac did not strip (its cookie path differs), so this is a Windows-added pre-step. Pure.
    /// </summary>
    public static string Sanitize(string raw)
        => raw.Replace("\r", string.Empty).Replace("\n", string.Empty);

    /// <summary>
    /// Parse a pasted credential into a <c>sessionKey</c> and (when present) the full cookie header.
    /// Returns null when no usable, structurally-reasonable <c>sessionKey</c> can be extracted.
    /// Pure + static for unit testing. Ported VERBATIM from the Mac
    /// <c>AuthManager.parsePastedCredentials</c>, with the CRLF sanitize applied first:
    /// <list type="bullet">
    ///   <item>A full cookie header (contains a <c>sessionKey=...</c> pair) keeps the whole header
    ///   when other cookies are present (it carries the HttpOnly <c>__cf_bm</c>); a lone
    ///   <c>sessionKey=...</c> is treated as a bare key (no header).</item>
    ///   <item>A bare token (no <c>;</c> and no whitespace) is taken as the sessionKey.</item>
    ///   <item>Anything else (a non-empty value for the sessionKey is required) -> null.</item>
    /// </list>
    /// </summary>
    public static ParsedCredentials? ParsePastedCredentials(string raw)
    {
        // CRLF is stripped before parsing so neither the returned sessionKey nor the cookie header
        // can carry an embedded newline (header-injection guard).
        var trimmed = Sanitize(raw).Trim();
        if (trimmed.Length == 0)
        {
            return null;
        }

        // Full cookie header: contains a "sessionKey=..." pair somewhere in the string.
        const string keyPrefix = "sessionKey=";
        if (trimmed.Contains(keyPrefix, StringComparison.Ordinal))
        {
            foreach (var pair in trimmed.Split(';'))
            {
                var kv = pair.Trim();
                if (!kv.StartsWith(keyPrefix, StringComparison.Ordinal))
                {
                    continue;
                }

                var value = kv[keyPrefix.Length..];
                if (value.Length == 0)
                {
                    return null; // sessionKey present but empty: not usable
                }

                // Keep the full header when other cookies are present (carries HttpOnly __cf_bm);
                // otherwise treat it as a bare key. Mirrors the Mac hasOtherCookies branch.
                var hasOtherCookies = trimmed.Contains(';');
                return new ParsedCredentials(value, hasOtherCookies ? trimmed : null);
            }

            return null;
        }

        // Bare sessionKey: a single token with no cookie syntax or whitespace.
        if (!trimmed.Contains(';') && !trimmed.Any(char.IsWhiteSpace))
        {
            return new ParsedCredentials(trimmed, null);
        }

        return null;
    }

    /// <summary>
    /// Pure org-selection rule (never blindly take orgs[0]; the Mac multi-org 100%/100% bug),
    /// shared with the WebView path. Single org -> take it; else if an existing account's org is in
    /// the list -> auto-select that match; else the caller shows a picker. Mirrors the Mac
    /// <c>AuthManager.selectOrg</c>.
    /// </summary>
    public static OrgSelection SelectOrg(IReadOnlyList<Organization> orgs, IReadOnlyList<Account> accounts)
    {
        if (orgs.Count == 1)
        {
            return OrgSelection.Single(orgs[0]);
        }

        var existing = accounts.FirstOrDefault(acct => orgs.Any(o => o.Uuid == acct.OrganizationId));
        if (existing is not null)
        {
            var match = orgs.First(o => o.Uuid == existing.OrganizationId);
            return OrgSelection.AutoMatched(match);
        }

        return OrgSelection.NeedsChoice(orgs);
    }

    // MARK: - Async router (drives org discovery + add/re-auth + the picker contract)

    /// <summary>
    /// Validate a pasted credential and add/re-auth the account, mirroring the Mac
    /// <c>manualSignIn</c> + <c>discoverAndAddManualAccount</c>. Invalid input short-circuits before
    /// any network call. A 401/403 returns <see cref="ManualSignInResult.AuthFailedResult"/> with
    /// <c>SuggestFullHeader</c> set when only a bare key was pasted (a bare key is usually blocked by
    /// Cloudflare for the missing HttpOnly <c>__cf_bm</c>). A multi-org no-match result stashes the
    /// pending context and returns <see cref="ManualSignInResult.NeedsOrgChoiceResult"/> for the
    /// picker; <see cref="CompleteWithChosenOrg"/> finishes it.
    ///
    /// Cookie-jar safety mirrors the Mac: the AccountStore only mutates the shared jar on a
    /// successful add/re-auth (its <c>UpsertAccount</c> + <c>SwitchTo</c> path); a failed attempt
    /// performs no jar mutation here, so a healthy active account is never clobbered by a failed
    /// add. (The Mac had to snapshot-and-restore because its <c>activateCookies</c> ran before
    /// discovery; here discovery uses the already-primed active jar and only a successful upsert
    /// re-primes, so there is nothing to restore.)
    /// </summary>
    public async Task<ManualSignInResult> SignInAsync(string pasted, CancellationToken cancellationToken = default)
    {
        _pending = null;

        var parsed = ParsePastedCredentials(pasted);
        if (parsed is null)
        {
            return ManualSignInResult.InvalidInput;
        }

        IReadOnlyList<Organization> orgs;
        try
        {
            orgs = await _api.GetOrganizationsAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (ClaudeAuthException)
        {
            // 401/403. A bare key (no full header) most often means a missing HttpOnly __cf_bm
            // (Cloudflare block): steer the user to paste the full header. Pattern #5: the server is
            // authoritative; we do not guess validity client-side.
            return ManualSignInResult.AuthFailed(suggestFullHeader: parsed.CookieHeader is null);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            return ManualSignInResult.ConnectionError;
        }

        if (orgs.Count == 0)
        {
            return ManualSignInResult.NoOrganizations;
        }

        var email = ExtractEmail(orgs) ?? $"Account {_accountStore.Accounts.Count + 1}";

        var selection = SelectOrg(orgs, _accountStore.Accounts);
        if (selection.Kind == OrgSelectionKind.NeedsChoice)
        {
            _pending = (parsed.SessionKey, parsed.CookieHeader, email);
            return ManualSignInResult.NeedsOrgChoice(selection.Choices!);
        }

        return AddOrReactivate(selection.Org!, parsed.SessionKey, parsed.CookieHeader, email);
    }

    /// <summary>
    /// Finish a manual sign-in after the user picks an org (the multi-org, no-existing-match case).
    /// Mirrors the Mac <c>completeManualSignIn</c>. Returns <see cref="ManualSignInResult.InvalidInput"/>
    /// when there is no pending context (e.g. completing twice).
    /// </summary>
    public ManualSignInResult CompleteWithChosenOrg(Organization org)
    {
        if (_pending is not { } ctx)
        {
            return ManualSignInResult.InvalidInput;
        }

        _pending = null;
        return AddOrReactivate(org, ctx.SessionKey, ctx.CookieHeader, ctx.Email);
    }

    private ManualSignInResult AddOrReactivate(Organization org, string sessionKey, string? cookieHeader, string email)
    {
        // UpsertAccount adds a new account OR updates an existing org in place (the corrected Mac
        // re-auth path); it primes the jar + bumps the generation when the account becomes/stays
        // active. A false return means a genuinely new account would exceed the 5-account cap.
        var account = new Account
        {
            Email = email,
            SessionKey = sessionKey,
            OrganizationId = org.Uuid,
            AllCookieHeader = cookieHeader,
        };

        if (!_accountStore.UpsertAccount(account))
        {
            return ManualSignInResult.AccountLimitReached;
        }

        // Make the just-upserted account active so its session is the one polled. UpsertAccount
        // already activates the first-ever account and re-primes an in-place re-auth of the active
        // one; SwitchTo covers the add-a-non-first-account and pick-a-different-org cases.
        var resolved = _accountStore.Accounts.First(a => a.OrganizationId == org.Uuid);
        _accountStore.SwitchTo(resolved.Id);
        DebugLog("Manual sign-in added/reactivated an account");
        return ManualSignInResult.Success(resolved.DisplayName);
    }

    /// <summary>
    /// Best-effort email pull from the org list for the account display name, mirroring the Mac
    /// <c>extractEmail</c> preference for the enriched <c>email_address</c> field. The deeper raw-JSON
    /// fallback keys the Mac also probes are not modeled here; an absent email falls back to
    /// "Account N" at the call site.
    /// </summary>
    private static string? ExtractEmail(IReadOnlyList<Organization> orgs)
        => orgs.Select(o => o.EmailAddress).FirstOrDefault(e => !string.IsNullOrEmpty(e));

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[ManualSignIn] {message}");
}

/// <summary>
/// A parsed pasted credential: the extracted <c>sessionKey</c> and, when a full multi-cookie header
/// was pasted, the whole header (carrying the HttpOnly <c>__cf_bm</c>). Both are already CRLF-stripped
/// by <see cref="ManualSignIn.ParsePastedCredentials"/>.
/// </summary>
public sealed record ParsedCredentials(string SessionKey, string? CookieHeader);

// OrgSelection + OrgSelectionKind are defined once, in AuthManager.cs, and shared by both the
// WebView (U6/U7) and manual-paste (U11) sign-in paths. ManualSignIn.SelectOrg consumes that single
// type (it reads .Choices, an alias of .Org's NeedsChoice list); no duplicate is defined here.

/// <summary>
/// Outcome of a manual paste sign-in, the C# port of the Mac <c>ManualSignInResult</c> enum
/// (Services/AuthManager.swift). Drives the Settings inline status + org picker.
/// </summary>
public sealed record ManualSignInResult
{
    public enum ResultKind
    {
        Success,
        NeedsOrgChoice,
        InvalidInput,
        AuthFailed,
        NoOrganizations,
        AccountLimitReached,
        ConnectionError,
    }

    public ResultKind Kind { get; private init; }

    /// Display name for <see cref="ResultKind.Success"/>.
    public string? DisplayName { get; private init; }

    /// Org choices for <see cref="ResultKind.NeedsOrgChoice"/>.
    public IReadOnlyList<Organization>? Orgs { get; private init; }

    /// For <see cref="ResultKind.AuthFailed"/>: true when only a bare sessionKey was pasted, so the
    /// likely cause is a missing HttpOnly <c>__cf_bm</c> (Cloudflare block) and the user should paste
    /// the full Cookie header. Mirrors the Mac <c>authFailed(suggestFullHeader:)</c>.
    public bool SuggestFullHeader { get; private init; }

    public static ManualSignInResult Success(string displayName) =>
        new() { Kind = ResultKind.Success, DisplayName = displayName };

    public static ManualSignInResult NeedsOrgChoice(IReadOnlyList<Organization> orgs) =>
        new() { Kind = ResultKind.NeedsOrgChoice, Orgs = orgs };

    public static readonly ManualSignInResult InvalidInput = new() { Kind = ResultKind.InvalidInput };

    public static ManualSignInResult AuthFailed(bool suggestFullHeader) =>
        new() { Kind = ResultKind.AuthFailed, SuggestFullHeader = suggestFullHeader };

    public static readonly ManualSignInResult NoOrganizations = new() { Kind = ResultKind.NoOrganizations };

    public static readonly ManualSignInResult AccountLimitReached = new() { Kind = ResultKind.AccountLimitReached };

    public static readonly ManualSignInResult ConnectionError = new() { Kind = ResultKind.ConnectionError };
}
