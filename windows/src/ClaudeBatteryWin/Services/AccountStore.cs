using System.Diagnostics;
using System.IO;
using System.Net;
using System.Text.Json;
using ClaudeBatteryWin.Models;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// Multi-account state, the Windows port of the Mac <c>AccountStore</c>
/// (Services/AccountStore.swift) plus the cookie-jar priming the Mac kept in
/// <c>ClaudeAPI.activateCookies</c> (Services/ClaudeAPI.swift).
///
/// Responsibilities:
/// <list type="bullet">
/// <item>Hold up to <see cref="MaxAccounts"/> accounts with organization-id uniqueness on add.</item>
/// <item>Encrypt each account's secrets through <see cref="SecretStore"/> (DPAPI); persist the
/// non-secret metadata as plaintext JSON.</item>
/// <item>Own the account-activation boundary: clear the prior account's <c>.claude.ai</c> cookies
/// from the shared <see cref="CookieContainer"/> and prime the new account's, exactly as the Mac
/// did against its shared cookie jar.</item>
/// <item>Drive switch concurrency with a monotonically increasing request-generation token so a
/// late response from a superseded poll can never set <c>authFailed</c> on the newly active
/// account.</item>
/// </list>
///
/// <para>
/// <b>Re-auth updates in place.</b> Adding an account whose org id already exists is NOT a
/// rejection: it updates that account's session (sessionKey + cookie header) in place. The Mac's
/// <c>addAccount</c> rejected a duplicate org id outright, which permanently locked a user out of
/// re-login for an org they already had. <see cref="UpsertAccount"/> is the corrected path.
/// </para>
///
/// <para>
/// <b>Threading.</b> Intended to be driven from the UI thread (like the Mac <c>@MainActor</c>
/// store). The generation token is read by the polling layer on its own task; it is an
/// <c>int</c> mutated only here and read via <see cref="CurrentGeneration"/> /
/// <see cref="IsCurrentGeneration"/>, so a stale generation is always safely &lt; the current one.
/// </para>
/// </summary>
public sealed class AccountStore
{
    public const int MaxAccounts = 5;

    private const string ClaudeBaseUrl = "https://claude.ai";

    private readonly CookieContainer _cookieJar;
    private readonly SecretStore _secretStore;
    private readonly string _metadataPath;

    private readonly List<Account> _accounts = new();
    private Guid? _activeAccountId;
    private int _generation;

    /// <summary>
    /// Raised whenever the active account's session/cookies change in a way the poller must react
    /// to: an account switch, a removal that changes the active account, an in-place re-auth of the
    /// active account, or the last account being removed. The poller subscribes to cancel its
    /// in-flight request, re-read <see cref="CurrentGeneration"/>, and restart (or stop, when
    /// <see cref="ActiveAccount"/> is null). This is the Windows analog of the Mac calling
    /// <c>ClaudeAPI.activateCookies</c> then letting the next poll pick up the new jar.
    /// </summary>
    public event Action? ActiveAccountChanged;

    /// <param name="cookieJar">
    /// The shared <see cref="CookieContainer"/> the HTTP transport (U3) reads from. The integration
    /// layer wires the real shared instance; tests pass a fresh container and assert on its
    /// contents.
    /// </param>
    /// <param name="secretStore">DPAPI-backed secret persistence.</param>
    /// <param name="metadataPath">
    /// File that holds the non-secret account metadata as JSON. Defaults to
    /// <c>%APPDATA%\ClaudeBatteryWin\accounts.json</c>. Tests inject a temp path.
    /// </param>
    public AccountStore(CookieContainer cookieJar, SecretStore secretStore, string? metadataPath = null)
    {
        _cookieJar = cookieJar;
        _secretStore = secretStore;
        _metadataPath = metadataPath ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "ClaudeBatteryWin",
            "accounts.json");

