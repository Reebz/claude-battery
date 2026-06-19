using System.IO;
using System.Net;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U6/U7 lifecycle tests for <see cref="AuthManager"/>, exercised through the injectable
/// <see cref="FakeLoginWebView"/> / <see cref="FakeOrgPicker"/> / <see cref="FakeClaudeApi"/> seams
/// so the full state machine, capture funnel, capture-guard reset, and activity-based timeout run
/// with no real WebView2. These encode documented Mac regressions (the capture-guard lockout and the
/// SPA-late-cookie capture) and are written test-first per the unit's execution note.
/// </summary>
public sealed class AuthManagerTests : IDisposable
{
    private readonly string _root;
    private readonly CookieContainer _jar = new();

    public AuthManagerTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "cbw-auth-tests", Guid.NewGuid().ToString("N"));
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

    private (AuthManager Manager, FakeLoginWebView WebView, FakeOrgPicker Picker, FakeClaudeApi Api, AccountStore Store)
        NewManager(FakeClaudeApi? api = null, TimeSpan? timeout = null)
    {
        var store = NewStore();
        var web = new FakeLoginWebView();
        var factory = new FakeLoginWebViewFactory(web);
        var picker = new FakeOrgPicker();
        api ??= new FakeClaudeApi();
        var manager = new AuthManager(api, store, factory, picker, timeout);
        return (manager, web, picker, api, store);
    }

    // ---- capture funnel: SPA-late cookie -------------------------------------------------------

    [Fact]
    public async Task Capture_SucceedsWhenSessionCookieAppearsOnlyAfterSpaRouteChange()
    {
        var api = new FakeClaudeApi { Orgs = new[] { Org("org-1") } };
        var (manager, web, _, _, store) = NewManager(api);

        manager.PresentLogin();
        Assert.Equal(LoginStateKind.Idle, manager.LoginState.Kind);

        // First navigation: no session cookie yet (still on the login page).
        web.RaiseNavigationCompleted(new[] { Cookie("__cf_bm", "cf"), }, ua: "UA/Test");
        Assert.False(manager.HasCapturedSession);

        // SPA route change after auth: the HttpOnly sessionKey now appears. HistoryChanged is the
        // capture trigger (no full navigation fires). Mac KVO-on-url path.
        web.RaiseHistoryChanged(new[]
        {
            Cookie("sessionKey", "sk-live"),
            Cookie("__cf_bm", "cf"),
        });

        await manager.LastDiscoveryTask!;

        Assert.Equal(LoginStateKind.Active, manager.LoginState.Kind);
        Assert.Single(store.Accounts);
        Assert.Equal("org-1", store.Accounts[0].OrganizationId);
        Assert.False(manager.HasActiveLoginWebView); // closed only on success
        Assert.True(web.Disposed);
    }

    [Fact]
    public void Capture_RejectsNonSecureOrWrongPathSessionCookie()
    {
        var (manager, web, _, _, _) = NewManager();
        manager.PresentLogin();

        // Right name + domain but not Secure: must NOT capture (Mac handleCookieCaptured rejects).
        web.RaiseCookiesObserved(new[] { Cookie("sessionKey", "sk", isSecure: false) });
        Assert.False(manager.HasCapturedSession);

        // Right name + domain + Secure but wrong path: must NOT capture.
        web.RaiseCookiesObserved(new[] { Cookie("sessionKey", "sk", path: "/app") });
        Assert.False(manager.HasCapturedSession);

        // Wrong domain (lookalike): must NOT capture.
        web.RaiseCookiesObserved(new[] { Cookie("sessionKey", "sk", domain: "evil-claude.ai") });
        Assert.False(manager.HasCapturedSession);
    }

    [Fact]
    public async Task Capture_BuildsFullCookieHeaderFromAllClaudeCookies()
    {
        var api = new FakeClaudeApi { Orgs = new[] { Org("org-1") } };
        var (manager, web, _, _, store) = NewManager(api);
        manager.PresentLogin();

        web.RaiseCookiesObserved(new[]
        {
            Cookie("sessionKey", "sk-live"),
            Cookie("__cf_bm", "cf-value"),
            Cookie("ajs_user_id", "u123", domain: ".claude.ai"),
            Cookie("ignored", "x", domain: "accounts.google.com"), // not a claude cookie
        });

        await manager.LastDiscoveryTask!;

        // The captured header carries every .claude.ai cookie (incl. HttpOnly __cf_bm), not
        // sessionKey alone, and excludes non-claude-domain cookies. It is persisted on the account.
        var header = store.Accounts[0].AllCookieHeader;
        Assert.NotNull(header);
        Assert.Contains("sessionKey=sk-live", header);
        Assert.Contains("__cf_bm=cf-value", header);
        Assert.Contains("ajs_user_id=u123", header);
        Assert.DoesNotContain("ignored=", header);
        Assert.True(api.LastOrganizationsCallSeen);
    }

    // ---- cancel during capture: guard reset, no dangling mutation ------------------------------

    [Fact]
    public async Task ClosingDuringCapture_CancelsPendingTaskAndReturnsToIdle()
    {
        // A discovery that never completes on its own - the close must cancel it.
        var api = new FakeClaudeApi { OrganizationsGate = new TaskCompletionSource<IReadOnlyList<Organization>>() };
        var (manager, web, _, _, store) = NewManager(api);
        manager.PresentLogin();

        web.RaiseCookiesObserved(new[] { Cookie("sessionKey", "sk"), Cookie("__cf_bm", "cf") });
        // Capture kicks off discovery synchronously up to the gated await, so the in-flight state
        // is OrgDiscovery (the gate never completes on its own - the close below must cancel it).
        Assert.Equal(LoginStateKind.OrgDiscovery, manager.LoginState.Kind);

        // User closes the window mid-discovery.
        web.RaiseClosed();

        Assert.Equal(LoginStateKind.Idle, manager.LoginState.Kind);
        Assert.False(manager.HasCapturedSession); // guard reset so retry can capture again
        Assert.Empty(store.Accounts);

        // The discovery task observed the cancelled token (the gate's registration set it canceled
        // on teardown) and must complete without mutating state. A late result is a no-op.
        api.OrganizationsGate.TrySetResult(new[] { Org("org-late") });
        await manager.LastDiscoveryTask!; // completes without throwing/mutating

        Assert.Equal(LoginStateKind.Idle, manager.LoginState.Kind);
        Assert.Empty(store.Accounts); // the late result never added an account
    }

    // ---- activity-based timeout ----------------------------------------------------------------

    [Fact]
    public void Timeout_ReArmsOnEachNavigation()
    {
        var (manager, web, _, _, _) = NewManager(timeout: TimeSpan.FromSeconds(30));
        manager.PresentLogin();

        var first = manager.LastTimeoutTask;
        Assert.NotNull(first);

        // Each navigation re-arms: a fresh timeout task supersedes the prior one (which is cancelled).
        web.RaiseNavigationCompleted(Array.Empty<CapturedCookie>(), ua: "UA/Test");
        var second = manager.LastTimeoutTask;
        Assert.NotSame(first, second);

        web.RaiseNavigationCompleted(Array.Empty<CapturedCookie>(), ua: "UA/Test");
        var third = manager.LastTimeoutTask;
        Assert.NotSame(second, third);
    }

    [Fact]
    public async Task Timeout_PersistentChallengeEndsTerminalNotInfiniteSpinner()
    {
        // A very short timeout simulates a persistent Cloudflare challenge: the user never captures.
        var (manager, web, _, _, _) = NewManager(timeout: TimeSpan.FromMilliseconds(40));
        manager.PresentLogin();
        Assert.True(manager.HasActiveLoginWebView);

        await manager.LastTimeoutTask!;

        // Terminal idle + window torn down - NOT a stuck signing-in spinner.
        Assert.Equal(LoginStateKind.Idle, manager.LoginState.Kind);
        Assert.False(manager.HasActiveLoginWebView);
        Assert.True(web.Disposed);
    }

    // ---- popup routing: separate WebView with its own gate -------------------------------------

    [Fact]
    public void NewWindowRequested_AllowsOAuthHostWithPopupGate_BlocksOthers()
    {
        var (manager, web, _, _, _) = NewManager();
        manager.PresentLogin();

        var allowed = web.RaiseNewWindowRequested("https://accounts.google.com/o/oauth2/auth");
        Assert.True(allowed.Allowed);
        Assert.NotNull(allowed.PopupNavigationGate);
        // The popup's own gate enforces the same allowlist so it cannot wander after the bootstrap.
        Assert.True(allowed.PopupNavigationGate!("https://accounts.google.com/signin"));
        Assert.False(allowed.PopupNavigationGate!("https://evil.example.com/"));

        var blocked = web.RaiseNewWindowRequested("https://evil.example.com/popup");
        Assert.False(blocked.Allowed);
    }

    // ---- main-frame navigation gate ------------------------------------------------------------

    [Fact]
    public void NavigationStarting_AllowsClaudeAndAboutBlank_BlocksOthers()
    {
        var (manager, web, _, _, _) = NewManager();
        manager.PresentLogin();

        Assert.True(web.RaiseNavigationStarting("https://claude.ai/login"));
        Assert.True(web.RaiseNavigationStarting("about:blank"));
        Assert.False(web.RaiseNavigationStarting("https://evil-claude.ai/"));
    }

    // ---- UA capture ----------------------------------------------------------------------------

    [Fact]
    public void UserAgent_CapturedOnceAfterFirstNavigationCompleted()
    {
        var (manager, web, _, _, _) = NewManager();
        manager.PresentLogin();
        Assert.Null(manager.CapturedUserAgent);

        web.RaiseNavigationCompleted(Array.Empty<CapturedCookie>(), ua: "Mozilla/5.0 Edge/Test");
        Assert.Equal("Mozilla/5.0 Edge/Test", manager.CapturedUserAgent);

        // A later navigation with a different UA does not overwrite the first captured one.
        web.RaiseNavigationCompleted(Array.Empty<CapturedCookie>(), ua: "Mozilla/5.0 Other");
        Assert.Equal("Mozilla/5.0 Edge/Test", manager.CapturedUserAgent);
    }

    // ---- WebView2 init failure surface (U6 / issue #6) -----------------------------------------

    [Fact]
    public void WebView2InitFailure_ShowsErrorStateWithRetry_NotSilentBlankWindow()
    {
        var (manager, web, _, _, _) = NewManager();
        manager.PresentLogin();

        // The host could not start WebView2 (runtime/profile error). It must surface a visible error
        // with retry, not leave a blank window with a spinning poll.
        web.RaiseInitFailed("Could not start the sign-in browser. Please try again.");

        Assert.Equal(LoginStateKind.Error, manager.LoginState.Kind);
        Assert.Equal("Could not start the sign-in browser. Please try again.", manager.LoginState.Message);
        Assert.False(manager.HasCapturedSession);     // capture guard reset so a retry can capture
        Assert.True(manager.HasActiveLoginWebView);   // window stays open showing the error + retry
    }

    // ---- re-auth generation bump (U5 / issue #18) ----------------------------------------------

    [Fact]
    public async Task ReAuth_OfActiveAccount_BumpsGenerationExactlyOnce()
    {
        var api = new FakeClaudeApi { Orgs = new[] { Org("org-1") } };
        var (manager, web, _, _, store) = NewManager(api);

        // Seed an active account for org-1 (the first account auto-activates inside UpsertAccount).
        store.UpsertAccount(new Account { Email = "a@x.com", SessionKey = "old", OrganizationId = "org-1" });
        Assert.Equal("org-1", store.ActiveAccount!.OrganizationId);

        var genBefore = store.CurrentGeneration;
        var changes = 0;
        store.ActiveAccountChanged += () => changes++;

        // Log in again; discovery finds org-1 -> re-auth in place. UpsertAccount re-primes + bumps
        // ONCE for the active account; the manager must not bump again via a redundant SwitchTo.
        manager.PresentLogin();
        web.RaiseCookiesObserved(new[] { Cookie("sessionKey", "sk-new"), Cookie("__cf_bm", "cf") });
        await manager.LastDiscoveryTask!;

        Assert.Equal(LoginStateKind.Active, manager.LoginState.Kind);
        Assert.Single(store.Accounts);                           // re-auth in place, no new account
        Assert.Equal("sk-new", store.ActiveAccount!.SessionKey); // credentials refreshed
        Assert.Equal(1, changes);                                // exactly one bump, not two
        Assert.Equal(genBefore + 1, store.CurrentGeneration);
    }

    [Fact]
    public async Task ReAuth_OfNonActiveAccount_SwitchesToIt_WithOneBump()
    {
        // Mac parity: fetchOrganizationId switches to the logged-in account even when it was not
        // active. The conditional SwitchTo keeps that, and it is a single bump (UpsertAccount does
        // not bump a non-active in-place update).
        var api = new FakeClaudeApi { Orgs = new[] { Org("org-2") } };
        var (manager, web, _, _, store) = NewManager(api);

        store.UpsertAccount(new Account { Email = "a@x.com", SessionKey = "a", OrganizationId = "org-1" }); // active
        store.UpsertAccount(new Account { Email = "b@x.com", SessionKey = "b", OrganizationId = "org-2" }); // not active
        var activeBefore = store.ActiveAccountId;

        var changes = 0;
        store.ActiveAccountChanged += () => changes++;

        manager.PresentLogin();
        web.RaiseCookiesObserved(new[] { Cookie("sessionKey", "b-new"), Cookie("__cf_bm", "cf") });
        await manager.LastDiscoveryTask!;

        Assert.Equal("org-2", store.ActiveAccount!.OrganizationId); // switched to the re-authed account
        Assert.NotEqual(activeBefore, store.ActiveAccountId);
        Assert.Equal("b-new", store.ActiveAccount.SessionKey);
        Assert.Equal(1, changes);                                  // exactly one bump (the SwitchTo)
    }

    // ---- helpers -------------------------------------------------------------------------------

    internal static CapturedCookie Cookie(
        string name, string value, string domain = ".claude.ai", string path = "/",
        bool isSecure = true, bool isHttpOnly = true) =>
        new()
        {
            Name = name,
            Value = value,
            Domain = domain,
            Path = path,
            IsSecure = isSecure,
            IsHttpOnly = isHttpOnly,
        };

    internal static Organization Org(string uuid, string? name = null, string? email = null) =>
        new() { Uuid = uuid, Name = name, EmailAddress = email };
}

