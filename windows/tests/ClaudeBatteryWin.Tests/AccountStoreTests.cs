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