        Load();
    }

    // MARK: - Observable state

    public IReadOnlyList<Account> Accounts => _accounts;

    public Guid? ActiveAccountId => _activeAccountId;

    public Account? ActiveAccount =>
        _activeAccountId is { } id ? _accounts.FirstOrDefault(a => a.Id == id) : null;

    public bool IsAuthenticated => ActiveAccount is not null;

    public bool CanAddAccount => _accounts.Count < MaxAccounts;

    /// <summary>
    /// The current request-generation token. Bumped on every activation boundary (add of the first
    /// account, switch, in-place re-auth of the active account, and a removal that changes the
    /// active account). The poller stamps each request with the value read at dispatch and discards
    /// any response whose stamp is no longer current.
    /// </summary>
    public int CurrentGeneration => _generation;

    /// <summary>
    /// True when <paramref name="generation"/> is still the active generation. The poller calls
    /// this before applying a result (in particular before setting <c>authFailed</c>); a superseded
    /// generation returns false, so a late prior-account response is discarded and can never flag
    /// the newly active account.
    /// </summary>
    public bool IsCurrentGeneration(int generation) => generation == _generation;

    // MARK: - Mutations

    /// <summary>
    /// Add a new account or, when its organization id already exists, update that existing account's
    /// session in place. Returns false only when a genuinely new account would exceed
    /// <see cref="MaxAccounts"/>; an in-place update of an existing org always succeeds (it does not
    /// consume a slot). This is the corrected Mac <c>addAccount</c> + re-auth path: the Mac rejected
    /// a duplicate org, locking out re-login.
    /// </summary>
    /// <returns>
    /// <c>true</c> when the account was added or an existing org was updated; <c>false</c> when a
    /// new account was rejected for hitting the 5-account limit.
    /// </returns>
    public bool UpsertAccount(Account account)
    {
        var existingIndex = _accounts.FindIndex(a => a.OrganizationId == account.OrganizationId);
        if (existingIndex >= 0)
        {
            // Re-auth to an org we already track: update the session in place, preserving the
            // existing id, nickname, threshold, and added date. Only the credentials are refreshed.
            var existing = _accounts[existingIndex];
            var updated = existing with
            {
                Email = account.Email,
                SessionKey = account.SessionKey,
                AllCookieHeader = account.AllCookieHeader,
            };
            _accounts[existingIndex] = updated;
            SaveSecret(updated);
            PersistMetadata();

            // If the re-authed account is the active one, re-prime the jar with the fresh cookies
            // and bump the generation so any in-flight poll on stale cookies is discarded.
            if (_activeAccountId == updated.Id)
            {
                ActivateCookies(updated);
                BumpGenerationAndNotify();
            }

            DebugLog($"Updated existing org account in place: {updated.Id:N}");
            return true;
        }

        if (_accounts.Count >= MaxAccounts)
        {
            DebugLog($"Cannot add account — limit of {MaxAccounts} reached");
            return false;
        }

        _accounts.Add(account);
        SaveSecret(account);
        PersistMetadata();

        // First account becomes active (mirrors the Mac: accounts.count == 1 → switchTo).
        if (_accounts.Count == 1)
        {
            SwitchTo(account.Id);
        }

        DebugLog($"Added account: {account.Id:N}");
        return true;
    }

    /// <summary>
    /// Remove an account by id. When the removed account was active, the first remaining account
    /// becomes active and its cookies are primed; when none remain, the cookie jar is cleared of
    /// claude.ai cookies and <see cref="ActiveAccount"/> becomes null (the poller stops). The secret
    /// blob for the removed account is deleted from disk.
    /// </summary>
    public void RemoveAccount(Guid id)
    {
        var wasActive = _activeAccountId == id;
        var removed = _accounts.RemoveAll(a => a.Id == id) > 0;
        if (!removed)
        {
            return;
        }

        _secretStore.Delete(id);

        if (wasActive)
        {
            _activeAccountId = _accounts.Count > 0 ? _accounts[0].Id : (Guid?)null;
            if (ActiveAccount is { } newActive)
            {
                ActivateCookies(newActive);
            }
            else
            {
                ClearClaudeCookies();
            }

            // Either way the active session changed: bump so a late poll from the removed account is
            // discarded, and notify so the poller restarts (or stops, when no account remains).
            BumpGenerationAndNotify();
        }

        PersistMetadata();
        DebugLog($"Removed account {id:N}. Remaining: {_accounts.Count}");
    }

    /// <summary>
    /// Make the given account active: prime its cookies into the shared jar, bump the generation to
    /// supersede any in-flight poll on the prior account, and notify the poller to cancel-and-restart
    /// against the new account. No-op when the id is unknown.
    /// </summary>
    public void SwitchTo(Guid id)
    {
        var account = _accounts.FirstOrDefault(a => a.Id == id);
        if (account is null)
        {
            return;
        }

        _activeAccountId = id;
        PersistMetadata();
        ActivateCookies(account);
        BumpGenerationAndNotify();
        DebugLog($"Switched to account {id:N}");
    }

    /// <summary>
    /// Update the credentials of an existing account in place (used on a silent re-prime that is not
    /// a full org re-auth). Re-primes the jar and bumps the generation when the updated account is
    /// active. No-op when the id is unknown.
    /// </summary>
    public void UpdateSession(Guid id, string sessionKey, string? cookieHeader = null)
    {
        var index = _accounts.FindIndex(a => a.Id == id);
        if (index < 0)
        {
            return;
        }

        var updated = _accounts[index] with
        {
            SessionKey = sessionKey,
            AllCookieHeader = cookieHeader ?? _accounts[index].AllCookieHeader,
        };
        _accounts[index] = updated;
        SaveSecret(updated);
        PersistMetadata();

        if (_activeAccountId == id)
        {
            ActivateCookies(updated);
            BumpGenerationAndNotify();
        }
    }

    /// <summary>Update a nickname (trimmed, capped at 30 chars; empty becomes null). Mac parity.</summary>
    public void UpdateNickname(Guid id, string nickname)
    {
        var index = _accounts.FindIndex(a => a.Id == id);
        if (index < 0)
        {
            return;
        }

        var trimmed = nickname.Trim();
        if (trimmed.Length > 30)
        {
            trimmed = trimmed[..30];
        }

        _accounts[index] = _accounts[index] with { Nickname = trimmed.Length == 0 ? null : trimmed };
        PersistMetadata();
    }

    /// <summary>Set the low-usage notification dedup latch (U11). Mac parity.</summary>
    public void UpdateDidNotify(Guid id, bool value)
    {
        var index = _accounts.FindIndex(a => a.Id == id);
        if (index < 0)
        {
            return;
        }

        _accounts[index] = _accounts[index] with { DidNotifyBelowThreshold = value };
        PersistMetadata();
    }

    /// <summary>Set the per-account notification threshold (5-50 step 5 in the UI). Mac parity.</summary>
    public void UpdateThreshold(Guid id, double threshold)
    {
        var index = _accounts.FindIndex(a => a.Id == id);
        if (index < 0)
        {
            return;
        }

        _accounts[index] = _accounts[index] with { NotificationThreshold = threshold };
        PersistMetadata();
    }

    // MARK: - Generation

    private void BumpGenerationAndNotify()
    {
        _generation++;
        ActiveAccountChanged?.Invoke();
    }

    // MARK: - Cookie jar management (ported from Mac ClaudeAPI)

    /// <summary>
    /// Prime the shared jar with a captured credential set BEFORE any account exists, so the U7
    /// org-discovery request carries the full captured cookie set (including HttpOnly <c>__cf_bm</c>),
    /// not <c>sessionKey</c> alone. This is the Windows analog of the Mac
    /// <c>ClaudeAPI.activateCookies(sessionKey:cookieHeader:)</c> the auth flow calls right after
    /// capture: clear every claude.ai cookie first, then inject from <paramref name="cookieHeader"/>,
    /// falling back to <c>sessionKey=&lt;value&gt;</c> when no header was captured. No account or
    /// generation state is touched — only the jar.
    /// </summary>
    public void PrimeCookies(string sessionKey, string? cookieHeader)
    {
        ClearClaudeCookies();
        if (!string.IsNullOrEmpty(cookieHeader))
        {
            InjectCookies(cookieHeader!);
        }
        else
        {
            InjectCookies($"sessionKey={sessionKey}");
        }
    }

    /// <summary>
    /// Re-prime the shared jar from the CURRENT active account, or clear all claude.ai cookies when
    /// there is none. Used to undo a transient <see cref="PrimeCookies"/> done for an operation that
    /// then failed - e.g. manual sign-in primes the pasted credential for org discovery, and on a
    /// failed discovery the healthy active account's cookies must be restored rather than left
    /// clobbered by the (possibly invalid) pasted credential.
    /// </summary>
    public void RestoreActiveCookies()
    {
        if (ActiveAccount is { } active)
        {
            ActivateCookies(active);
        }
        else
        {
            ClearClaudeCookies();
        }
    }

    /// <summary>
    /// Replace any claude.ai cookies in the shared jar with the given account's captured set.
    /// Called at every account-becomes-active moment (load, switch, re-auth). Mirrors the Mac
    /// <c>ClaudeAPI.activateCookies</c>: clear first, then inject from <see cref="Account.AllCookieHeader"/>,
    /// falling back to <c>sessionKey=&lt;value&gt;</c> when no header was captured.
    /// </summary>
    private void ActivateCookies(Account account)
    {
        ClearClaudeCookies();
        if (!string.IsNullOrEmpty(account.AllCookieHeader))
        {
            InjectCookies(account.AllCookieHeader!);
        }
        else
        {
            InjectCookies($"sessionKey={account.SessionKey}");
        }
    }

    /// <summary>
    /// Remove every claude.ai-scoped cookie from the shared jar. <see cref="CookieContainer"/> has no
    /// delete, so expire each matching cookie (set <c>Expired = true</c>); the container then drops
    /// it. Matches both <c>claude.ai</c> and <c>.claude.ai</c> domains, exactly as the Mac did
    /// (never a suffix/contains match).
    /// </summary>
    private void ClearClaudeCookies()
    {
        var baseUri = new Uri(ClaudeBaseUrl);
        foreach (Cookie cookie in _cookieJar.GetCookies(baseUri))
        {
            var domain = cookie.Domain;
            if (domain == "claude.ai" || domain == ".claude.ai")
            {
                cookie.Expired = true;
            }
        }
    }

    /// <summary>
    /// Parse a <c>"name1=value1; name2=value2"</c> cookie header and add each pair to the shared jar
    /// scoped to <c>.claude.ai</c>. Ported verbatim from the Mac <c>injectCookies</c>:
    /// split on <c>";"</c> (not <c>"; "</c> — a bare semicolon is valid per RFC 6265 and must not
    /// drop later cookies), trim, split on the first <c>"="</c> only, and skip a pair whose name or
    /// value is empty.
    /// </summary>
    private void InjectCookies(string headerString)
    {
        foreach (var rawPair in headerString.Split(';'))
        {
            var trimmed = rawPair.Trim();
            if (trimmed.Length == 0)
            {
                continue;
            }

            var eq = trimmed.IndexOf('=');
            if (eq <= 0 || eq == trimmed.Length - 1)
            {
                // No '=', empty name (eq == 0), or empty value (eq is last char): skip.
                continue;
            }

            var name = trimmed[..eq].Trim();
            var value = trimmed[(eq + 1)..];
            if (name.Length == 0 || value.Length == 0)
            {
                continue;
            }

            try
            {
                _cookieJar.Add(new Cookie(name, value, "/", ".claude.ai")
                {
                    Secure = true,
                });
            }
            catch (CookieException)
            {
                // A malformed name/value the container rejects must not abort the rest of the set,
                // matching the Mac's per-pair tolerance.
                DebugLog("Skipped a cookie the container rejected");
            }
        }
    }

    // MARK: - Persistence

    /// <summary>
    /// Load account metadata from disk and re-hydrate each account's secrets from the SecretStore.
    /// An account whose secret blob is missing or will not decrypt is DROPPED (its blob deleted) and
    /// flagged for re-auth via <see cref="DroppedAccountIds"/> — never a crash. Then the active
    /// account is resolved and its cookies primed, mirroring the Mac init.
    /// </summary>
    private void Load()
    {
        var metadata = ReadMetadata();
        _accounts.Clear();
        DroppedAccountIds.Clear();

        var droppedActive = false;
        foreach (var meta in metadata.Accounts)
        {
            if (_secretStore.TryLoad(meta.Id, out var secret) && secret is not null)
            {
                _accounts.Add(meta with
                {
                    SessionKey = secret.SessionKey,
                    AllCookieHeader = secret.AllCookieHeader,
                });
            }
            else
            {
                // Corrupt/missing blob: delete it, drop the account, flag re-auth. Never crash.
                _secretStore.Delete(meta.Id);
                DroppedAccountIds.Add(meta.Id);
                if (metadata.ActiveAccountId == meta.Id)
                {
                    droppedActive = true;
                }
                DebugLog($"Dropped account {meta.Id:N} — secret unavailable (re-auth required)");
            }
        }

        _activeAccountId = metadata.ActiveAccountId;

        // If the persisted active account was dropped or absent, fall back to the first survivor.
        if (droppedActive || _activeAccountId is null ||
            _accounts.All(a => a.Id != _activeAccountId))
        {
            _activeAccountId = _accounts.Count > 0 ? _accounts[0].Id : (Guid?)null;
        }

        // If any accounts were dropped, persist the trimmed list so the dropped entries do not
        // resurface on the next launch.
        if (DroppedAccountIds.Count > 0)
        {
            PersistMetadata();
        }

        // Prime the jar from the active account so the first poll after boot carries the full set.
        if (ActiveAccount is { } active)
        {
            ActivateCookies(active);
        }
    }

    /// <summary>
    /// Account ids dropped during <see cref="Load"/> because their DPAPI blob would not decrypt
    /// (corrupt blob, copied profile, SID change). The UI surfaces these as "re-auth required". The
    /// metadata for these is also removed from disk by <see cref="Load"/>. Cleared on each load.
    /// </summary>
    public List<Guid> DroppedAccountIds { get; } = new();

    private void SaveSecret(Account account)
    {
        _secretStore.Save(account.Id, new AccountSecret
        {
            SessionKey = account.SessionKey,
            AllCookieHeader = account.AllCookieHeader,
        });
    }

    private void PersistMetadata()
    {
        var snapshot = new PersistedState
        {
            ActiveAccountId = _activeAccountId,
            // Persist only the non-secret fields; SessionKey / AllCookieHeader live in the SecretStore.
            Accounts = _accounts
                .Select(a => a with { SessionKey = string.Empty, AllCookieHeader = null })
                .ToList(),
        };

        try
        {
            var dir = Path.GetDirectoryName(_metadataPath);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }

            var json = JsonSerializer.SerializeToUtf8Bytes(snapshot, MetadataJsonOptions);
            var temp = _metadataPath + ".tmp";
            File.WriteAllBytes(temp, json);
            File.Move(temp, _metadataPath, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            DebugLog("Failed to persist account metadata (ignored)");
        }
    }

    private PersistedState ReadMetadata()
    {
        try
        {
            if (!File.Exists(_metadataPath))
            {
                return new PersistedState();
            }

            var json = File.ReadAllBytes(_metadataPath);
            return JsonSerializer.Deserialize<PersistedState>(json, MetadataJsonOptions) ?? new PersistedState();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            DebugLog("Failed to read account metadata (starting empty)");
            return new PersistedState();
        }
    }

    [Conditional("DEBUG")]
    private static void DebugLog(string message) => Debug.WriteLine($"[AccountStore] {message}");

    private static readonly JsonSerializerOptions MetadataJsonOptions = new()
    {
        IncludeFields = false,
    };

    /// <summary>
    /// On-disk shape for the non-secret account list plus the active id. Secrets are stripped before
    /// serialization (the SessionKey field carries an empty string here) and re-hydrated from the
    /// SecretStore on load.
    /// </summary>
    private sealed record PersistedState
    {
        public Guid? ActiveAccountId { get; init; }
        public List<Account> Accounts { get; init; } = new();
    }
}