// ================================================================================================
// Test doubles shared across AuthManagerTests and OrgDiscoveryTests.
// ================================================================================================

/// A fake login WebView the tests drive directly: it exposes Raise* methods that fire each
/// ILoginWebView event, so the AuthManager funnel runs with no real WebView2.
internal sealed class FakeLoginWebView : ILoginWebView
{
    public bool Disposed { get; private set; }
    public bool Shown { get; private set; }
    public bool PollingStarted { get; private set; }
    public string? LastNavigatedUrl { get; private set; }

    public event Func<string, bool>? NavigationStarting;
    public event Action<NavigationCompletedInfo>? NavigationCompleted;
    public event Action<IReadOnlyList<CapturedCookie>>? HistoryChanged;
    public event Action<IReadOnlyList<CapturedCookie>>? CookiesObserved;
    public event Func<string, NewWindowDecision>? NewWindowRequested;
    public event Action<string>? InitFailed;
    public event Action? Closed;

    event Func<string, bool> ILoginWebView.NavigationStarting
    {
        add => NavigationStarting += value;
        remove => NavigationStarting -= value;
    }

    event Action<NavigationCompletedInfo> ILoginWebView.NavigationCompleted
    {
        add => NavigationCompleted += value;
        remove => NavigationCompleted -= value;
    }

