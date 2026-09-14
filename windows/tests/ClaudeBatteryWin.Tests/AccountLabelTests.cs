using System.IO;
using System.Net;
using System.Net.Http;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U8: accounts show the address they belong to (R19), two organizations of one login are told apart
/// (R20), and no later sign-in renames a row someone else set up (R21).
///
/// Every account currently reads "Account 1", "Account 2" and so on, which is useless the moment
/// there is more than one. The address comes from the account endpoint first and the organizations
/// response second, and nothing about that lookup is allowed to fail a sign-in that otherwise worked.
/// </summary>
public sealed class AccountLabelTests : IDisposable
{
    private readonly string _root;
    private readonly CookieContainer _jar = new();

    public AccountLabelTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "cbw-labels-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
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

    private AccountStore NewStore() =>
        new(_jar, new SecretStore(Path.Combine(_root, "secrets")), Path.Combine(_root, "accounts.json"));

    private static Organization Org(string uuid, string? name = null, string? email = null) =>
        new() { Uuid = uuid, Name = name, EmailAddress = email };

    private static CapturedCookie[] FreshCookies() => new[]
    {
        AuthManagerTests.Cookie("sessionKey", "sk-fresh"),
        AuthManagerTests.Cookie("__cf_bm", "cf-new"),
    };

    private (AuthManager Manager, FakeLoginWebView WebView, AccountStore Store) NewManager(
        FakeClaudeApi api, AccountStore? store = null)
    {
        store ??= NewStore();
        var web = new FakeLoginWebView();
        var manager = new AuthManager(api, store, new FakeLoginWebViewFactory(web), new FakeOrgPicker());
        return (manager, web, store);
    }

    // --- Which label an account gets ------------------------------------------------------------

