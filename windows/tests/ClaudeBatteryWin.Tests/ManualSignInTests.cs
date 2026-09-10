using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Http;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U11 manual-sign-in tests: the universal cookie-paste floor.
///
/// Covers the plan's scenarios: a value with no <c>sessionKey</c> is rejected; a value containing a
/// CRLF sequence is sanitized before use; a valid multi-org header routes to the picker; plus the
/// bare-key vs full-header distinction (which drives the Cloudflare "paste the full header" hint),
/// single-org auto-select, the 401/403 auth-failed mapping, and the empty-orgs case.
///
/// The HTTP surface is a fake <see cref="IClaudeApi"/> (no network); the account store is real (DPAPI
/// on the CI Windows host, with isolated temp paths) so the add/re-auth + jar-priming side effects
/// are exercised exactly as in production.
/// </summary>
public sealed class ManualSignInTests : IDisposable
{
    private readonly string _root;
    private readonly string _secretsDir;
    private readonly string _metadataPath;

    public ManualSignInTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "cbw-manualsignin-tests", Guid.NewGuid().ToString("N"));
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
        }
    }

    private AccountStore NewStore(CookieContainer jar)
        => new(jar, new SecretStore(_secretsDir), _metadataPath);

    private sealed class FakeApi : IClaudeApi
    {
        public IReadOnlyList<Organization> Orgs = Array.Empty<Organization>();
        public int? AuthFailStatus; // when set, GetOrganizationsAsync throws ClaudeAuthException
        public bool Throw;          // when set, GetOrganizationsAsync throws a transport error

        // When set, the sessionKey cookie present in this jar AT DISCOVERY TIME is recorded, so a
        // test can assert which credential org discovery actually used (issue #13).
        public CookieContainer? JarToObserve;
        public string? SessionKeySeenAtDiscovery;

        // When set, the org fetch completes on a thread-pool thread (like the real transport after a
        // network round trip) instead of synchronously via Task.FromResult, so a test can prove where
        // SignInAsync's continuation lands. A synchronously-completed fake never yields, so it cannot
        // tell ConfigureAwait(true) from ConfigureAwait(false).
        public bool CompleteOffThread;

        public Task<UsageApiResponse> GetUsageAsync(string organizationId, CancellationToken cancellationToken)
            => Task.FromResult(new UsageApiResponse());

        public Task<Credits?> GetCreditsAsync(string organizationId, CancellationToken cancellationToken)
            => Task.FromResult<Credits?>(null);

        public Task<IReadOnlyList<Organization>> GetOrganizationsAsync(CancellationToken cancellationToken)
        {
            if (JarToObserve is not null)
            {
                SessionKeySeenAtDiscovery =
                    JarToObserve.GetCookies(new Uri("https://claude.ai"))["sessionKey"]?.Value;
            }
            if (AuthFailStatus is { } status)
            {
                throw new ClaudeAuthException(status);
            }
            if (Throw)
            {
                throw new HttpRequestException("simulated transport failure");
            }
            if (CompleteOffThread)
            {
                return CompleteOffThreadAsync();
            }
            return Task.FromResult(Orgs);
        }

        private async Task<IReadOnlyList<Organization>> CompleteOffThreadAsync()
        {
            // Task.Delay always goes async (timer), and ConfigureAwait(false) keeps the completion on
            // the timer's pool thread rather than posting back to the test's context.
            await Task.Delay(10).ConfigureAwait(false);
            return Orgs;
        }
    }

    /// <summary>
    /// A stand-in for the WPF dispatcher: a <see cref="SynchronizationContext"/> that runs every
    /// posted callback on ONE dedicated thread. Lets a test assert that a continuation came back to
    /// "the UI thread" (this thread) rather than running wherever the awaited task completed.
    /// </summary>
    private sealed class SingleThreadSyncContext : SynchronizationContext, IDisposable
    {
        private readonly BlockingCollection<(SendOrPostCallback Callback, object? State)> _queue = new();
        private readonly Thread _thread;
        private int _postCount;

        public int ThreadId => _thread.ManagedThreadId;
        public int PostCount => Volatile.Read(ref _postCount);

        public SingleThreadSyncContext()
        {
            _thread = new Thread(Pump) { IsBackground = true, Name = "test-ui-thread" };
            _thread.Start();
        }

        private void Pump()
        {
            SetSynchronizationContext(this);
            foreach (var (callback, state) in _queue.GetConsumingEnumerable())
            {
                callback(state);
            }
        }

        public override void Post(SendOrPostCallback d, object? state)
        {
            Interlocked.Increment(ref _postCount);
            _queue.Add((d, state));
        }

        public override void Send(SendOrPostCallback d, object? state) => throw new NotSupportedException();

        public void Dispose() => _queue.CompleteAdding();
    }

    private static Organization Org(string uuid, string? name = null, string? email = null)
        => new() { Uuid = uuid, Name = name, EmailAddress = email };

    // ---- pure parse / sanitize ----

    [Fact]
    public void Parse_NoSessionKey_ReturnsNull()
    {
        // A header that has cookies but no sessionKey pair is not usable.
        Assert.Null(ManualSignIn.ParsePastedCredentials("__cf_bm=abc; other=def"));
        // Empty / whitespace.
        Assert.Null(ManualSignIn.ParsePastedCredentials("   "));
        // A multi-token value with whitespace but no sessionKey is not a bare key either.
        Assert.Null(ManualSignIn.ParsePastedCredentials("not a cookie header"));
    }

    [Fact]
    public void Parse_EmptySessionKeyValue_ReturnsNull()
    {
        Assert.Null(ManualSignIn.ParsePastedCredentials("sessionKey=; __cf_bm=abc"));
    }

    [Fact]
    public void Parse_BareSessionKey_KeepsKey_NoHeader()
    {
        var parsed = ManualSignIn.ParsePastedCredentials("sk-ant-xyz123");
        Assert.NotNull(parsed);
        Assert.Equal("sk-ant-xyz123", parsed!.SessionKey);
        Assert.Null(parsed.CookieHeader); // bare key -> no full header (drives the Cloudflare hint)
    }

    [Fact]
    public void Parse_LoneSessionKeyPair_TreatedAsBareKey()
    {
        // "sessionKey=value" with no other cookies is a bare key, not a full header.
        var parsed = ManualSignIn.ParsePastedCredentials("sessionKey=sk-only");
        Assert.NotNull(parsed);
        Assert.Equal("sk-only", parsed!.SessionKey);
        Assert.Null(parsed.CookieHeader);
    }

    [Fact]
    public void Parse_FullHeaderWithOtherCookies_KeepsWholeHeader()
    {
        var parsed = ManualSignIn.ParsePastedCredentials("sessionKey=sk-1; __cf_bm=cf-1; lastOrg=o");
        Assert.NotNull(parsed);
        Assert.Equal("sk-1", parsed!.SessionKey);
        Assert.Equal("sessionKey=sk-1; __cf_bm=cf-1; lastOrg=o", parsed.CookieHeader);
    }

    [Fact]
    public void Sanitize_StripsCarriageReturnAndNewline()
    {
        Assert.Equal("ab", ManualSignIn.Sanitize("a\r\nb"));
        Assert.Equal("sessionKey=sk-1; x=y", ManualSignIn.Sanitize("sessionKey=sk-1;\r\n x=y\r"));
    }

    [Fact]
    public void Parse_CrlfContainingValue_IsSanitizedBeforeUse()
    {
        // A CRLF injected into the header must not survive into the parsed sessionKey or header
        // (header-injection guard). The newline between cookies is also stripped, so the trailing
        // "__cf_bm" pair still parses as a same-line cookie and the whole (cleaned) header is kept.
        var parsed = ManualSignIn.ParsePastedCredentials("sessionKey=sk-\r\nINJECT; __cf_bm=cf");
        Assert.NotNull(parsed);
        Assert.DoesNotContain('\r', parsed!.SessionKey);
        Assert.DoesNotContain('\n', parsed.SessionKey);
        Assert.Equal("sk-INJECT", parsed.SessionKey);
        Assert.NotNull(parsed.CookieHeader);
        Assert.DoesNotContain('\r', parsed.CookieHeader!);
        Assert.DoesNotContain('\n', parsed.CookieHeader!);
    }

    // ---- pure org selection ----

    [Fact]
    public void SelectOrg_SingleOrg_TakesIt()
    {
        var selection = AuthManager.SelectOrg(new[] { Org("o1") }, Array.Empty<Account>());
        Assert.Equal(OrgSelectionKind.Single, selection.Kind);
        Assert.Equal("o1", selection.Org!.Uuid);
    }

    [Fact]
    public void SelectOrg_MultiOrg_NoExistingMatch_NeedsChoice()
    {
        var selection = AuthManager.SelectOrg(new[] { Org("o1"), Org("o2") }, Array.Empty<Account>());
        Assert.Equal(OrgSelectionKind.NeedsChoice, selection.Kind);
        Assert.Equal(2, selection.Orgs!.Count);
    }

    [Fact]
    public void SelectOrg_MultiOrg_ExistingMatch_AutoMatches()
    {
        var existing = new Account { Email = "u@e.com", SessionKey = "sk", OrganizationId = "o2" };
        var selection = AuthManager.SelectOrg(new[] { Org("o1"), Org("o2") }, new[] { existing });
        Assert.Equal(OrgSelectionKind.AutoMatched, selection.Kind);
        Assert.Equal("o2", selection.Org!.Uuid); // never blindly orgs[0]
    }

    // ---- async router ----

    [Fact]
    public async Task SignIn_InvalidInput_RejectedBeforeAnyNetworkCall()
    {
        var api = new FakeApi { Orgs = new[] { Org("o1") } };
        var store = NewStore(new CookieContainer());
        var manual = new ManualSignIn(api, store);

        var result = await manual.SignInAsync("not a cookie");

        Assert.Equal(ManualSignInResult.ResultKind.InvalidInput, result.Kind);
        Assert.Empty(store.Accounts); // nothing added
    }

    [Fact]
    public async Task SignIn_SingleOrg_AddsAccount_AndActivates()
    {
        var api = new FakeApi { Orgs = new[] { Org("o1", name: "Acme", email: "u@acme.com") } };
        var jar = new CookieContainer();
        var store = NewStore(jar);
        var manual = new ManualSignIn(api, store);

        var result = await manual.SignInAsync("sessionKey=sk-1; __cf_bm=cf-1");

        Assert.Equal(ManualSignInResult.ResultKind.Success, result.Kind);
        Assert.Single(store.Accounts);
        Assert.Equal("o1", store.ActiveAccount!.OrganizationId);
        Assert.Equal("u@acme.com", store.ActiveAccount.Email);
        // The full header (carrying __cf_bm) was kept and primed into the shared jar.
        Assert.Equal("sk-1", jar.GetCookies(new Uri("https://claude.ai"))["sessionKey"]!.Value);
        Assert.Equal("cf-1", jar.GetCookies(new Uri("https://claude.ai"))["__cf_bm"]!.Value);
    }

    [Fact]
    public async Task SignIn_MultiOrg_NoMatch_RoutesToPicker_ThenCompletes()
    {
        var api = new FakeApi { Orgs = new[] { Org("o1", "First"), Org("o2", "Second") } };
        var store = NewStore(new CookieContainer());
        var manual = new ManualSignIn(api, store);

        var result = await manual.SignInAsync("sessionKey=sk-1; __cf_bm=cf");

        // A valid multi-org header routes to the picker rather than auto-picking orgs[0].
        Assert.Equal(ManualSignInResult.ResultKind.NeedsOrgChoice, result.Kind);
        Assert.Equal(2, result.Orgs!.Count);
        Assert.Empty(store.Accounts); // nothing committed until the user chooses

        // Completing with the chosen org commits exactly that org.
        var chosen = result.Orgs!.First(o => o.Uuid == "o2");
        var done = manual.CompleteWithChosenOrg(chosen);
        Assert.Equal(ManualSignInResult.ResultKind.Success, done.Kind);
        Assert.Single(store.Accounts);
        Assert.Equal("o2", store.ActiveAccount!.OrganizationId);
    }

    [Fact]
    public async Task SignIn_BareKey_AuthFailed_SuggestsFullHeader()
    {
        var api = new FakeApi { AuthFailStatus = 403 };
        var store = NewStore(new CookieContainer());
        var manual = new ManualSignIn(api, store);

        var result = await manual.SignInAsync("sk-bare-key"); // bare key, no full header

        Assert.Equal(ManualSignInResult.ResultKind.AuthFailed, result.Kind);
        Assert.True(result.SuggestFullHeader); // bare key -> likely Cloudflare block, steer to header
        Assert.Empty(store.Accounts);
    }

    [Fact]
    public async Task SignIn_FullHeader_AuthFailed_DoesNotSuggestFullHeader()
    {
        var api = new FakeApi { AuthFailStatus = 401 };
        var store = NewStore(new CookieContainer());
        var manual = new ManualSignIn(api, store);

        var result = await manual.SignInAsync("sessionKey=sk-1; __cf_bm=cf");

        Assert.Equal(ManualSignInResult.ResultKind.AuthFailed, result.Kind);
        Assert.False(result.SuggestFullHeader); // already a full header; expired-cookies message
    }

    [Fact]
    public async Task SignIn_EmptyOrgs_NoOrganizations()
    {
        var api = new FakeApi { Orgs = Array.Empty<Organization>() };
        var store = NewStore(new CookieContainer());
        var manual = new ManualSignIn(api, store);

        var result = await manual.SignInAsync("sessionKey=sk-1; __cf_bm=cf");

        Assert.Equal(ManualSignInResult.ResultKind.NoOrganizations, result.Kind);
        Assert.Empty(store.Accounts);
    }

    [Fact]
    public async Task SignIn_TransportThrow_ConnectionError()
    {
        var api = new FakeApi { Throw = true };
        var store = NewStore(new CookieContainer());
        var manual = new ManualSignIn(api, store);

        var result = await manual.SignInAsync("sessionKey=sk-1; __cf_bm=cf");

        Assert.Equal(ManualSignInResult.ResultKind.ConnectionError, result.Kind);
    }

    [Fact]
    public async Task SignIn_ExistingOrg_ReauthsInPlace_NoDuplicate()
    {
        // Seed an account for o1, then manually re-auth the same org: it updates in place (the
        // corrected Mac re-auth path) rather than creating a second account.
        var store = NewStore(new CookieContainer());
        store.UpsertAccount(new Account { Email = "old@e.com", SessionKey = "sk-old", OrganizationId = "o1" });
        var originalId = store.Accounts[0].Id;

        var api = new FakeApi { Orgs = new[] { Org("o1", "Acme", "new@acme.com") } };
        var manual = new ManualSignIn(api, store);

        var result = await manual.SignInAsync("sessionKey=sk-new; __cf_bm=cf-new");

        Assert.Equal(ManualSignInResult.ResultKind.Success, result.Kind);
        Assert.Single(store.Accounts);
        Assert.Equal(originalId, store.Accounts[0].Id);     // same account, updated in place
        Assert.Equal("sk-new", store.Accounts[0].SessionKey);
    }

    // ---- issue #13: discovery uses the pasted credential, not the active account's jar ----

    [Fact]
    public async Task SignIn_DiscoversWithPastedCredential_NotActiveAccountJar()
    {
        // Seed + activate account A so the shared jar starts primed with A's session.
        var jar = new CookieContainer();
        var store = NewStore(jar);
        store.UpsertAccount(new Account
        {
            Email = "a@x.com", SessionKey = "sk-A", OrganizationId = "org-A",
            AllCookieHeader = "sessionKey=sk-A; __cf_bm=cfA",
        });
        Assert.Equal("sk-A", jar.GetCookies(new Uri("https://claude.ai"))["sessionKey"]!.Value);

        // Paste a DIFFERENT identity (B). Discovery must run with B's credential, not A's.
        var api = new FakeApi { Orgs = new[] { Org("org-B", email: "b@x.com") }, JarToObserve = jar };
        var manual = new ManualSignIn(api, store);

        var result = await manual.SignInAsync("sessionKey=sk-B; __cf_bm=cfB");

        Assert.Equal(ManualSignInResult.ResultKind.Success, result.Kind);
        Assert.Equal("sk-B", api.SessionKeySeenAtDiscovery);    // discovery used the PASTED credential
        Assert.Equal("org-B", store.ActiveAccount!.OrganizationId);
        Assert.Equal(2, store.Accounts.Count);                  // A retained, B onboarded
    }

    [Fact]
    public async Task SignIn_Failed_RestoresActiveAccountJar_NotLeftClobbered()
    {
        var jar = new CookieContainer();
        var store = NewStore(jar);
        store.UpsertAccount(new Account
        {
            Email = "a@x.com", SessionKey = "sk-A", OrganizationId = "org-A",
            AllCookieHeader = "sessionKey=sk-A; __cf_bm=cfA",
        });

        // The pasted credential is tried (so it DID prime), but discovery 401s.
        var api = new FakeApi { AuthFailStatus = 401, JarToObserve = jar };
        var manual = new ManualSignIn(api, store);

        var result = await manual.SignInAsync("sessionKey=sk-BAD; __cf_bm=cfBAD");

        Assert.Equal(ManualSignInResult.ResultKind.AuthFailed, result.Kind);
        Assert.Equal("sk-BAD", api.SessionKeySeenAtDiscovery); // it primed + tried the pasted value
        // ...but after the failure, account A's cookies are restored - not left as the bad paste.
        Assert.Equal("sk-A", jar.GetCookies(new Uri("https://claude.ai"))["sessionKey"]!.Value);
        Assert.Single(store.Accounts);
        Assert.Equal("org-A", store.ActiveAccount!.OrganizationId);
    }

    [Fact]
    public async Task SignIn_AfterNeedsOrgChoice_FreshSignIn_DiscardsPendingContext_AndSucceeds()
    {
        // After a multi-org paste parks a pending pick, a brand-new SignInAsync must discard that
        // stale context (_pending is cleared at the top of SignInAsync) and resolve on its own merits -
        // here a single-org paste that succeeds, NOT an InvalidInput from a leftover pending pick (U12).
        var api = new FakeApi { Orgs = new[] { Org("o1", "First"), Org("o2", "Second") } };
        var store = NewStore(new CookieContainer());
        var manual = new ManualSignIn(api, store);

        var first = await manual.SignInAsync("sessionKey=sk-1; __cf_bm=cf");
        Assert.Equal(ManualSignInResult.ResultKind.NeedsOrgChoice, first.Kind);
        Assert.Empty(store.Accounts);

        // A fresh sign-in for a single-org identity succeeds; the prior pending pick is not consulted.
        api.Orgs = new[] { Org("solo", email: "u@solo.com") };
        var second = await manual.SignInAsync("sessionKey=sk-2; __cf_bm=cf2");
        Assert.Equal(ManualSignInResult.ResultKind.Success, second.Kind);
        Assert.Single(store.Accounts);
        Assert.Equal("solo", store.ActiveAccount!.OrganizationId);

        // The stale pending pick is gone: completing the OLD choice now is InvalidInput (no context).
        var staleComplete = manual.CompleteWithChosenOrg(Org("o2"));
        Assert.Equal(ManualSignInResult.ResultKind.InvalidInput, staleComplete.Kind);
    }

    [Fact]
    public async Task CompleteWithChosenOrg_WithNoPendingContext_IsInvalidInput()
    {
        var api = new FakeApi();
        var store = NewStore(new CookieContainer());
        var manual = new ManualSignIn(api, store);

        // No prior SignInAsync that needed a choice -> no pending context.
        var result = manual.CompleteWithChosenOrg(Org("o1"));
        Assert.Equal(ManualSignInResult.ResultKind.InvalidInput, result.Kind);
    }

    // ---- save failure: a distinct result, no throw, the active jar restored ----

    [Fact]
    public async Task SignIn_FirstAccount_SaveFailure_ReturnsSaveFailed_NoThrow_JarCleared()
    {
        // Occupy the secrets directory path with a FILE so the blob can never be written.
        File.WriteAllText(_secretsDir, "not a directory");
        var api = new FakeApi { Orgs = new[] { Org("o1", email: "u@acme.com") } };
        var jar = new CookieContainer();
        var store = NewStore(jar);
        var manual = new ManualSignIn(api, store);

        var result = await manual.SignInAsync("sessionKey=sk-1; __cf_bm=cf-1");

        Assert.Equal(ManualSignInResult.ResultKind.SaveFailed, result.Kind);
        Assert.Empty(store.Accounts);
        Assert.Null(store.ActiveAccount);
        // No active account to restore, so the pasted credential is cleared out of the jar.
        Assert.Empty(jar.GetCookies(new Uri("https://claude.ai")));
    }

    [Fact]
    public async Task SignIn_Reauth_SaveFailure_ReturnsSaveFailed_RestoresActiveAccountJar()
    {
        // A healthy active account A, primed into the jar.
        var jar = new CookieContainer();
        var store = NewStore(jar);
        store.UpsertAccount(new Account
        {
            Email = "a@x.com", SessionKey = "sk-A", OrganizationId = "org-A",
            AllCookieHeader = "sessionKey=sk-A; __cf_bm=cfA",
        });
        var id = store.Accounts[0].Id;

        // Re-auth the same org by paste while A's blob is locked, so the re-auth's blob write fails.
        var api = new FakeApi { Orgs = new[] { Org("org-A", email: "a@x.com") }, JarToObserve = jar };
        var manual = new ManualSignIn(api, store);
        ManualSignInResult result;
        using (new FileStream(new SecretStore(_secretsDir).BlobPath(id), FileMode.Open, FileAccess.Read, FileShare.None))
        {
            result = await manual.SignInAsync("sessionKey=sk-NEW; __cf_bm=cfNEW");
        }

        Assert.Equal(ManualSignInResult.ResultKind.SaveFailed, result.Kind);
        Assert.Equal("sk-NEW", api.SessionKeySeenAtDiscovery); // discovery did run with the paste
        // ...but the store is unchanged and the jar holds the prior active account's cookies again.
        Assert.Single(store.Accounts);
        Assert.Equal("sk-A", store.Accounts[0].SessionKey);
        Assert.Equal("sk-A", jar.GetCookies(new Uri("https://claude.ai"))["sessionKey"]!.Value);
        Assert.Equal("cfA", jar.GetCookies(new Uri("https://claude.ai"))["__cf_bm"]!.Value);
    }

    // ---- thread affinity: the commit runs on the caller's context, not the transport's thread ----

    [Fact]
    public async Task SignIn_CommitsOnCallerSynchronizationContext_NotOnTransportThread()
    {
        var api = new FakeApi { Orgs = new[] { Org("o1", email: "u@acme.com") }, CompleteOffThread = true };
        var store = NewStore(new CookieContainer());
        var manual = new ManualSignIn(api, store);

        var commitThreadId = -1;
        store.ActiveAccountChanged += () => commitThreadId = Environment.CurrentManagedThreadId;

        using var uiContext = new SingleThreadSyncContext();
        var previous = SynchronizationContext.Current;
        Task<ManualSignInResult> signIn;
        SynchronizationContext.SetSynchronizationContext(uiContext);
        try
        {
            // Start the call with the "UI" context current so SignInAsync captures it at its await;
            // the fake then completes on a pool thread, which is where the commit used to run.
            signIn = manual.SignInAsync("sessionKey=sk-1; __cf_bm=cf-1");
        }
        finally
        {
            // Restore this thread's context BEFORE awaiting so the test's own continuation goes
            // back through xUnit's context, not ours.
            SynchronizationContext.SetSynchronizationContext(previous);
        }

        var result = await signIn;

        Assert.Equal(ManualSignInResult.ResultKind.Success, result.Kind);
        Assert.True(uiContext.PostCount >= 1);                // the continuation was posted back...
        Assert.Equal(uiContext.ThreadId, commitThreadId);      // ...and the store mutated on that thread
        Assert.Single(store.Accounts);
    }
}