    event Action<IReadOnlyList<CapturedCookie>> ILoginWebView.HistoryChanged
    {
        add => HistoryChanged += value;
        remove => HistoryChanged -= value;
    }

    event Action<IReadOnlyList<CapturedCookie>> ILoginWebView.CookiesObserved
    {
        add => CookiesObserved += value;
        remove => CookiesObserved -= value;
    }

    event Func<string, NewWindowDecision> ILoginWebView.NewWindowRequested
    {
        add => NewWindowRequested += value;
        remove => NewWindowRequested -= value;
    }

    event Action<string> ILoginWebView.InitFailed
    {
        add => InitFailed += value;
        remove => InitFailed -= value;
    }

    event Action ILoginWebView.Closed
    {
        add => Closed += value;
        remove => Closed -= value;
    }

    public void Show() => Shown = true;

    public void Focus()
    {
    }

    public void Navigate(string url) => LastNavigatedUrl = url;

    public void StartCookiePolling() => PollingStarted = true;

    public void Dispose() => Disposed = true;

    public bool RaiseNavigationStarting(string url) => NavigationStarting!.Invoke(url);

    public void RaiseNavigationCompleted(IReadOnlyList<CapturedCookie> cookies, string? ua) =>
        NavigationCompleted?.Invoke(new NavigationCompletedInfo { Cookies = cookies, UserAgent = ua });

