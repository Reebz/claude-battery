using System.IO;
using System.Net;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using ClaudeBatteryWin.Views;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U7 org-discovery tests: the pure <see cref="AuthManager.SelectOrg"/> rule (never <c>orgs[0]</c>),
/// the multi-org picker that persists exactly the chosen org, the re-auth-updates-in-place path, and
/// the failure-edge contract — EVERY discovery failure resets the capture guard so a retry can
/// capture again, and the login window closes ONLY on success. Driven through the same injectable
/// fakes as <see cref="AuthManagerTests"/> (defined there), so no real WebView2/HTTP is needed.
/// </summary>
public sealed class OrgDiscoveryTests : IDisposable
{
    private readonly string _root;
    private readonly CookieContainer _jar = new();

    public OrgDiscoveryTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "cbw-orgdiscovery-tests", Guid.NewGuid().ToString("N"));
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

    private (AuthManager Manager, FakeLoginWebView WebView, FakeOrgPicker Picker, AccountStore Store)
        NewManager(FakeClaudeApi api)
    {
        var store = NewStore();
        var web = new FakeLoginWebView();
        var picker = new FakeOrgPicker();
        var manager = new AuthManager(api, store, new FakeLoginWebViewFactory(web), picker);
        return (manager, web, picker, store);
    }

    private static Organization Org(string uuid, string? name = null, string? email = null) =>
        new() { Uuid = uuid, Name = name, EmailAddress = email };

    private static CapturedCookie[] SessionCookies() => new[]
    {
        AuthManagerTests.Cookie("sessionKey", "sk-live"),
        AuthManagerTests.Cookie("__cf_bm", "cf"),
    };

    // ---- pure SelectOrg rule -------------------------------------------------------------------

    [Fact]
    public void SelectOrg_SingleOrg_TakesIt()
    {
        var result = AuthManager.SelectOrg(new[] { Org("only") }, Array.Empty<Account>());
        Assert.Equal(OrgSelectionKind.Single, result.Kind);
        Assert.Equal("only", result.Org!.Uuid);
    }

    [Fact]
    public void SelectOrg_MultiOrg_NoExistingMatch_NeedsChoice()
    {
        var result = AuthManager.SelectOrg(new[] { Org("a"), Org("b") }, Array.Empty<Account>());
        Assert.Equal(OrgSelectionKind.NeedsChoice, result.Kind);
        Assert.Equal(2, result.Orgs!.Count);
    }

    [Fact]
    public void SelectOrg_MultiOrg_ExistingAccountMatch_AutoMatches()
    {
        var existing = new Account { Email = "e@x.com", SessionKey = "old", OrganizationId = "b" };
        var result = AuthManager.SelectOrg(new[] { Org("a"), Org("b") }, new[] { existing });
        Assert.Equal(OrgSelectionKind.AutoMatched, result.Kind);
        Assert.Equal("b", result.Org!.Uuid);
        Assert.Equal(existing.Id, result.AccountId);
    }

    // ---- single org auto-selects, no picker ----------------------------------------------------

    [Fact]
    public async Task SingleOrg_AutoSelects_NoPicker()
    {
        var api = new FakeClaudeApi { Orgs = new[] { Org("solo", email: "user@x.com") } };
        var (manager, web, picker, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(SessionCookies());
        await manager.LastDiscoveryTask!;

        Assert.False(picker.WasAsked);
        Assert.Single(store.Accounts);
        Assert.Equal("solo", store.Accounts[0].OrganizationId);
        Assert.Equal("user@x.com", store.Accounts[0].Email);
        Assert.Equal(LoginStateKind.Active, manager.LoginState.Kind);
        Assert.True(web.Disposed); // closed only on success
    }

    // ---- multi-org picker persists exactly the chosen org --------------------------------------

    [Fact]
    public async Task MultiOrg_PresentsPicker_PersistsChosenOrg()
    {
        var api = new FakeClaudeApi { Orgs = new[] { Org("a"), Org("b"), Org("c") } };
        var (manager, web, picker, store) = NewManager(api);
        picker.Choice = Org("b"); // user picks the second org

        manager.PresentLogin();
        web.RaiseCookiesObserved(SessionCookies());
        await manager.LastDiscoveryTask!;

        Assert.True(picker.WasAsked);
        Assert.Equal(3, picker.PresentedOrgs!.Count);
        Assert.Single(store.Accounts);
        Assert.Equal("b", store.Accounts[0].OrganizationId); // EXACTLY the chosen org, not orgs[0]
        Assert.Equal(LoginStateKind.Active, manager.LoginState.Kind);
    }

    [Fact]
    public async Task MultiOrg_PickerCancelled_SurfacesErrorAndResetsGuard()
    {
        var api = new FakeClaudeApi { Orgs = new[] { Org("a"), Org("b") } };
        var (manager, web, picker, store) = NewManager(api);
        picker.Choice = null; // cancel

        manager.PresentLogin();
        web.RaiseCookiesObserved(SessionCookies());
        await manager.LastDiscoveryTask!;

        Assert.Empty(store.Accounts);
        Assert.Equal(LoginStateKind.Error, manager.LoginState.Kind);
        Assert.False(manager.HasCapturedSession); // guard reset
        Assert.True(manager.HasActiveLoginWebView); // NOT torn down on failure — user recovers in place
    }

    // ---- re-auth updates in place --------------------------------------------------------------

    [Fact]
    public async Task ReAuth_ForExistingOrg_UpdatesInPlace_NoDuplicate()
    {
        // Seed an existing account for org "team" via a first login.
        var api = new FakeClaudeApi { Orgs = new[] { Org("team", email: "old@x.com") } };
        var (manager, web, _, store) = NewManager(api);
        manager.PresentLogin();
        web.RaiseCookiesObserved(new[]
        {
            AuthManagerTests.Cookie("sessionKey", "sk-OLD"),
            AuthManagerTests.Cookie("__cf_bm", "cf-old"),
        });
        await manager.LastDiscoveryTask!;
        Assert.Single(store.Accounts);
        var originalId = store.Accounts[0].Id;
        Assert.Equal("sk-OLD", store.Accounts[0].SessionKey);

        // Re-auth: a fresh login resolving to the SAME org must update in place, not duplicate or
        // reject (the Mac once permanently locked out re-login here).
        manager.PresentLogin();
        web.RaiseCookiesObserved(new[]
        {
            AuthManagerTests.Cookie("sessionKey", "sk-NEW"),
            AuthManagerTests.Cookie("__cf_bm", "cf-new"),
        });
        await manager.LastDiscoveryTask!;

        Assert.Single(store.Accounts); // still one account
        Assert.Equal(originalId, store.Accounts[0].Id); // same identity, updated in place
        Assert.Equal("sk-NEW", store.Accounts[0].SessionKey); // session refreshed
        Assert.Equal(LoginStateKind.Active, manager.LoginState.Kind);
    }

    // ---- failure edges all reset the guard, leave the window open ------------------------------

    [Fact]
    public async Task AuthFailure_401_ResetsGuard_ShowsError_KeepsWindowOpen()
    {
        var api = new FakeClaudeApi { OrganizationsThrows = new ClaudeAuthException(401) };
        var (manager, web, _, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(SessionCookies());
        await manager.LastDiscoveryTask!;

        Assert.Empty(store.Accounts);
        Assert.Equal(LoginStateKind.Error, manager.LoginState.Kind);
        Assert.False(manager.HasCapturedSession); // reset so retry can capture again
        Assert.True(manager.HasActiveLoginWebView);
    }

    [Fact]
    public async Task EmptyOrgs_ResetsGuard_ShowsError()
    {
        var api = new FakeClaudeApi { Orgs = Array.Empty<Organization>() };
        var (manager, web, _, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(SessionCookies());
        await manager.LastDiscoveryTask!;

        Assert.Empty(store.Accounts);
        Assert.Equal(LoginStateKind.Error, manager.LoginState.Kind);
        Assert.False(manager.HasCapturedSession);
    }

    [Fact]
    public async Task NetworkError_ResetsGuard_ShowsError()
    {
        var api = new FakeClaudeApi { OrganizationsThrows = new HttpRequestException("no network") };
        var (manager, web, _, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(SessionCookies());
        await manager.LastDiscoveryTask!;

        Assert.Empty(store.Accounts);
        Assert.Equal(LoginStateKind.Error, manager.LoginState.Kind);
        Assert.False(manager.HasCapturedSession);
    }

    [Fact]
    public async Task FailureThenRetry_CanCaptureAgain()
    {
        // First attempt: 403 fails and resets the guard.
        var api = new FakeClaudeApi { OrganizationsThrows = new ClaudeAuthException(403) };
        var (manager, web, _, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(SessionCookies());
        await manager.LastDiscoveryTask!;
        Assert.Equal(LoginStateKind.Error, manager.LoginState.Kind);
        Assert.False(manager.HasCapturedSession);

        // Retry clears the error and reloads; the guard is reset so the still-live session cookie is
        // re-captured. This time discovery succeeds.
        api.OrganizationsThrows = null;
        api.Orgs = new[] { Org("recovered") };
        manager.RetryLogin();
        Assert.Equal(LoginStateKind.Idle, manager.LoginState.Kind);

        web.RaiseCookiesObserved(SessionCookies());
        await manager.LastDiscoveryTask!;

        Assert.Single(store.Accounts);
        Assert.Equal("recovered", store.Accounts[0].OrganizationId);
        Assert.Equal(LoginStateKind.Active, manager.LoginState.Kind);
    }

    [Fact]
    public void Capture_WhileErrorShown_DoesNotReCapture()
    {
        // The capture funnel skips while an error card is shown: a cancelled/failed login leaves the
        // session cookie live and the poll armed; without this gate the next tick would re-capture
        // and silently undo the user's failure state. (Mac !loginState.isError gate.)
        var api = new FakeClaudeApi { OrganizationsThrows = new ClaudeAuthException(401) };
        var (manager, web, _, store) = NewManager(api);

        manager.PresentLogin();
        web.RaiseCookiesObserved(SessionCookies());
        // discovery ran synchronously (FakeClaudeApi throws immediately) → error state
        Assert.Equal(LoginStateKind.Error, manager.LoginState.Kind);

        // A subsequent poll tick with the still-live session cookie must be ignored.
        web.RaiseCookiesObserved(SessionCookies());
        Assert.False(manager.HasCapturedSession);
        Assert.Equal(LoginStateKind.Error, manager.LoginState.Kind);
        Assert.Empty(store.Accounts);
    }

    // ---- picker label disambiguation (pure) ----------------------------------------------------

    [Fact]
    public void PickerLabels_DisambiguateGenericAndDuplicateNames()
    {
        var orgs = new[]
        {
            Org("a"),                      // no name → "Organization 1"
            Org("b", name: "Acme"),
            Org("c", name: "Acme"),        // duplicate display name → "Acme (2)"
            Org("d"),                      // → "Organization 4"
        };

        var labels = OrgPickerView.BuildDisambiguatedLabels(orgs);

        Assert.Equal("Organization 1", labels[0]);
        Assert.Equal("Acme", labels[1]);
        Assert.Equal("Acme (2)", labels[2]);
        Assert.Equal("Organization 4", labels[3]);
    }
}