    [Fact]
    public async Task NoAddressInTheOrganisations_TakesTheOneFromTheAccountEndpoint()
    {
        var api = new FakeClaudeApi
        {
            Orgs = new[] { Org("org-1") },
            AccountEmail = "real@example.com",
        };
        var (manager, web, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        Assert.Equal("real@example.com", Assert.Single(store.Accounts).Email);
        Assert.Equal(1, api.AccountEmailCalls); // once per sign-in, never on a poll
    }

    [Fact]
    public async Task AccountEndpointSilent_FallsBackToTheOrganisationsAddress()
    {
        var api = new FakeClaudeApi
        {
            Orgs = new[] { Org("org-1", email: "from-org@example.com") },
            AccountEmail = null,
        };
        var (manager, web, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        Assert.Equal("from-org@example.com", Assert.Single(store.Accounts).Email);
    }

    [Fact]
    public async Task NeitherSourceHasAnAddress_UsesAPlaceholderThatCanBeRepairedLater()
    {
        var api = new FakeClaudeApi { Orgs = new[] { Org("org-1") }, AccountEmail = null };
        var (manager, web, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        var account = Assert.Single(store.Accounts);
        Assert.Equal("Account 1", account.Email);
        Assert.True(AuthManager.IsPlaceholderEmail(account.Email));
    }

    [Theory]
    [InlineData(403)]
    [InlineData(429)]
    public async Task AccountEndpointBlocked_CompletesTheSignInAnyway(int status)
    {
        // A blocked cosmetic lookup must never turn a working sign-in into a failure, and must never
        // be counted as a Cloudflare block against the poll path.
        var api = new FakeClaudeApi
        {
            Orgs = new[] { Org("org-1", email: "from-org@example.com") },
            AccountEmailThrows = new ClaudeAuthException(status),
        };
        var (manager, web, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        Assert.Equal(LoginStateKind.Active, manager.LoginState.Kind);
        Assert.Equal("from-org@example.com", Assert.Single(store.Accounts).Email);
    }

    [Fact]
    public async Task AccountEndpointThrows_CompletesTheSignInAnyway()
    {
        var api = new FakeClaudeApi
        {
            Orgs = new[] { Org("org-1", email: "from-org@example.com") },
            AccountEmailThrows = new HttpRequestException("simulated transport failure"),
        };
        var (manager, web, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        Assert.Equal(LoginStateKind.Active, manager.LoginState.Kind);
        Assert.Equal("from-org@example.com", Assert.Single(store.Accounts).Email);
    }

    // --- What counts as a placeholder ----------------------------------------------------------

    [Theory]
    [InlineData("Account 1", true)]
    [InlineData("Account 12", true)]
    [InlineData("", true)]
    [InlineData("  ", true)]
    [InlineData("me@x.com", false)]
    [InlineData("account 1", false)]
    [InlineData("Account", false)]
    [InlineData("Account x", false)]
    [InlineData("Accountant 2", false)]
    [InlineData("Account 1 (work)", false)]
    public void IsPlaceholderEmail_MatchesOnlyTheAppsOwnLabels(string email, bool expected) =>
        Assert.Equal(expected, AuthManager.IsPlaceholderEmail(email));

    // --- Never relabel a real address -----------------------------------------------------------

    [Fact]
    public async Task ReAuthWithNoAddressAnywhere_KeepsTheRealOneAlreadyStored()
    {
        var store = NewStore();
        store.UpsertAccount(new Account
        {
            Email = "first-owner@example.com",
            SessionKey = "sk-old",
            OrganizationId = "org-1",
        });

        // Two logins can share one organization; the row belongs to whoever added it first.
        var api = new FakeClaudeApi { Orgs = new[] { Org("org-1") }, AccountEmail = null };
        var (manager, web, _) = NewManager(api, store);

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        Assert.Equal("first-owner@example.com", Assert.Single(store.Accounts).Email);
    }

    [Fact]
    public async Task ReAuthOverAPlaceholder_PutsTheRealAddressIn()
    {
        var store = NewStore();
        store.UpsertAccount(new Account
        {
            Email = "Account 1",
            SessionKey = "sk-old",
            OrganizationId = "org-1",
        });

        var api = new FakeClaudeApi { Orgs = new[] { Org("org-1") }, AccountEmail = "real@example.com" };
        var (manager, web, _) = NewManager(api, store);

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        Assert.Equal("real@example.com", Assert.Single(store.Accounts).Email);
    }

    [Fact]
    public void RepairPlaceholder_NeverSwapsOnePlaceholderForAnother()
    {
        var store = NewStore();
        store.UpsertAccount(new Account { Email = "Account 1", SessionKey = "sk", OrganizationId = "org-1" });
        var account = store.Accounts[0];

        AuthManager.RepairPlaceholderEmail(store, account, "Account 2");

        Assert.Equal("Account 1", store.Accounts[0].Email);
    }

    // --- Telling two organizations of one login apart -------------------------------------------

    [Fact]
    public void UniqueAddress_ShowsJustTheAddress()
    {
        var solo = new Account
        {
            Email = "solo@x.com",
            SessionKey = "sk",
            OrganizationId = "org-1",
            OrganizationName = "Acme",
        };

        Assert.Equal("solo@x.com", AccountStore.DisambiguatedName(solo, new[] { solo }));
    }

    [Fact]
    public void SharedAddress_AppendsTheOrganisationName()
    {
        var first = new Account { Email = "me@x.com", SessionKey = "sk", OrganizationId = "a", OrganizationName = "Acme" };
        var second = new Account { Email = "me@x.com", SessionKey = "sk", OrganizationId = "b", OrganizationName = "Beta" };
        var accounts = new[] { first, second };

        Assert.Equal("me@x.com (Acme)", AccountStore.DisambiguatedName(first, accounts));
        Assert.Equal("me@x.com (Beta)", AccountStore.DisambiguatedName(second, accounts));
        Assert.NotEqual(
            AccountStore.DisambiguatedName(first, accounts),
            AccountStore.DisambiguatedName(second, accounts));
    }

    [Fact]
    public void ANicknameAlwaysWins()
    {
        var first = new Account
        {
            Email = "me@x.com", SessionKey = "sk", OrganizationId = "a",
            OrganizationName = "Acme", Nickname = "Work",
        };
        var second = new Account { Email = "me@x.com", SessionKey = "sk", OrganizationId = "b", OrganizationName = "Beta" };

        Assert.Equal("Work", AccountStore.DisambiguatedName(first, new[] { first, second }));
    }

    [Fact]
    public void SharedAddressWithNoOrganisationName_FallsBackToTheAddress()
    {
        // An account stored before organization names were kept has nothing to append.
        var first = new Account { Email = "me@x.com", SessionKey = "sk", OrganizationId = "a" };
        var second = new Account { Email = "me@x.com", SessionKey = "sk", OrganizationId = "b" };

        Assert.Equal("me@x.com", AccountStore.DisambiguatedName(first, new[] { first, second }));
    }

    [Fact]
    public async Task SigningIn_StoresTheOrganisationName()
    {
        var api = new FakeClaudeApi { Orgs = new[] { Org("org-1", name: "Acme Inc") } };
        var (manager, web, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        Assert.Equal("Acme Inc", Assert.Single(store.Accounts).OrganizationName);
    }
}