    public void RaiseHistoryChanged(IReadOnlyList<CapturedCookie> cookies) => HistoryChanged?.Invoke(cookies);

    public void RaiseCookiesObserved(IReadOnlyList<CapturedCookie> cookies) => CookiesObserved?.Invoke(cookies);

    public NewWindowDecision RaiseNewWindowRequested(string url) => NewWindowRequested!.Invoke(url);

    public void RaiseInitFailed(string message) => InitFailed?.Invoke(message);

    public void RaiseClosed() => Closed?.Invoke();
}

internal sealed class FakeLoginWebViewFactory : ILoginWebViewFactory
{
    private readonly ILoginWebView _instance;

    public FakeLoginWebViewFactory(ILoginWebView instance) => _instance = instance;

    public ILoginWebView Create() => _instance;
}

/// A fake org picker scripted with a fixed choice (or null = cancel). Records that it was asked, and
/// supports the resume-once cancel contract via CancelPending.
internal sealed class FakeOrgPicker : IOrgPicker
{
    /// When set, PickAsync returns this org; null returns null (cancel).
    public Organization? Choice { get; set; }

    /// When set, PickAsync gates on this so a test can drive the timing of the pick.
    public TaskCompletionSource<Organization?>? Gate { get; set; }

    public bool WasAsked { get; private set; }
    public IReadOnlyList<Organization>? PresentedOrgs { get; private set; }

