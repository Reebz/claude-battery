import XCTest
import WebKit
@testable import ClaudeBattery

final class AuthManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var mockSession: MockHTTPSession!

    override func setUp() {
        super.setUp()
        suiteName = "test.AuthManager.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        mockSession = MockHTTPSession()
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        mockSession = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @MainActor
    private func makeAuthManager() -> AuthManager {
        let storage = StorageService(defaults: defaults, prefix: "cb_")
        let accountStore = AccountStore(storage: storage)
        return AuthManager(storage: storage, accountStore: accountStore, session: mockSession)
    }

    /// Create an HTTPCookie with the given properties, defaulting to a valid session cookie.
    private func makeCookie(
        name: String = "sessionKey",
        value: String = "sk-test-value",
        domain: String = "claude.ai",
        path: String = "/",
        isSecure: Bool = true
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if isSecure {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)!
    }

    /// Poll `condition` on the main actor until it is true or `timeout` elapses.
    /// Used for capture paths that hop through async cookie-store reads.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Session capture funnel (U1, #17)
    // Every capture trigger (poll, KVO, navigationResponse, webViewDidClose) routes through
    // captureSessionCookie(from:). These deterministic tests exercise that funnel directly;
    // the real WKWebView store-read on macOS 13.5 is covered by manual QA per the plan.

    @MainActor
    func testCaptureSessionCookie_capturesValidSession() {
        let auth = makeAuthManager()
        auth.captureSessionCookie(from: [makeCookie(value: "sk-funnel")])
        // handleCookieCaptured sets these synchronously before spawning org discovery.
        XCTAssertEqual(auth.pendingSessionKey, "sk-funnel")
        XCTAssertEqual(auth.loginState, .signingIn)
    }

    @MainActor
    func testCaptureSessionCookie_idempotentAcrossTriggers() {
        let auth = makeAuthManager()
        // First trigger captures; a second trigger (e.g. poll firing after webViewDidClose)
        // must not re-capture — critical pattern #3.
        auth.captureSessionCookie(from: [makeCookie(value: "first")])
        auth.captureSessionCookie(from: [makeCookie(value: "second")])
        XCTAssertEqual(auth.pendingSessionKey, "first", "Second capture must be ignored")
    }

    @MainActor
    func testCaptureSessionCookie_rejectsSpoofedDomain() {
        let auth = makeAuthManager()
        auth.captureSessionCookie(from: [makeCookie(domain: "evil-claude.ai")])
        XCTAssertNil(auth.pendingSessionKey, "Spoofed domain must never be captured — pattern #2")
        XCTAssertEqual(auth.loginState, .idle)
    }

    @MainActor
    func testCaptureSessionCookie_ignoresNonSessionCookies() {
        let auth = makeAuthManager()
        auth.captureSessionCookie(from: [
            makeCookie(name: "__cf_bm", value: "cf"),
            makeCookie(name: "anthropic-csrf-token", value: "csrf"),
        ])
        XCTAssertNil(auth.pendingSessionKey)
        XCTAssertEqual(auth.loginState, .idle)
    }

    // MARK: - navigationResponse additive path (U1) — parse + validate logic
    // WKNavigationResponse has no public initializer, so we exercise the header-parsing and
    // domain-validation the delegate performs by feeding the parsed cookies through the funnel.

    @MainActor
    func testCaptureFromResponseHeader_capturesSessionKey() {
        let auth = makeAuthManager()
        let url = URL(string: "https://claude.ai")!
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": "sessionKey=sk-from-header; Domain=.claude.ai; Path=/; Secure"],
            for: url
        )
        auth.captureSessionCookie(from: cookies)
        XCTAssertEqual(auth.pendingSessionKey, "sk-from-header")
    }

    @MainActor
    func testCaptureFromResponseHeader_rejectsSpoofedDomain() {
        let auth = makeAuthManager()
        let url = URL(string: "https://evil-claude.ai")!
        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": "sessionKey=sk-evil; Domain=evil-claude.ai; Path=/; Secure"],
            for: url
        )
        auth.captureSessionCookie(from: cookies)
        XCTAssertNil(auth.pendingSessionKey, "Spoofed Set-Cookie domain must be rejected — pattern #2")
    }

    // MARK: - webViewDidClose re-read (U1) — THE test that gates "fixes #17"
    // Seeds a real non-persistent cookie store with sessionKey, then drives webViewDidClose
    // and asserts the full capture → org-discovery → account chain completes.

    @MainActor
    func testWebViewDidClose_capturesSessionFromLoginStore() async {
        let auth = makeAuthManager()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let loginWebView = WKWebView(frame: .zero, configuration: config)
        await config.websiteDataStore.httpCookieStore.setCookie(makeCookie(value: "sk-popup-close"))
        auth.loginWebView = loginWebView

        // Single org so discovery completes deterministically to one account.
        mockSession.responseData = #"[{"uuid": "org-popup-close"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        // A non-popup webView triggers only the re-read branch, not popup teardown.
        let unrelated = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        auth.webViewDidClose(unrelated)

        await waitUntil { auth.accountStore.accounts.count == 1 }

        XCTAssertEqual(auth.accountStore.accounts.count, 1,
                       "webViewDidClose must re-read the login store and capture the session (#17)")
        XCTAssertEqual(auth.accountStore.accounts.first?.sessionKey, "sk-popup-close")
        XCTAssertEqual(auth.accountStore.accounts.first?.organizationId, "org-popup-close")
    }

    // MARK: - "Finishing sign-in…" overlay (U2)

    @MainActor
    private func makeLoginWebView() -> WKWebView {
        WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: WKWebViewConfiguration())
    }

    @MainActor
    private func hasMountedOverlay(_ webView: WKWebView) -> Bool {
        webView.subviews.contains { $0.identifier == AuthManager.loginOverlayIdentifier }
    }

    @MainActor
    func testOverlay_shownOnSigningIn() {
        let auth = makeAuthManager()
        let webView = makeLoginWebView()
        auth.loginWebView = webView

        auth.showSigningInOverlay()

        XCTAssertEqual(auth.loginOverlayKind, .signingIn)
        XCTAssertTrue(hasMountedOverlay(webView), "Overlay view should be mounted on the login WebView")
    }

    @MainActor
    func testOverlay_noOpWithoutLoginWebView() {
        let auth = makeAuthManager()
        // No loginWebView set — overlay has nowhere to mount and must stay absent.
        auth.showSigningInOverlay()
        XCTAssertEqual(auth.loginOverlayKind, .none)
    }

    @MainActor
    func testOverlay_drivenByLoginStateTransitions() {
        let auth = makeAuthManager()
        let webView = makeLoginWebView()
        auth.loginWebView = webView

        auth.loginState = .signingIn
        XCTAssertEqual(auth.loginOverlayKind, .signingIn, "didSet should show the overlay on .signingIn")

        auth.loginState = .error("boom")
        XCTAssertEqual(auth.loginOverlayKind, .error, "didSet should swap to the error overlay on .error")

        auth.loginState = .idle
        XCTAssertEqual(auth.loginOverlayKind, .none, "didSet should clear the overlay on .idle")
        XCTAssertFalse(hasMountedOverlay(webView))
    }

    @MainActor
    func testOverlay_errorStateOnOrgDiscovery401() async {
        let auth = makeAuthManager()
        let webView = makeLoginWebView()
        auth.loginWebView = webView
        auth.pendingSessionKey = "sk-expired"
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 401

        await auth.fetchOrganizationId()

        XCTAssertEqual(auth.loginOverlayKind, .error,
                       "A 401 during org discovery should surface the recoverable error overlay")
    }

    @MainActor
    func testOverlay_tornDownWhenWindowClosesMidSigningIn() {
        let auth = makeAuthManager()
        let webView = makeLoginWebView()
        auth.loginWebView = webView
        auth.loginState = .signingIn
        XCTAssertEqual(auth.loginOverlayKind, .signingIn)

        // User closes the login window while capture is still finishing.
        auth.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertEqual(auth.loginOverlayKind, .none, "Overlay must be torn down on window close")
        XCTAssertFalse(hasMountedOverlay(webView), "No overlay subview should be retained after teardown")
        XCTAssertEqual(auth.loginState, .idle, "State resets to idle so the user can retry")
    }

    @MainActor
    func testRetryLogin_resetsCaptureState() {
        let auth = makeAuthManager()
        let webView = makeLoginWebView()
        auth.loginWebView = webView
        auth.loginState = .signingIn
        auth.pendingSessionKey = "sk-stale"

        auth.retryLogin()

        XCTAssertNil(auth.pendingSessionKey, "Retry clears the stale pending key")
        XCTAssertEqual(auth.loginOverlayKind, .none)
        XCTAssertEqual(auth.loginState, .idle)
    }

    // MARK: - Forced email-code modal copy (U3)
    // The sheet presentation (z-order, deferred load, re-entrancy) needs a live window and is
    // covered by manual QA; the drift-prone copy is locked down here.

    @MainActor
    func testEmailCodeAlert_buttonTitleExact() {
        let alert = AuthManager.makeEmailCodeAlert()
        XCTAssertEqual(alert.buttons.count, 1, "Exactly one button, no click-away dismissal (KTD-1)")
        XCTAssertEqual(alert.buttons.first?.title, "Ok, I'll login with email code")
    }

    @MainActor
    func testEmailCodeAlert_copyGuidesToEmailAndManualFallback() {
        let copy = AuthManager.makeEmailCodeAlert().informativeText
        XCTAssertTrue(copy.contains("enter the code Claude sends you"),
                      "Copy must steer to the email-code path")
        XCTAssertTrue(copy.lowercased().contains("manually under settings"),
                      "Copy must point stuck users (Google/passkey accounts) to the paste floor (G1-B-safe)")
    }

    @MainActor
    func testEmailCodeAlert_copyHasNoEmDash() {
        let alert = AuthManager.makeEmailCodeAlert()
        XCTAssertFalse(alert.informativeText.contains("\u{2014}"), "No em dashes in user-facing copy")
        XCTAssertFalse(alert.messageText.contains("\u{2014}"))
    }

    // MARK: - WebAuthn credentials shim + One Tap suppression (U4)
    // JS runtime behavior is validated by G1 + manual QA; these assert the shim is wired into
    // the config and that its source honors the publicKey gate and the CPU-safe suppression.

    @MainActor
    func testLoginConfiguration_includesCredentialsShimUnconditionally() {
        let auth = makeAuthManager()
        let config = auth.makeLoginConfiguration()
        let sources = config.userContentController.userScripts.map(\.source)
        XCTAssertTrue(
            sources.contains { $0.contains("navigator.credentials") && $0.contains(".publicKey") },
            "Login config must include the WebAuthn shim (ships in release, unlike the netlog script)"
        )
    }

    @MainActor
    func testCredentialsShim_gatesRejectionOnPublicKey() {
        let src = AuthManager.credentialsShimSource
        XCTAssertTrue(src.contains("navigator.credentials.get"))
        XCTAssertTrue(src.contains("navigator.credentials.create"))
        XCTAssertTrue(src.contains("options.publicKey"), "Must gate on publicKey, not blanket-reject")
        XCTAssertTrue(src.contains("return origGet(options)"), "Non-publicKey get must pass through unchanged")
        XCTAssertTrue(src.contains("return origCreate(options)"), "Non-publicKey create must pass through unchanged")
    }

    @MainActor
    func testCredentialsShim_forcesPlatformAuthenticatorUnavailable() {
        let src = AuthManager.credentialsShimSource
        XCTAssertTrue(src.contains("isUserVerifyingPlatformAuthenticatorAvailable"))
        XCTAssertTrue(src.contains("Promise.resolve(false)"))
    }

    @MainActor
    func testCredentialsShim_suppressesOneTapWithCSSNotObserver() {
        let src = AuthManager.credentialsShimSource
        XCTAssertTrue(src.contains("accounts.google.com/gsi"), "Targets the Google One Tap iframe (#7)")
        XCTAssertTrue(src.contains("display: none"), "Hides One Tap via CSS")
        XCTAssertFalse(src.contains("MutationObserver"),
                       "Must not use a subtree MutationObserver — CPU hot-loop risk (issue #11)")
    }

    // MARK: - isSessionCookie: Happy Path — valid sessionKey on claude.ai

    @MainActor
    func testIsSessionCookie_validCookie() {
        let cookie = makeCookie(name: "sessionKey", domain: "claude.ai")
        XCTAssertTrue(AuthManager.isSessionCookie(cookie))
    }

    // MARK: - isSessionCookie: Happy Path — domain with leading dot (.claude.ai)

    @MainActor
    func testIsSessionCookie_dotDomain() {
        let cookie = makeCookie(name: "sessionKey", domain: ".claude.ai")
        XCTAssertTrue(AuthManager.isSessionCookie(cookie))
    }

    // MARK: - isSessionCookie: Error Path — wrong domain (Round 1 regression)

    @MainActor
    func testIsSessionCookie_evilDomainReturnsFalse() {
        let cookie = makeCookie(name: "sessionKey", domain: "evil-claude.ai")
        XCTAssertFalse(AuthManager.isSessionCookie(cookie))
    }

    // MARK: - isSessionCookie: Error Path — wrong cookie name

    @MainActor
    func testIsSessionCookie_wrongNameReturnsFalse() {
        let cookie = makeCookie(name: "otherCookie", domain: "claude.ai")
        XCTAssertFalse(AuthManager.isSessionCookie(cookie))
    }

    // MARK: - isSessionCookie: Error Path — subdomain of claude.ai

    @MainActor
    func testIsSessionCookie_subdomainReturnsFalse() {
        let cookie = makeCookie(name: "sessionKey", domain: "api.claude.ai")
        XCTAssertFalse(AuthManager.isSessionCookie(cookie))
    }

    // MARK: - handleCookieCaptured rejects non-secure cookie
    // handleCookieCaptured checks isSecure and path after isSessionCookie passes.
    // We test this indirectly: a non-secure cookie should not trigger org discovery.

    @MainActor
    func testHandleCookieCaptured_nonSecureCookieDoesNotTriggerOrgDiscovery() {
        let auth = makeAuthManager()

        // Craft a cookie that passes isSessionCookie but fails the secure check
        let cookie = makeCookie(name: "sessionKey", domain: "claude.ai", isSecure: false)

        // handleCookieCaptured is internal via @testable
        auth.handleCookieCaptured(cookie)

        // loginState should remain .idle (no org discovery triggered)
        XCTAssertEqual(auth.loginState, .idle)
    }

    // MARK: - handleCookieCaptured rejects wrong path

    @MainActor
    func testHandleCookieCaptured_wrongPathDoesNotTriggerOrgDiscovery() {
        let auth = makeAuthManager()

        let cookie = makeCookie(name: "sessionKey", domain: "claude.ai", path: "/api")

        auth.handleCookieCaptured(cookie)

        XCTAssertEqual(auth.loginState, .idle)
    }

    // MARK: - fetchOrganizationId: Happy Path — single org creates account

    @MainActor
    func testFetchOrganizationId_singleOrgCreatesAccount() async {
        let auth = makeAuthManager()

        let json = """
        [{"uuid": "org-happy-path-123"}]
        """.data(using: .utf8)!

        mockSession.responseData = json
        mockSession.responseStatusCode = 200

        // Set the pending session key (normally set by handleCookieCaptured)
        auth.pendingSessionKey = "sk-test-fetch-org"

        await auth.fetchOrganizationId()

        let store = auth.accountStore
        XCTAssertEqual(store.accounts.count, 1, "Should have created one account")
        XCTAssertEqual(store.accounts.first?.organizationId, "org-happy-path-123")
        XCTAssertEqual(store.accounts.first?.sessionKey, "sk-test-fetch-org")
        XCTAssertEqual(auth.loginState, .idle, "Should return to idle after success")
    }

    // MARK: - fetchOrganizationId: multiple orgs require a window for the picker

    @MainActor
    func testFetchOrganizationId_multipleOrgsWithNoWindowFailsGracefully() async {
        let auth = makeAuthManager()

        let json = """
        [{"uuid": "org-first-111"}, {"uuid": "org-second-222"}]
        """.data(using: .utf8)!

        mockSession.responseData = json
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-multi-org"

        await auth.fetchOrganizationId()

        // With multiple orgs and no login window (test context), the org picker
        // returns nil because loginWindowController is nil. This triggers
        // handleOrgDiscoveryFailure, so no account is created.
        let store = auth.accountStore
        XCTAssertEqual(store.accounts.count, 0,
                       "No account created when org picker has no window")
    }

    // MARK: - fetchOrganizationId: Error Path — 401 sets error state

    @MainActor
    func testFetchOrganizationId_401SetsErrorState() async {
        let auth = makeAuthManager()

        mockSession.responseData = Data()
        mockSession.responseStatusCode = 401
        auth.pendingSessionKey = "sk-expired"

        await auth.fetchOrganizationId()

        if case .error(let message) = auth.loginState {
            XCTAssertTrue(message.contains("Sign-in failed"),
                          "Expected sign-in failure message, got: \(message)")
        } else {
            XCTFail("Expected .error state, got \(auth.loginState)")
        }

        // pendingSessionKey should be cleared
        XCTAssertNil(auth.pendingSessionKey)
    }

    // MARK: - fetchOrganizationId: Error Path — 403 sets error state

    @MainActor
    func testFetchOrganizationId_403SetsErrorState() async {
        let auth = makeAuthManager()

        mockSession.responseData = Data()
        mockSession.responseStatusCode = 403
        auth.pendingSessionKey = "sk-forbidden"

        await auth.fetchOrganizationId()

        if case .error(let message) = auth.loginState {
            XCTAssertTrue(message.contains("Sign-in failed"),
                          "Expected sign-in failure message, got: \(message)")
        } else {
            XCTFail("Expected .error state, got \(auth.loginState)")
        }
    }

    // MARK: - fetchOrganizationId: Error Path — empty orgs array

    @MainActor
    func testFetchOrganizationId_emptyOrgsArraySetsError() async {
        let auth = makeAuthManager()

        let json = "[]".data(using: .utf8)!
        mockSession.responseData = json
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-no-orgs"

        await auth.fetchOrganizationId()

        if case .error(let message) = auth.loginState {
            XCTAssertTrue(message.lowercased().contains("no organizations"),
                          "Expected 'no organizations' message, got: \(message)")
        } else {
            XCTFail("Expected .error state, got \(auth.loginState)")
        }

        XCTAssertNil(auth.pendingSessionKey)
    }

    // MARK: - fetchOrganizationId: Error Path — nil pendingSessionKey

    @MainActor
    func testFetchOrganizationId_nilSessionKeyReturnsToIdle() async {
        let auth = makeAuthManager()

        // Do not set pendingSessionKey
        auth.pendingSessionKey = nil

        await auth.fetchOrganizationId()

        XCTAssertEqual(auth.loginState, .idle)
        XCTAssertEqual(mockSession.capturedRequests.count, 0,
                       "Should not make any network request without a session key")
    }

    // MARK: - fetchOrganizationId: Error Path — network error sets error state

    @MainActor
    func testFetchOrganizationId_networkErrorSetsErrorState() async {
        let auth = makeAuthManager()

        mockSession.responseError = URLError(.notConnectedToInternet)
        auth.pendingSessionKey = "sk-offline"

        await auth.fetchOrganizationId()

        if case .error(let message) = auth.loginState {
            XCTAssertTrue(message.contains("Connection error"),
                          "Expected connection error message, got: \(message)")
        } else {
            XCTFail("Expected .error state, got \(auth.loginState)")
        }

        XCTAssertNil(auth.pendingSessionKey)
    }

    // MARK: - fetchOrganizationId: Re-auth updates existing account

    @MainActor
    func testFetchOrganizationId_reAuthUpdatesExistingAccount() async {
        let auth = makeAuthManager()
        let store = auth.accountStore

        // Pre-populate an account with the same org ID
        let existing = Account(
            email: "existing@test.com",
            sessionKey: "sk-old-key",
            organizationId: "org-reauth-456"
        )
        _ = store.addAccount(existing)
        XCTAssertEqual(store.accounts.count, 1)

        // Now simulate re-auth returning the same org
        let json = """
        [{"uuid": "org-reauth-456"}]
        """.data(using: .utf8)!

        mockSession.responseData = json
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-refreshed-key"

        await auth.fetchOrganizationId()

        // Should still have one account, not two
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.sessionKey, "sk-refreshed-key",
                       "Session key should be updated on re-auth")
        XCTAssertEqual(auth.loginState, .idle)
    }

    // MARK: - LoginState equality

    func testLoginStateEquality() {
        XCTAssertEqual(LoginState.idle, LoginState.idle)
        XCTAssertEqual(LoginState.signingIn, LoginState.signingIn)
        XCTAssertEqual(LoginState.error("foo"), LoginState.error("foo"))
        XCTAssertNotEqual(LoginState.idle, LoginState.signingIn)
        XCTAssertNotEqual(LoginState.error("a"), LoginState.error("b"))
    }
}
