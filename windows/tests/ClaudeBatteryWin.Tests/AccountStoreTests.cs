using System.IO;
using System.Net;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U5 account-store tests: the 5-account cap, org-uniqueness vs in-place re-auth update, switch
/// concurrency (the load-bearing correctness model - a late prior-generation response can never
/// flag the new account), corrupt-blob drop-and-reauth, and the last-account-removed cookie clear.
///
/// Each test gets an isolated temp metadata path and secret directory plus a fresh
/// <see cref="CookieContainer"/>, so DPAPI blobs and JSON never collide across tests. DPAPI is a
/// real Windows API; the suite runs on the CI Windows host.
/// </summary>
public sealed class AccountStoreTests : IDisposable
{
    private static readonly Uri ClaudeUri = new("https://claude.ai");

    private readonly string _root;
    private readonly string _secretsDir;
    private readonly string _metadataPath;

    public AccountStoreTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "cbw-accountstore-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
        _secretsDir = Path.Combine(_root, "secrets");
        _metadataPath = Path.Combine(_root, "accounts.json");
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_root))
            {
                Directory.Delete(_root, recursive: true);
            }
        }
        catch (IOException)
        {
            // Best-effort temp cleanup.
        }
    }

    private AccountStore NewStore(CookieContainer jar) =>
        new(jar, new SecretStore(_secretsDir), _metadataPath);

    private static Account NewAccount(string org, string? sessionKey = null, string? cookieHeader = null) =>
        new()
        {
            Email = $"user-{org}@example.com",
            SessionKey = sessionKey ?? $"sk-{org}",
            OrganizationId = org,
            AllCookieHeader = cookieHeader,
        };

    private static int CountClaudeCookies(CookieContainer jar) => jar.GetCookies(ClaudeUri).Count;

    // ---- 5-account cap ----

    [Fact]
    public void SixthAccount_IsRejected()
    {
        var store = NewStore(new CookieContainer());

        for (var i = 1; i <= 5; i++)
        {
            Assert.True(store.UpsertAccount(NewAccount($"org-{i}")));
        }

        Assert.False(store.CanAddAccount);
        Assert.False(store.UpsertAccount(NewAccount("org-6")));
        Assert.Equal(5, store.Accounts.Count);
        Assert.DoesNotContain(store.Accounts, a => a.OrganizationId == "org-6");
    }

    // ---- duplicate org updates in place (the corrected Mac lockout) ----

    [Fact]
    public void DuplicateOrg_UpdatesExistingAccount_DoesNotCreateSecond()
    {
        var store = NewStore(new CookieContainer());
        Assert.True(store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-old")));
        var originalId = store.Accounts[0].Id;

        // Re-auth to the same org with a fresh session.
        var reauth = NewAccount("org-A", sessionKey: "sk-new", cookieHeader: "sessionKey=sk-new; __cf_bm=abc");
        Assert.True(store.UpsertAccount(reauth));

        Assert.Single(store.Accounts);
        Assert.Equal(originalId, store.Accounts[0].Id); // id preserved, not a new account
        Assert.Equal("sk-new", store.Accounts[0].SessionKey);
        Assert.Equal("sessionKey=sk-new; __cf_bm=abc", store.Accounts[0].AllCookieHeader);
    }

    [Fact]
    public void DuplicateOrg_UpdateInPlace_DoesNotConsumeASlot()
    {
        var store = NewStore(new CookieContainer());
        for (var i = 1; i <= 5; i++)
        {
            Assert.True(store.UpsertAccount(NewAccount($"org-{i}")));
        }

        // Re-auth to an existing org while full must still succeed (no slot consumed).
        Assert.True(store.UpsertAccount(NewAccount("org-3", sessionKey: "sk-refreshed")));
        Assert.Equal(5, store.Accounts.Count);
        Assert.Equal("sk-refreshed", store.Accounts.First(a => a.OrganizationId == "org-3").SessionKey);
    }

    [Fact]
    public void ReauthActiveAccount_BumpsGeneration_AndNotifies()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-old"));
        var notified = 0;
        store.ActiveAccountChanged += () => notified++;
        var genBefore = store.CurrentGeneration;

        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-new"));

        Assert.True(store.CurrentGeneration > genBefore);
        Assert.Equal(1, notified);
    }

    // ---- secret round-trip via the store ----

    [Fact]
    public void Reload_RehydratesSecretsFromDpapi()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-secret", cookieHeader: "sessionKey=sk-secret; __cf_bm=v"));

        // A new store instance over the same paths must recover the encrypted secrets.
        var reloaded = NewStore(new CookieContainer());

        Assert.Single(reloaded.Accounts);
        Assert.Equal("sk-secret", reloaded.Accounts[0].SessionKey);
        Assert.Equal("sessionKey=sk-secret; __cf_bm=v", reloaded.Accounts[0].AllCookieHeader);
        Assert.Empty(reloaded.DroppedAccountIds);
    }

    [Fact]
    public void Metadata_NeverPersistsSecretInPlaintext()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-PLAINTEXT-MARKER", cookieHeader: "sessionKey=sk-PLAINTEXT-MARKER"));

        var rawMetadata = File.ReadAllText(_metadataPath);

        // The metadata JSON holds only non-secret fields; the secret lives in the DPAPI blob.
        Assert.DoesNotContain("sk-PLAINTEXT-MARKER", rawMetadata);
        Assert.Contains("org-A", rawMetadata); // org id is non-secret metadata
    }

    // ---- U1: the captured session UA persists as non-secret metadata (R1) ----

    [Fact]
    public void Reload_RehydratesUserAgent_AsPlaintextMetadata_NotInDpapiBlob()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(new Account
        {
            Email = "u@x.com",
            SessionKey = "sk-A",
            OrganizationId = "org-A",
            AllCookieHeader = "sessionKey=sk-A",
            UserAgent = "UA/Reload-Test",
        });

        // The UA is non-secret, so it lives in plaintext accounts.json - never the DPAPI blob.
        var rawMetadata = File.ReadAllText(_metadataPath);
        Assert.Contains("UA/Reload-Test", rawMetadata);

        var blobBytes = File.ReadAllBytes(new SecretStore(_secretsDir).BlobPath(store.Accounts[0].Id));
        Assert.DoesNotContain("UA/Reload-Test", System.Text.Encoding.Latin1.GetString(blobBytes));

        // A second store over the same paths exposes the persisted UA on the active account.
        var reloaded = NewStore(new CookieContainer());
        Assert.Equal("UA/Reload-Test", reloaded.ActiveAccount!.UserAgent);
    }

    [Fact]
    public void Reload_AccountWithNoUserAgent_LoadsAsNull_NoError()
    {
        // A legacy accounts.json (pre-U1, no userAgent key) loads as UserAgent == null without error;
        // persisting an account whose UA is null produces the same on-disk shape.
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A")); // NewAccount sets no UserAgent
        Assert.Null(store.Accounts[0].UserAgent);

        var reloaded = NewStore(new CookieContainer());
        Assert.Single(reloaded.Accounts);
        Assert.Null(reloaded.Accounts[0].UserAgent);
    }

    [Fact]
    public void DuplicateOrg_Reauth_RefreshesUserAgentInPlace()
    {
        // A re-auth to an org we already track must refresh the captured UA in place; leaving the
        // stale UA is the wrong-UA-then-403 failure mode U1/U2 fix.
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(new Account
        {
            Email = "a@x.com", SessionKey = "old", OrganizationId = "org-A", UserAgent = "UA/Old",
        });
        var originalId = store.Accounts[0].Id;

        store.UpsertAccount(new Account
        {
            Email = "a@x.com", SessionKey = "new", OrganizationId = "org-A", UserAgent = "UA/New",
        });

        Assert.Single(store.Accounts);
        Assert.Equal(originalId, store.Accounts[0].Id); // updated in place, not a new account
        Assert.Equal("UA/New", store.Accounts[0].UserAgent);
    }

    [Fact]
    public void DuplicateOrg_Reauth_WithNullUserAgent_PreservesExistingUserAgent()
    {
        // The other half of the coalesce guard (`account.UserAgent ?? existing.UserAgent`): a
        // re-auth that captured NO UA - reachable, since capture can complete via cookie/history
        // events before any NavigationCompleted sets CapturedUserAgent - must never clobber a
        // known-good persisted UA to null. (Empty string cannot reach here: AuthManager captures a
        // UA only through a !string.IsNullOrEmpty gate.)
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(new Account
        {
            Email = "a@x.com", SessionKey = "old", OrganizationId = "org-A", UserAgent = "UA/Old",
        });

        store.UpsertAccount(new Account
        {
            Email = "a@x.com", SessionKey = "new", OrganizationId = "org-A", UserAgent = null,
        });

        Assert.Single(store.Accounts);
        Assert.Equal("UA/Old", store.Accounts[0].UserAgent); // preserved, not clobbered to null
    }

    // ---- corrupt blob drops the account + deletes the file + flags re-auth ----

    [Fact]
    public void CorruptBlob_OnReload_DropsAccount_DeletesFile_FlagsReauth_NoCrash()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A"));
        store.UpsertAccount(NewAccount("org-B", sessionKey: "sk-B"));
        var corruptId = store.Accounts.First(a => a.OrganizationId == "org-A").Id;

        // Corrupt account A's blob, then reload.
        var secretStore = new SecretStore(_secretsDir);
        File.WriteAllBytes(secretStore.BlobPath(corruptId), new byte[] { 9, 8, 7, 6, 5 });

        var reloaded = NewStore(new CookieContainer());

        // A is dropped and flagged; B survives.
        Assert.Single(reloaded.Accounts);
        Assert.Equal("org-B", reloaded.Accounts[0].OrganizationId);
        Assert.Contains(corruptId, reloaded.DroppedAccountIds);

        // The corrupt blob file is deleted.
        Assert.False(File.Exists(secretStore.BlobPath(corruptId)));
    }

    [Fact]
    public void CorruptBlob_OfActiveAccount_ReassignsActiveToSurvivor()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A")); // becomes active (first)
        store.UpsertAccount(NewAccount("org-B", sessionKey: "sk-B"));
        var activeId = store.ActiveAccountId!.Value;
        Assert.Equal("org-A", store.Accounts.First(a => a.Id == activeId).OrganizationId);

        var secretStore = new SecretStore(_secretsDir);
        File.WriteAllBytes(secretStore.BlobPath(activeId), new byte[] { 1, 2, 3 });

        var reloaded = NewStore(new CookieContainer());

        Assert.Single(reloaded.Accounts);
        Assert.Equal("org-B", reloaded.ActiveAccount!.OrganizationId);
        Assert.Contains(activeId, reloaded.DroppedAccountIds);
    }

    // ---- transient read failure (locked blob) defers the account, never drops it ----

    [Fact]
    public void LockedBlob_OnReload_IsDeferred_NotDropped_MetadataKept_ThenLoadsOnceReleased()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A", cookieHeader: "sessionKey=sk-A"));
        var id = store.Accounts[0].Id;
        var blobPath = new SecretStore(_secretsDir).BlobPath(id);

        // A second launch while something else holds the blob open (antivirus / backup / sync).
        using (new FileStream(blobPath, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            var locked = NewStore(new CookieContainer());

            // Not an account this session (no session key to poll with)...
            Assert.Empty(locked.Accounts);
            Assert.False(locked.IsAuthenticated);
            // ...but NOT dropped either: no re-auth flag, and the metadata entry is still on disk.
            Assert.Empty(locked.DroppedAccountIds);
            Assert.Contains(id.ToString(), File.ReadAllText(_metadataPath));
            Assert.False(ClaudeBatteryWin.App.ShouldFlagSecurityDataUnreadable(locked));

            // A write in the same session (adding another account) must carry the deferred entry
            // along instead of rewriting accounts.json without it.
            store = locked;
            store.UpsertAccount(NewAccount("org-B", sessionKey: "sk-B"));
            Assert.Contains(id.ToString(), File.ReadAllText(_metadataPath));
            Assert.Contains("org-A", File.ReadAllText(_metadataPath));
        }

        // Lock released: the next launch loads the deferred account with its secret intact.
        var recovered = NewStore(new CookieContainer());
        Assert.Equal(2, recovered.Accounts.Count);
        var a = recovered.Accounts.First(x => x.OrganizationId == "org-A");
        Assert.Equal(id, a.Id);
        Assert.Equal("sk-A", a.SessionKey);
        Assert.Equal("sessionKey=sk-A", a.AllCookieHeader);
        Assert.Empty(recovered.DroppedAccountIds);
        Assert.True(File.Exists(blobPath));
    }

    [Fact]
    public void LockedBlob_OfActiveAccount_FallsBackToSurvivor_ThisSessionOnly()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A")); // active (first)
        store.UpsertAccount(NewAccount("org-B", sessionKey: "sk-B"));
        var activeId = store.ActiveAccountId!.Value;
        var blobPath = new SecretStore(_secretsDir).BlobPath(activeId);

        using (new FileStream(blobPath, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            var locked = NewStore(new CookieContainer());

            Assert.Single(locked.Accounts);
            Assert.Equal("org-B", locked.ActiveAccount!.OrganizationId); // survivor active for now
            Assert.Empty(locked.DroppedAccountIds);
        }

        var recovered = NewStore(new CookieContainer());
        Assert.Equal(2, recovered.Accounts.Count); // A is back
        Assert.Contains(recovered.Accounts, x => x.Id == activeId && x.SessionKey == "sk-A");
    }

    // ---- save failure: nothing changes in memory, the caller gets a typed exception ----

    [Fact]
    public void SaveFailure_OnAdd_ThrowsTyped_LeavesAccountsActiveAndJarUntouched()
    {
        // Occupy the secrets directory path with a FILE so the blob can never be written.
        File.WriteAllText(_secretsDir, "not a directory");
        var jar = new CookieContainer();
        var store = NewStore(jar);

        Assert.Throws<AccountPersistenceException>(
            () => store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A", cookieHeader: "sessionKey=sk-A; __cf_bm=cf")));

        Assert.Empty(store.Accounts);         // no phantom account
        Assert.Null(store.ActiveAccount);
        Assert.False(store.IsAuthenticated);
        Assert.Equal(0, CountClaudeCookies(jar)); // jar never primed
        Assert.False(File.Exists(_metadataPath)); // metadata never written for it either
    }

    [Fact]
    public void SaveFailure_OnReauth_ThrowsTyped_KeepsExistingSessionAndJar()
    {
        var jar = new CookieContainer();
        var store = NewStore(jar);
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-OLD", cookieHeader: "sessionKey=sk-OLD"));
        var id = store.Accounts[0].Id;
        var genBefore = store.CurrentGeneration;
        var notified = 0;
        store.ActiveAccountChanged += () => notified++;

        // Lock the existing blob so the atomic move-into-place of the re-auth's new blob fails.
        using (new FileStream(new SecretStore(_secretsDir).BlobPath(id), FileMode.Open, FileAccess.Read, FileShare.None))
        {
            Assert.Throws<AccountPersistenceException>(
                () => store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-NEW", cookieHeader: "sessionKey=sk-NEW")));
        }

        // The in-memory account, the jar, and the generation are exactly as before the attempt.
        Assert.Single(store.Accounts);
        Assert.Equal("sk-OLD", store.Accounts[0].SessionKey);
        Assert.Equal("sk-OLD", jar.GetCookies(ClaudeUri)["sessionKey"]!.Value);
        Assert.Equal(genBefore, store.CurrentGeneration);
        Assert.Equal(0, notified);
    }

    // ---- cookie-jar per-domain cap: a large capture must not evict sessionKey ----

    [Fact]
    public void LargeCookieSet_SurvivesUpsertAndReload_SessionKeyNotEvicted()
    {
        // 25 distinct names with sessionKey FIRST (the first evicted on a default jar) and no
        // __cf_bm (so the restore path drops nothing). Every cookie lands under the one .claude.ai
        // domain key; .NET's default per-domain cap of 20 would silently evict the first five.
        var names = new List<string> { "sessionKey" };
        for (var i = 1; i < 25; i++)
        {
            names.Add($"cookie{i:D2}");
        }
        var header = string.Join("; ", names.Select(n => $"{n}={n}-value"));

        var jar = new CookieContainer();
        var store = NewStore(jar);
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sessionKey-value", cookieHeader: header));

        Assert.Equal(25, CountClaudeCookies(jar));
        Assert.NotNull(jar.GetCookies(ClaudeUri)["sessionKey"]);

        // Cold-start restore into a fresh jar over the same paths: still all 25.
        var restoreJar = new CookieContainer();
        _ = NewStore(restoreJar);

        Assert.Equal(25, CountClaudeCookies(restoreJar));
        Assert.Equal("sessionKey-value", restoreJar.GetCookies(ClaudeUri)["sessionKey"]!.Value);
    }

    [Fact]
    public void CookieJar_PerDomainCapacity_IsRaisedOnAnyJarTheStoreIsGiven()
    {
        // The factory the app uses is pre-configured...
        Assert.Equal(AccountStore.CookieJarPerDomainCapacity, AccountStore.CreateCookieJar().PerDomainCapacity);

        // ...and a default jar handed to the store is raised in place, so the fix rides the
        // injection path rather than one construction site.
        var jar = new CookieContainer();
        Assert.True(jar.PerDomainCapacity < AccountStore.CookieJarPerDomainCapacity);
        _ = NewStore(jar);
        Assert.Equal(AccountStore.CookieJarPerDomainCapacity, jar.PerDomainCapacity);
    }

    // ---- U6: App startup latch predicate (producer -> latch chain, R4) ----

    [Fact]
    public void App_ShouldFlagSecurityDataUnreadable_TrueOnDpapiDropWithNoSurvivor()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A"));
        var id = store.Accounts[0].Id;

        // Healthy reload: no drop -> not flagged.
        Assert.False(ClaudeBatteryWin.App.ShouldFlagSecurityDataUnreadable(NewStore(new CookieContainer())));

        // Corrupt the only account's blob, reload: dropped, no survivor, signed out -> flagged.
        File.WriteAllBytes(new SecretStore(_secretsDir).BlobPath(id), new byte[] { 9, 8, 7 });
        var dropped = NewStore(new CookieContainer());
        Assert.NotEmpty(dropped.DroppedAccountIds);
        Assert.False(dropped.IsAuthenticated);
        Assert.True(ClaudeBatteryWin.App.ShouldFlagSecurityDataUnreadable(dropped));
    }

    [Fact]
    public void App_ShouldFlagSecurityDataUnreadable_FalseWhenASurvivorIsAuthenticated()
    {
        // A drop alongside a surviving account: the user is signed in via the survivor, so the DPAPI
        // nudge must NOT show (it would be misleading) - the predicate gates on !IsAuthenticated.
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A")); // active
        store.UpsertAccount(NewAccount("org-B", sessionKey: "sk-B"));
        var aId = store.Accounts.First(a => a.OrganizationId == "org-A").Id;

        File.WriteAllBytes(new SecretStore(_secretsDir).BlobPath(aId), new byte[] { 1, 2, 3 });
        var reloaded = NewStore(new CookieContainer());

        Assert.NotEmpty(reloaded.DroppedAccountIds); // A dropped
        Assert.True(reloaded.IsAuthenticated);       // B survived and is active
        Assert.False(ClaudeBatteryWin.App.ShouldFlagSecurityDataUnreadable(reloaded));
    }

    [Fact]
    public void App_RetireSecurityDataUnreadable_RetiredOnAuth_NeverRelatchesAfterSignOut()
    {
        // The latch lifecycle promise (U6/R4): flagged at startup, retired by the FIRST
        // authenticated state observed, and a later deliberate sign-out must NOT resurface the
        // "security data could not be read" copy - the plain Sign In surface shows instead.
        Assert.True(ClaudeBatteryWin.App.RetireSecurityDataUnreadable(latched: true, isAuthenticated: false));   // pre-auth: still latched
        Assert.False(ClaudeBatteryWin.App.RetireSecurityDataUnreadable(latched: true, isAuthenticated: true));   // auth observed: retired
        Assert.False(ClaudeBatteryWin.App.RetireSecurityDataUnreadable(latched: false, isAuthenticated: false)); // sign-out later: never re-latches
    }

    // ---- switch concurrency: a late prior-generation response cannot flag the new account ----

    [Fact]
    public void SwitchMidPoll_LatePriorGenerationResponse_IsNotCurrent()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A"));
        store.UpsertAccount(NewAccount("org-B"));
        var accountA = store.Accounts.First(a => a.OrganizationId == "org-A");
        var accountB = store.Accounts.First(a => a.OrganizationId == "org-B");

        // Account A active; the poller dispatches a request stamped with the current generation.
        store.SwitchTo(accountA.Id);
        var genWhenPollStartedOnA = store.CurrentGeneration;

        // User switches to B mid-poll. Generation bumps.
        store.SwitchTo(accountB.Id);

        // A's in-flight response arrives now. The poller would gate on IsCurrentGeneration before
        // applying any result (including setting authFailed): it must be rejected as superseded.
        Assert.False(store.IsCurrentGeneration(genWhenPollStartedOnA));
        Assert.True(store.IsCurrentGeneration(store.CurrentGeneration));

        // The active account is B, untouched by A's late response.
        Assert.Equal(accountB.Id, store.ActiveAccountId);
    }

    [Fact]
    public void SwitchTo_PrimesNewAccountCookies_AndClearsPrior()
    {
        var jar = new CookieContainer();
        var store = NewStore(jar);
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A",
            cookieHeader: "sessionKey=sk-A; __cf_bm=cf-A; lastActiveOrg=org-A"));
        store.UpsertAccount(NewAccount("org-B", sessionKey: "sk-B",
            cookieHeader: "sessionKey=sk-B; __cf_bm=cf-B"));

        store.SwitchTo(store.Accounts.First(a => a.OrganizationId == "org-A").Id);
        var aCookies = jar.GetCookies(ClaudeUri);
        Assert.Equal("sk-A", aCookies["sessionKey"]!.Value);
        Assert.Equal("cf-A", aCookies["__cf_bm"]!.Value);
        Assert.Equal("org-A", aCookies["lastActiveOrg"]!.Value);

        // Switching to B must clear A's cookies (including A-only "lastActiveOrg") and prime B's.
        store.SwitchTo(store.Accounts.First(a => a.OrganizationId == "org-B").Id);
        var bCookies = jar.GetCookies(ClaudeUri);
        Assert.Equal("sk-B", bCookies["sessionKey"]!.Value);
        Assert.Equal("cf-B", bCookies["__cf_bm"]!.Value);
        Assert.Null(bCookies["lastActiveOrg"]); // A-only cookie did not leak into B's session
    }

    [Fact]
    public void Switch_BumpsGeneration_AndNotifiesPoller()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A"));
        store.UpsertAccount(NewAccount("org-B"));
        var notifications = 0;
        store.ActiveAccountChanged += () => notifications++;
        var genBefore = store.CurrentGeneration;

        store.SwitchTo(store.Accounts.First(a => a.OrganizationId == "org-B").Id);

        Assert.True(store.CurrentGeneration > genBefore);
        Assert.Equal(1, notifications);
    }

    // ---- first account auto-activates and primes cookies ----

    [Fact]
    public void FirstAccount_AutoActivates_AndPrimesCookies()
    {
        var jar = new CookieContainer();
        var store = NewStore(jar);

        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A", cookieHeader: "sessionKey=sk-A; __cf_bm=cf"));

        Assert.True(store.IsAuthenticated);
        Assert.Equal("org-A", store.ActiveAccount!.OrganizationId);
        Assert.Equal("sk-A", jar.GetCookies(ClaudeUri)["sessionKey"]!.Value);
    }

    [Fact]
    public void AccountWithNoCookieHeader_PrimesSessionKeyOnly()
    {
        var jar = new CookieContainer();
        var store = NewStore(jar);

        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-fallback", cookieHeader: null));

        var cookies = jar.GetCookies(ClaudeUri);
        Assert.Equal(1, cookies.Count);
        Assert.Equal("sk-fallback", cookies["sessionKey"]!.Value);
    }

    // ---- U5: cold-start restore drops the stale __cf_bm (restore-only) ----

    [Fact]
    public void Load_DropsStaleCfBm_KeepsSessionKeyAndOtherCookies()
    {
        // Persist an account whose captured header carries a __cf_bm (the in-session add primes the
        // full set into the seed jar).
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A",
            cookieHeader: "sessionKey=sk-A; __cf_bm=stale; lastActiveOrg=org-A"));

        // A cold start (a fresh store over the same paths) primes via the restore path: the stale
        // __cf_bm is dropped so Cloudflare issues a fresh one; sessionKey + other cookies stay.
        var restoreJar = new CookieContainer();
        _ = NewStore(restoreJar);

        var cookies = restoreJar.GetCookies(ClaudeUri);
        Assert.Equal("sk-A", cookies["sessionKey"]!.Value);
        Assert.Equal("org-A", cookies["lastActiveOrg"]!.Value);
        Assert.Null(cookies["__cf_bm"]); // stale __cf_bm dropped on restore
    }

    [Fact]
    public void AddAndSwitch_StillInjectFullSet_InclCfBm_SkipIsRestoreOnly()
    {
        var jar = new CookieContainer();
        var store = NewStore(jar);

        // Add (auto-activate) injects the full set incl __cf_bm in-session - NOT the restore path.
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A", cookieHeader: "sessionKey=sk-A; __cf_bm=cf-A"));
        Assert.Equal("cf-A", jar.GetCookies(ClaudeUri)["__cf_bm"]!.Value);

        // Switch also keeps __cf_bm (the drop is restore-only).
        store.UpsertAccount(NewAccount("org-B", sessionKey: "sk-B", cookieHeader: "sessionKey=sk-B; __cf_bm=cf-B"));
        store.SwitchTo(store.Accounts.First(a => a.OrganizationId == "org-B").Id);
        Assert.Equal("cf-B", jar.GetCookies(ClaudeUri)["__cf_bm"]!.Value);
    }

    [Fact]
    public void ReauthOfActiveAccount_ReinjectsFullSet_InclCfBm()
    {
        // The one full-set ActivateCookies caller the U5 cluster did not jar-assert: an in-place
        // re-auth of the currently ACTIVE org re-primes the jar with the FRESH full set including
        // __cf_bm - the restore-only drop must never leak into this path (KTD5).
        var jar = new CookieContainer();
        var store = NewStore(jar);

        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-1", cookieHeader: "sessionKey=sk-1; __cf_bm=cf-OLD"));
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-2", cookieHeader: "sessionKey=sk-2; __cf_bm=cf-NEW"));

        var cookies = jar.GetCookies(ClaudeUri);
        Assert.Equal("sk-2", cookies["sessionKey"]!.Value);
        Assert.Equal("cf-NEW", cookies["__cf_bm"]!.Value); // full set injected, __cf_bm kept
    }

    [Fact]
    public void Load_LeavesStoredCookieHeaderVerbatim_DropIsInjectionTimeOnly()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A",
            cookieHeader: "sessionKey=sk-A; __cf_bm=stale"));

        var reloaded = NewStore(new CookieContainer());
        // The persisted header is stored verbatim - the __cf_bm drop happens at injection, not on disk.
        Assert.Equal("sessionKey=sk-A; __cf_bm=stale", reloaded.Accounts[0].AllCookieHeader);
    }

    // ---- removing the only account clears the jar and stops polling ----

    [Fact]
    public void RemovingOnlyAccount_ClearsJar_AndStopsPolling()
    {
        var jar = new CookieContainer();
        var store = NewStore(jar);
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A", cookieHeader: "sessionKey=sk-A; __cf_bm=cf"));
        Assert.True(CountClaudeCookies(jar) > 0);

        var notified = 0;
        store.ActiveAccountChanged += () => notified++;
        var genBefore = store.CurrentGeneration;

        store.RemoveAccount(store.Accounts[0].Id);

        Assert.Empty(store.Accounts);
        Assert.Null(store.ActiveAccountId);
        Assert.False(store.IsAuthenticated); // poller sees no active account → stops
        Assert.Equal(0, CountClaudeCookies(jar)); // jar cleared of claude.ai cookies
        Assert.True(store.CurrentGeneration > genBefore); // late prior poll discarded
        Assert.Equal(1, notified);
    }

    [Fact]
    public void RemovingActiveAccount_WithOthers_ActivatesSurvivor_AndPrimesItsCookies()
    {
        var jar = new CookieContainer();
        var store = NewStore(jar);
        store.UpsertAccount(NewAccount("org-A", sessionKey: "sk-A", cookieHeader: "sessionKey=sk-A; __cf_bm=cf-A")); // active
        store.UpsertAccount(NewAccount("org-B", sessionKey: "sk-B", cookieHeader: "sessionKey=sk-B; __cf_bm=cf-B"));
        var activeId = store.ActiveAccountId!.Value;

        store.RemoveAccount(activeId);

        Assert.Single(store.Accounts);
        Assert.Equal("org-B", store.ActiveAccount!.OrganizationId);
        Assert.Equal("sk-B", jar.GetCookies(ClaudeUri)["sessionKey"]!.Value); // B's cookies primed
    }

    [Fact]
    public void RemovingNonActiveAccount_DoesNotChangeActiveOrGeneration()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A")); // active
        store.UpsertAccount(NewAccount("org-B"));
        var activeId = store.ActiveAccountId!.Value;
        var notified = 0;
        store.ActiveAccountChanged += () => notified++;
        var genBefore = store.CurrentGeneration;
        var bId = store.Accounts.First(a => a.OrganizationId == "org-B").Id;

        store.RemoveAccount(bId);

        Assert.Equal(activeId, store.ActiveAccountId); // active unchanged
        Assert.Equal(genBefore, store.CurrentGeneration); // no in-flight poll to supersede
        Assert.Equal(0, notified);
    }

    [Fact]
    public void RemoveAccount_DeletesSecretBlob()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A"));
        var id = store.Accounts[0].Id;
        var secretStore = new SecretStore(_secretsDir);
        Assert.True(File.Exists(secretStore.BlobPath(id)));

        store.RemoveAccount(id);

        Assert.False(File.Exists(secretStore.BlobPath(id)));
    }

    // ---- nickname / threshold parity ----

    [Fact]
    public void UpdateNickname_TrimsAndCapsAt30_EmptyBecomesNull()
    {
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(NewAccount("org-A"));
        var id = store.Accounts[0].Id;

        store.UpdateNickname(id, "   Work Account   ");
        Assert.Equal("Work Account", store.Accounts[0].Nickname);

        store.UpdateNickname(id, new string('x', 40));
        Assert.Equal(30, store.Accounts[0].Nickname!.Length);

        store.UpdateNickname(id, "   ");
        Assert.Null(store.Accounts[0].Nickname);
    }
}