    private TaskCompletionSource<Organization?>? _pending;

    public Task<Organization?> PickAsync(IReadOnlyList<Organization> orgs, CancellationToken cancellationToken)
    {
        WasAsked = true;
        PresentedOrgs = orgs;

        if (Gate is not null)
        {
            _pending = Gate;
            cancellationToken.Register(() => _pending?.TrySetResult(null));
            return Gate.Task;
        }

        return Task.FromResult(Choice);
    }

    public void CancelPending() => _pending?.TrySetResult(null);
}

/// A scriptable IClaudeApi. Org discovery is the path U7 exercises; usage/credits are not used here.
internal sealed class FakeClaudeApi : IClaudeApi
{
    public IReadOnlyList<Organization> Orgs { get; set; } = Array.Empty<Organization>();

    /// When set, GetOrganizationsAsync throws this (e.g. a ClaudeAuthException or a network error).
    public Exception? OrganizationsThrows { get; set; }

    /// When set, GetOrganizationsAsync awaits this gate instead of returning immediately, so a test
    /// can hold discovery open (e.g. to cancel mid-flight).
    public TaskCompletionSource<IReadOnlyList<Organization>>? OrganizationsGate { get; set; }

    public bool LastOrganizationsCallSeen { get; private set; }

    public async Task<IReadOnlyList<Organization>> GetOrganizationsAsync(CancellationToken cancellationToken)
    {
        LastOrganizationsCallSeen = true;

        if (OrganizationsThrows is not null)
        {
            throw OrganizationsThrows;
        }

        if (OrganizationsGate is not null)
        {
            using var reg = cancellationToken.Register(() => OrganizationsGate.TrySetCanceled());
            return await OrganizationsGate.Task.ConfigureAwait(false);
        }

        return Orgs;
    }

    public Task<UsageApiResponse> GetUsageAsync(string organizationId, CancellationToken cancellationToken) =>
        Task.FromResult(new UsageApiResponse());

    public Task<Credits?> GetCreditsAsync(string organizationId, CancellationToken cancellationToken) =>
        Task.FromResult<Credits?>(null);
}
