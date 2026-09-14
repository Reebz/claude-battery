using System.IO;
using System.Net;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using ClaudeBatteryWin.Views;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U7: one sign-in revives every organization stored under the same login (R16), a second
/// organization of that login can finally be added (R17), and a paste never moves the user off the
/// account they were looking at (R24).
///
/// The failure this closes: with three organizations expired, a user had to sign in three times,
/// once per organization, with nothing telling them that was what was needed.
/// </summary>
public sealed class RepairAllTests : IDisposable
{
    private readonly string _root;
    private readonly CookieContainer _jar = new();

    public RepairAllTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "cbw-repairall-tests", Guid.NewGuid().ToString("N"));
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

    private static Account Stored(string org, string key = "sk-expired") => new()
    {
        Email = "me@example.com",
        SessionKey = key,
        OrganizationId = org,
        AllCookieHeader = $"sessionKey={key}; __cf_bm=cf-old",
    };

    private static CapturedCookie[] FreshCookies() => new[]
    {
        AuthManagerTests.Cookie("sessionKey", "sk-fresh"),
        AuthManagerTests.Cookie("__cf_bm", "cf-new"),
    };

    // --- The exact strings ---------------------------------------------------------------------

    [Theory]
    [InlineData(1, true, "Refreshed 1 organization.")]
    [InlineData(2, true, "Refreshed 2 organizations.")]
    [InlineData(3, true, "Refreshed 3 organizations.")]
    public void RepairConfirmation_NamesTheCount(int count, bool viewed, string expected) =>
        Assert.Equal(expected, AuthManager.RepairConfirmation(count, viewed));

    [Fact]
    public void RepairConfirmation_WhenTheViewedAccountWasNotOneOfThem_SaysSoAndSaysWhatToDo() =>
        Assert.Equal(
            "Refreshed 2 organizations, but not the one you're viewing - switch to a refreshed one, or paste that account's cookie header.",
            AuthManager.RepairConfirmation(2, viewedAccountRepaired: false));

    [Theory]
    [InlineData(0, "Signed in as me@x.com.")]
    [InlineData(2, "Signed in as me@x.com. Refreshed 2 organizations.")]
    public void SignInConfirmation_AddsTheRepairSentenceOnlyWhenThereWasARepair(int count, string expected) =>
        Assert.Equal(expected, AuthManager.SignInConfirmation("me@x.com", count));

    // --- One sign-in through the window repairs every stored organization ----------------------

    [Fact]
    public async Task ThreeStoredAndExpired_OneSignInRefreshesAllThree()
    {
        // Covers AE4.
        var store = NewStore();
        store.UpsertAccount(Stored("org-a"));
        store.UpsertAccount(Stored("org-b"));
        store.UpsertAccount(Stored("org-c"));

        var api = new FakeClaudeApi { Orgs = new[] { Org("org-a"), Org("org-b"), Org("org-c") } };
        var (manager, web, _, _, confirmations) = NewManagerOn(store, api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        Assert.Equal(3, store.Accounts.Count);
        Assert.All(store.Accounts, a => Assert.Equal("sk-fresh", a.SessionKey));
        Assert.Equal(new[] { "Refreshed 3 organizations." }, confirmations.ToArray());
        Assert.Equal(LoginStateKind.Active, manager.LoginState.Kind);
    }

    [Fact]
    public async Task AllStored_SwitchTargetIsTheActiveAccount_NotTheFirstWritten()
    {
        var store = NewStore();
        store.UpsertAccount(Stored("org-a"));
        store.UpsertAccount(Stored("org-b"));
        var second = store.Accounts.First(a => a.OrganizationId == "org-b");
        store.SwitchTo(second.Id);

        var api = new FakeClaudeApi { Orgs = new[] { Org("org-a"), Org("org-b") } };
        var (manager, web, _, _, _) = NewManagerOn(store, api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        // Only the active account's write re-primes the live jar, so ending anywhere else would
        // leave the session that is polling on stale cookies.
        Assert.Equal(second.Id, store.ActiveAccountId);
    }

    [Fact]
    public async Task PlainReAuthOfOneAccount_SaysNothing()
    {
        var store = NewStore();
        store.UpsertAccount(Stored("org-a"));

        var api = new FakeClaudeApi { Orgs = new[] { Org("org-a") } };
        var (manager, web, _, _, confirmations) = NewManagerOn(store, api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        Assert.Empty(confirmations); // one account repaired, nothing worth a sentence
    }

    private (AuthManager Manager, FakeLoginWebView WebView, FakeOrgPicker Picker, AccountStore Store, List<string> Confirmations)
        NewManagerOn(AccountStore store, FakeClaudeApi api)
    {
        var web = new FakeLoginWebView();
        var picker = new FakeOrgPicker();
        var manager = new AuthManager(api, store, new FakeLoginWebViewFactory(web), picker);
        var confirmations = new List<string>();
        manager.OnSignInConfirmation = confirmations.Add;
        return (manager, web, picker, store, confirmations);
    }

    // --- A second organization of the same login can be added -----------------------------------

    [Fact]
    public async Task PersonalStored_PickingTheTeamOrganisationStoresBoth()
    {
        // Covers AE5: this used to be impossible, because the stored organization was reused
        // silently and the unadded one was never offered.
        var store = NewStore();
        store.UpsertAccount(Stored("org-personal"));

        var api = new FakeClaudeApi
        {
            Orgs = new[] { Org("org-personal", name: "Personal"), Org("org-team", name: "Team") }
        };
        var (manager, web, picker, _, _) = NewManagerOn(store, api);
        picker.Choice = Org("org-team", name: "Team");

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        Assert.True(picker.WasAsked);
        Assert.Equal(2, store.Accounts.Count);
        Assert.Contains(store.Accounts, a => a.OrganizationId == "org-team");
        Assert.Contains(store.Accounts, a => a.OrganizationId == "org-personal");
        Assert.Equal("org-team", store.ActiveAccount!.OrganizationId);
    }

    [Fact]
    public async Task AddingTheSecondOrganisation_AlsoRevivesTheFirst()
    {
        var store = NewStore();
        store.UpsertAccount(Stored("org-personal"));

        var api = new FakeClaudeApi { Orgs = new[] { Org("org-personal"), Org("org-team") } };
        var (manager, web, picker, _, confirmations) = NewManagerOn(store, api);
        picker.Choice = Org("org-team");

        manager.PresentLogin();
        web.RaiseCookiesObserved(FreshCookies());
        await manager.LastDiscoveryTask!;

        Assert.Equal("sk-fresh", store.Accounts.First(a => a.OrganizationId == "org-personal").SessionKey);
        // The organization signed in to was newly added, so only the sibling counts as repaired.
        Assert.Equal(new[] { "Refreshed 1 organization." }, confirmations.ToArray());
    }

    // --- The picker marks what is already stored ------------------------------------------------

    [Fact]
    public void Picker_MarksTheOrganisationsThatAlreadyHaveAnAccount()
    {
        var labels = OrgPickerView.BuildDisambiguatedLabels(
            new[] { Org("org-personal", name: "Personal"), Org("org-team", name: "Team") },
            new[] { "org-personal" });

        Assert.Equal(new[] { "Personal (already added)", "Team" }, labels.ToArray());
    }

    [Fact]
    public void Picker_WithNothingStored_MarksNothing()
    {
        var labels = OrgPickerView.BuildDisambiguatedLabels(
            new[] { Org("org-a", name: "Acme"), Org("org-b", name: "Beta") });

        Assert.Equal(new[] { "Acme", "Beta" }, labels.ToArray());
    }

    // --- A paste repairs without moving the user ------------------------------------------------

    [Fact]
    public async Task PasteThatOnlyRepairs_DoesNotSwitchTheActiveAccount()
    {
        // Covers R24: the user is looking at one account and fixed another; they must not find
        // themselves somewhere else.
        var store = NewStore();
        store.UpsertAccount(Stored("org-a"));
        store.UpsertAccount(Stored("org-b"));
        var viewing = store.Accounts.First(a => a.OrganizationId == "org-b");
        store.SwitchTo(viewing.Id);

        var api = new FakeClaudeApi { Orgs = new[] { Org("org-a"), Org("org-b") } };
        var result = await new ManualSignIn(api, store).SignInAsync("sessionKey=sk-pasted; __cf_bm=cf-new");

        Assert.Equal(ManualSignInResult.ResultKind.AlreadySignedInAllOrgs, result.Kind);
        Assert.Equal(2, result.RefreshedCount);
        Assert.True(result.ActiveAccountRefreshed);
        Assert.Equal(viewing.Id, store.ActiveAccountId); // unchanged
        Assert.All(store.Accounts, a => Assert.Equal("sk-pasted", a.SessionKey));
    }

    [Fact]
    public async Task PasteThatRepairsSomethingElse_SaysTheViewedAccountWasNotAmongThem()
    {
        var store = NewStore();
        store.UpsertAccount(Stored("org-a"));
        store.UpsertAccount(Stored("org-b"));
        store.UpsertAccount(Stored("org-untouched", key: "sk-other"));
        var viewing = store.Accounts.First(a => a.OrganizationId == "org-untouched");
        store.SwitchTo(viewing.Id);

        // The pasted login covers two stored organizations, and the one being viewed is not one of
        // them: everything it can reach is already stored, so it repairs and stops.
        var api = new FakeClaudeApi { Orgs = new[] { Org("org-a"), Org("org-b") } };
        var result = await new ManualSignIn(api, store).SignInAsync("sessionKey=sk-pasted; __cf_bm=cf-new");

        Assert.Equal(viewing.Id, store.ActiveAccountId);
        Assert.Equal("sk-other", store.Accounts.First(a => a.OrganizationId == "org-untouched").SessionKey);
        Assert.Contains("but not the one you're viewing", ConfirmationFor(result), StringComparison.Ordinal);
    }

    private static string ConfirmationFor(ManualSignInResult result) => result.Kind switch
    {
        ManualSignInResult.ResultKind.AlreadySignedInAllOrgs =>
            AuthManager.RepairConfirmation(result.RefreshedCount, result.ActiveAccountRefreshed),
        ManualSignInResult.ResultKind.Success =>
            AuthManager.SignInConfirmation(result.DisplayName ?? string.Empty, result.RefreshedCount),
        _ => string.Empty
    };

    [Fact]
    public async Task PasteThatAddsANewOrganisation_SwitchesToIt()
    {
        var store = NewStore();
        store.UpsertAccount(Stored("org-a"));
        var existing = store.Accounts[0];

        var api = new FakeClaudeApi { Orgs = new[] { Org("org-new") } };
        var result = await new ManualSignIn(api, store).SignInAsync("sessionKey=sk-pasted; __cf_bm=cf-new");

        Assert.Equal(ManualSignInResult.ResultKind.Success, result.Kind);
        Assert.Equal(2, store.Accounts.Count);
        Assert.NotEqual(existing.Id, store.ActiveAccountId);
        Assert.Equal("org-new", store.ActiveAccount!.OrganizationId);
    }

    // --- The steps a user follows to find the header -------------------------------------------

    [Fact]
    public void CookieHeaderHelp_ListsTheDeveloperToolsSteps()
    {
        var help = SettingsWindow.CookieHeaderHelpText;

        Assert.StartsWith("1. Sign in to claude.ai in your browser.", help, StringComparison.Ordinal);
        Assert.Contains("2. Open Developer Tools (F12) and select the Network tab.", help, StringComparison.Ordinal);
        Assert.Contains("3. Refresh the page, then click any request to claude.ai.", help, StringComparison.Ordinal);
        Assert.Contains("4. Under Request Headers, copy the entire value of the \"Cookie\" header.", help, StringComparison.Ordinal);
        Assert.EndsWith("5. Paste it above. Paste it only here, never into a web page.", help, StringComparison.Ordinal);
        Assert.DoesNotContain('—', help); // no em dash, matching the Mac
    }
}
