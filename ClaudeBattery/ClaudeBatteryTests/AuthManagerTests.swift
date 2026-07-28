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
        // Manual-sign-in tests prime the process-wide shared cookie jar via activateCookies;
        // start every test from a clean jar so there is no cross-test order dependency.
        ClaudeAPI.clearClaudeCookies()
    }

    override func tearDown() {
        ClaudeAPI.clearClaudeCookies()
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

    /// Poll `condition` on the main actor until it is true or `timeout` elapses. Returns whether
    /// the condition was met, so a timeout is a legible failure rather than a silent fall-through
    /// into a downstream assertion. Used for capture paths that hop through async store reads.
    @discardableResult
    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
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

    // MARK: - navigationResponse Set-Cookie parsing seam (U1 additive path + session-fixation guard)
    // WKNavigationResponse has no public init, so the delegate routes header parsing through the
    // static sessionCookies(fromResponseHeaders:url:) seam — exercised directly here. The delegate
    // additionally gates on the RESPONSE host being claude.ai itself.

    @MainActor
    func testSessionCookies_parsesClaudeSessionKeyFromHeader() {
        let url = URL(string: "https://claude.ai/login")!
        let cookies = AuthManager.sessionCookies(
            fromResponseHeaders: ["Set-Cookie": "sessionKey=sk-from-header; Domain=.claude.ai; Path=/; Secure"],
            url: url
        )
        XCTAssertTrue(cookies.contains { AuthManager.isSessionCookie($0) && $0.value == "sk-from-header" })
    }

    @MainActor
    func testSessionCookies_rejectsCrossDomainInjection() {
        // Session-fixation guard (pattern #2): a response from an allowlisted third party
        // (accounts.google.com) carrying Set-Cookie: sessionKey; Domain=.claude.ai must NOT yield
        // a claude.ai cookie, because the declared Domain= does not belong to the response host.
        let url = URL(string: "https://accounts.google.com/o/oauth2/callback")!
        let cookies = AuthManager.sessionCookies(
            fromResponseHeaders: ["Set-Cookie": "sessionKey=sk-INJECTED; Domain=.claude.ai; Path=/; Secure"],
            url: url
        )
        XCTAssertFalse(cookies.contains { $0.name == "sessionKey" },
                       "A cross-domain Domain=.claude.ai injection must be pinned out")
    }

    @MainActor
    func testSessionCookies_injectionNeverReachesCapture() {
        let auth = makeAuthManager()
        let url = URL(string: "https://accounts.google.com/x")!
        let cookies = AuthManager.sessionCookies(
            fromResponseHeaders: ["Set-Cookie": "sessionKey=sk-INJECTED; Domain=.claude.ai; Path=/; Secure"],
            url: url
        )
        auth.captureSessionCookie(from: cookies)
        XCTAssertNil(auth.pendingSessionKey, "Injected cross-domain sessionKey must never be captured")
    }

    @MainActor
    func testCookieDomainMatchesHost_exactLabelOnly() {
        XCTAssertTrue(AuthManager.cookieDomainMatchesHost(".claude.ai", host: "claude.ai"))
        XCTAssertTrue(AuthManager.cookieDomainMatchesHost("claude.ai", host: "claude.ai"))
        XCTAssertTrue(AuthManager.cookieDomainMatchesHost(".claude.ai", host: "api.claude.ai"))
        XCTAssertFalse(AuthManager.cookieDomainMatchesHost(".claude.ai", host: "evil-claude.ai"),
                       "evil-claude.ai must not match .claude.ai — pattern #2")
        XCTAssertFalse(AuthManager.cookieDomainMatchesHost(".claude.ai", host: "claude.ai.attacker.com"))
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

        // Real WKWebView + async non-persistent store read; give it a CI-safe window and assert
        // the wait result so a timeout reports as a distinct failure, not a silent "0 accounts".
        let captured = await waitUntil(timeout: 20) { auth.accountStore.accounts.count == 1 }

        XCTAssertTrue(captured, "webViewDidClose did not capture within timeout (#17 integration path)")
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

    // MARK: - Manual paste sign-in (U5 — the universal floor)

    @MainActor
    func testParsePastedCredentials_fullHeader() {
        let parsed = AuthManager.parsePastedCredentials("sessionKey=sk-123; __cf_bm=cf-abc; other=x")
        XCTAssertEqual(parsed?.sessionKey, "sk-123")
        XCTAssertEqual(parsed?.cookieHeader, "sessionKey=sk-123; __cf_bm=cf-abc; other=x")
    }

    @MainActor
    func testParsePastedCredentials_bareKey() {
        let parsed = AuthManager.parsePastedCredentials("  sk-ant-sid01-bare  ")
        XCTAssertEqual(parsed?.sessionKey, "sk-ant-sid01-bare")
        XCTAssertNil(parsed?.cookieHeader, "A bare key carries no full header")
    }

    @MainActor
    func testParsePastedCredentials_garbageReturnsNil() {
        XCTAssertNil(AuthManager.parsePastedCredentials("hello there this is not a cookie"))
        XCTAssertNil(AuthManager.parsePastedCredentials(""))
        XCTAssertNil(AuthManager.parsePastedCredentials("sessionKey="), "Empty sessionKey value is unusable")
    }

    @MainActor
    func testManualSignIn_garbageDoesNotHitNetwork() async {
        let auth = makeAuthManager()
        let result = await auth.manualSignIn("not a cookie header")
        XCTAssertEqual(result, .invalidInput)
        XCTAssertEqual(mockSession.capturedRequests.count, 0, "Invalid input must short-circuit before any request")
        XCTAssertEqual(auth.accountStore.accounts.count, 0)
    }

    @MainActor
    func testManualSignIn_fullHeaderSingleOrgAddsAccountWithFullHeader() async {
        let auth = makeAuthManager()
        mockSession.responseData = #"[{"uuid": "org-manual-1"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-manual; __cf_bm=cf-xyz")

        XCTAssertEqual(result, .success("Account 1", refreshedCount: 0),
                       "a first add repairs nothing, so the count is zero and the message stays plain (R6)")
        XCTAssertEqual(auth.accountStore.accounts.count, 1)
        XCTAssertEqual(auth.accountStore.accounts.first?.sessionKey, "sk-manual")
        XCTAssertEqual(auth.accountStore.accounts.first?.allCookieHeader,
                       "sessionKey=sk-manual; __cf_bm=cf-xyz",
                       "Full header must be persisted so HttpOnly __cf_bm survives")
    }

    @MainActor
    func testManualSignIn_bareKey403SuggestsFullHeader() async {
        let auth = makeAuthManager()
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 403

        let result = await auth.manualSignIn("sk-ant-bare-key")

        XCTAssertEqual(result, .authFailed(suggestFullHeader: true),
                       "Bare key + 403 is most likely a Cloudflare block; steer to the full header")
        XCTAssertEqual(auth.accountStore.accounts.count, 0)
    }

    @MainActor
    func testManualSignIn_fullHeader403DoesNotSuggestFullHeader() async {
        let auth = makeAuthManager()
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 403

        let result = await auth.manualSignIn("sessionKey=sk-x; __cf_bm=cf")

        XCTAssertEqual(result, .authFailed(suggestFullHeader: false),
                       "A full header already has __cf_bm; a 403 means stale credentials, not a missing cookie")
    }

    @MainActor
    func testManualSignIn_401AuthFailed() async {
        let auth = makeAuthManager()
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 401
        let result = await auth.manualSignIn("sessionKey=sk-x; __cf_bm=cf")
        XCTAssertEqual(result, .authFailed(suggestFullHeader: false))
    }

    @MainActor
    func testManualSignIn_emptyOrgs() async {
        let auth = makeAuthManager()
        mockSession.responseData = "[]".data(using: .utf8)!
        mockSession.responseStatusCode = 200
        let result = await auth.manualSignIn("sessionKey=sk-x; __cf_bm=cf")
        XCTAssertEqual(result, .noOrganizations)
        XCTAssertEqual(auth.accountStore.accounts.count, 0)
    }

    // MARK: - extractEmail branches (the org-body -> Account.email path; previously untested)

    @MainActor
    func testManualSignIn_extractsEmailFromModelEmailAddress() async {
        let auth = makeAuthManager()
        mockSession.responseData = #"[{"uuid":"org1","email_address":"model@example.com"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        _ = await auth.manualSignIn("sessionKey=sk-x; __cf_bm=cf")
        XCTAssertEqual(auth.accountStore.accounts.first?.email, "model@example.com")
    }

    @MainActor
    func testManualSignIn_extractsEmailFromRawBillingEmail() async {
        let auth = makeAuthManager()
        mockSession.responseData = #"[{"uuid":"org1","billing_email":"billing@example.com"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        _ = await auth.manualSignIn("sessionKey=sk-x; __cf_bm=cf")
        XCTAssertEqual(auth.accountStore.accounts.first?.email, "billing@example.com")
    }

    @MainActor
    func testManualSignIn_extractsEmailFromNestedBilling() async {
        let auth = makeAuthManager()
        mockSession.responseData = #"[{"uuid":"org1","billing":{"email":"nested@example.com"}}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        _ = await auth.manualSignIn("sessionKey=sk-x; __cf_bm=cf")
        XCTAssertEqual(auth.accountStore.accounts.first?.email, "nested@example.com")
    }

    @MainActor
    func testManualSignIn_emailAddressTakesPrecedenceOverRawKeys() async {
        let auth = makeAuthManager()
        mockSession.responseData = #"[{"uuid":"org1","email_address":"model@example.com","billing_email":"billing@example.com"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        _ = await auth.manualSignIn("sessionKey=sk-x; __cf_bm=cf")
        XCTAssertEqual(auth.accountStore.accounts.first?.email, "model@example.com",
                       "model email_address must win over a raw billing_email")
    }

    @MainActor
    func testManualSignIn_noEmailFallsBackToAccountLabel() async {
        let auth = makeAuthManager()
        mockSession.responseData = #"[{"uuid":"org1"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        _ = await auth.manualSignIn("sessionKey=sk-x; __cf_bm=cf")
        XCTAssertEqual(auth.accountStore.accounts.first?.email, "Account 1",
                       "no email in org body must fall back to the positional account label")
    }

    // MARK: - Org-picker continuation funnel (P2 fix: resume-once / no leak on teardown)

    @MainActor
    func testOrgPickerContinuation_stopLoginWindowResumesSuspendedPickerWithNil() async {
        let auth = makeAuthManager()
        // showOrgPicker needs a real window/sheet (unavailable headless), so drive the funnel it uses
        // directly: a child task suspends on a continuation stored in orgPickerContinuation.
        let picked = Task { @MainActor () -> Organization? in
            await withCheckedContinuation { (cont: CheckedContinuation<Organization?, Never>) in
                auth.orgPickerContinuation = cont
            }
        }
        let stored = await waitUntil { auth.orgPickerContinuation != nil }
        XCTAssertTrue(stored, "continuation should be stored before teardown")

        // Teardown MUST resume the suspended picker with nil (no leaked task) and clear it.
        // Reverting the `resumeOrgPicker(with: nil)` line in stopLoginWindow hangs this test.
        auth.stopLoginWindow()
        let result = await picked.value
        XCTAssertNil(result, "stopLoginWindow must resume the suspended picker with nil")
        XCTAssertNil(auth.orgPickerContinuation, "continuation must be nil after resume")
    }

    @MainActor
    func testOrgPickerContinuation_doubleResumeIsNoOpNotTrap() async {
        let auth = makeAuthManager()
        let picked = Task { @MainActor () -> Organization? in
            await withCheckedContinuation { (cont: CheckedContinuation<Organization?, Never>) in
                auth.orgPickerContinuation = cont
            }
        }
        _ = await waitUntil { auth.orgPickerContinuation != nil }

        auth.resumeOrgPicker(with: nil)
        let result = await picked.value
        XCTAssertNil(result)
        XCTAssertNil(auth.orgPickerContinuation)
        // A SECOND resume (e.g. a late sheet handler after teardown already resumed) must be a
        // harmless no-op, not a CheckedContinuation double-resume trap. Reverting the nil-guard in
        // resumeOrgPicker turns this into a fatalError.
        auth.resumeOrgPicker(with: nil)
        XCTAssertNil(auth.orgPickerContinuation, "double-resume must remain a no-op")
    }

    // MARK: - Capture funnel gated on error state (P2 fix: cancelled login must not auto-recapture)

    @MainActor
    func testCaptureSessionCookie_blockedWhileInErrorState() {
        let auth = makeAuthManager()
        auth.loginState = .error("Sign-in cancelled.")
        // A live session cookie is still in hand after a Cancel; the funnel must NOT re-capture it.
        auth.captureSessionCookie(from: [makeCookie()])
        XCTAssertEqual(auth.loginState, .error("Sign-in cancelled."),
                       "capture must stay blocked in .error (no flip to .signingIn) so Cancel is not undone")
    }

    @MainActor
    func testCaptureSessionCookie_proceedsInNonErrorState() {
        let auth = makeAuthManager()
        mockSession.responseData = #"[{"uuid":"org1"}]"#.data(using: .utf8)!
        auth.loginState = .idle
        auth.captureSessionCookie(from: [makeCookie()])
        XCTAssertEqual(auth.loginState, .signingIn,
                       "in the normal (non-error) state the funnel proceeds and drives .signingIn")
    }

    @MainActor
    func testManualSignIn_multiOrgRequiresPickerNotOrgsZero() async {
        let auth = makeAuthManager()
        mockSession.responseData = #"[{"uuid": "org-a"}, {"uuid": "org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-multi; __cf_bm=cf")

        guard case .needsOrgChoice(let orgs) = result else {
            return XCTFail("Expected needsOrgChoice, got \(result)")
        }
        XCTAssertEqual(orgs.count, 2)
        XCTAssertEqual(auth.accountStore.accounts.count, 0, "Must NOT auto-add orgs[0] for multi-org (pattern #6)")

        // User picks the second org from the SwiftUI picker.
        let completed = auth.completeManualSignIn(org: orgs[1])
        XCTAssertEqual(completed, .success("Account 1", refreshedCount: 0),
                       "org-b was never stored, so this pick added it and repaired nothing (R6)")
        XCTAssertEqual(auth.accountStore.accounts.first?.organizationId, "org-b")
    }

    @MainActor
    func testCompleteManualSignIn_withoutPendingContextIsInvalid() {
        let auth = makeAuthManager()
        let org = Organization(uuid: "org-x", name: nil, billingType: nil, emailAddress: nil)
        XCTAssertEqual(auth.completeManualSignIn(org: org), .invalidInput,
                       "Completing with no stashed context is a programming error, surfaced as invalid")
    }

    @MainActor
    func testManualSignIn_failureRestoresActiveAccountJar() async {
        let auth = makeAuthManager()
        // A healthy active account X whose cookies are primed into the shared jar.
        let x = Account(email: "x@test.com", sessionKey: "sk-X", organizationId: "org-X",
                        allCookieHeader: "sessionKey=sk-X; __cf_bm=cf-X")
        _ = auth.accountStore.addAccount(x)
        auth.accountStore.switchTo(x.id)
        let url = URL(string: "https://claude.ai")!
        func jarSessionKey() -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == "sessionKey" }?.value
        }
        XCTAssertEqual(jarSessionKey(), "sk-X", "Precondition: jar holds the active account")

        // A failed paste for a DIFFERENT account Y (401) must not leave Y's cookies in the jar.
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 401
        let result = await auth.manualSignIn("sessionKey=sk-Y; __cf_bm=cf-Y")

        XCTAssertEqual(result, .authFailed(suggestFullHeader: false))
        XCTAssertEqual(jarSessionKey(), "sk-X",
                       "A failed manual sign-in must restore the working account's cookie jar (P1)")
    }

    @MainActor
    func testManualSignIn_multiOrgRestoresActiveJarWhilePickerShown() async {
        let auth = makeAuthManager()
        let x = Account(email: "x@test.com", sessionKey: "sk-X", organizationId: "org-X",
                        allCookieHeader: "sessionKey=sk-X; __cf_bm=cf-X")
        _ = auth.accountStore.addAccount(x)
        auth.accountStore.switchTo(x.id)
        let url = URL(string: "https://claude.ai")!
        func jarSessionKey() -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == "sessionKey" }?.value
        }
        mockSession.responseData = #"[{"uuid": "org-a"}, {"uuid": "org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-Y; __cf_bm=cf-Y")

        guard case .needsOrgChoice = result else { return XCTFail("Expected needsOrgChoice, got \(result)") }
        XCTAssertEqual(jarSessionKey(), "sk-X",
                       "While the org picker is shown, the active account's jar must be restored (P1 multi-org path)")

        // Completing the pick re-primes the jar to the chosen account.
        _ = auth.completeManualSignIn(org: Organization(uuid: "org-b", name: nil, billingType: nil, emailAddress: nil))
        XCTAssertEqual(jarSessionKey(), "sk-Y", "After choosing an org, the jar holds the new account")
    }

    // MARK: - Issue #41 (R10): the jar restore reads the account active AT restore time
    // Account is a struct, so the old pre-network snapshot was a frozen copy. These three drive the
    // store while the organizations request is in flight, via InFlightHookSession at the bottom of
    // this file, then fail the request so the restore runs.

    @MainActor
    func testManualSignIn_switchDuringFlight_restoresTheAccountActiveNow() async {
        // AE9. Switching accounts mid-paste used to end with the OLD account's cookies written over
        // the new one - the same healthy-account breakage the restore exists to prevent.
        let storage = StorageService(defaults: defaults, prefix: "cb_")
        let accountStore = AccountStore(storage: storage)
        let x = Account(email: "x@test.com", sessionKey: "sk-X", organizationId: "org-X",
                        allCookieHeader: "sessionKey=sk-X; __cf_bm=cf-X")
        let z = Account(email: "z@test.com", sessionKey: "sk-Z", organizationId: "org-Z",
                        allCookieHeader: "sessionKey=sk-Z; __cf_bm=cf-Z")
        _ = accountStore.addAccount(x)
        _ = accountStore.addAccount(z)
        accountStore.switchTo(x.id)
        let url = URL(string: "https://claude.ai")!
        func jarSessionKey() -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == "sessionKey" }?.value
        }
        XCTAssertEqual(jarSessionKey(), "sk-X", "precondition: X is active and primed into the jar")

        // The user switches to Z while the paste is still waiting on the organizations response.
        let session = InFlightHookSession(data: Data(), statusCode: 401) {
            await MainActor.run { accountStore.switchTo(z.id) }
        }
        let auth = AuthManager(storage: storage, accountStore: accountStore, session: session)

        let result = await auth.manualSignIn("sessionKey=sk-Y; __cf_bm=cf-Y")

        XCTAssertEqual(result, .authFailed(suggestFullHeader: false))
        XCTAssertEqual(jarSessionKey(), "sk-Z",
                       "the restore serves the account active NOW, not the one active when the paste began")
    }

    @MainActor
    func testManualSignIn_removeActiveDuringFlight_doesNotRestoreDeletedAccount() async {
        // The entry that was active when the paste began is gone by the time it fails. Restoring the
        // pre-network copy would prime a deleted account's cookies over the entry that inherited
        // active status, leaving the jar serving credentials for an account the app no longer has.
        let storage = StorageService(defaults: defaults, prefix: "cb_")
        let accountStore = AccountStore(storage: storage)
        let x = Account(email: "x@test.com", sessionKey: "sk-X", organizationId: "org-X",
                        allCookieHeader: "sessionKey=sk-X; __cf_bm=cf-X")
        let z = Account(email: "z@test.com", sessionKey: "sk-Z", organizationId: "org-Z",
                        allCookieHeader: "sessionKey=sk-Z; __cf_bm=cf-Z")
        _ = accountStore.addAccount(x)
        _ = accountStore.addAccount(z)
        accountStore.switchTo(x.id)
        let url = URL(string: "https://claude.ai")!
        func jarSessionKey() -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == "sessionKey" }?.value
        }
        XCTAssertEqual(jarSessionKey(), "sk-X", "precondition: X is active and primed into the jar")

        let removedId = x.id
        let session = InFlightHookSession(data: Data(), statusCode: 401) {
            await MainActor.run { accountStore.removeAccount(removedId) }
        }
        let auth = AuthManager(storage: storage, accountStore: accountStore, session: session)

        let result = await auth.manualSignIn("sessionKey=sk-Y; __cf_bm=cf-Y")

        XCTAssertEqual(result, .authFailed(suggestFullHeader: false))
        XCTAssertFalse(accountStore.accounts.contains { $0.id == removedId }, "X really was removed")
        XCTAssertEqual(jarSessionKey(), "sk-Z",
                       "the restore must not re-inject the deleted account's cookies")
    }

    @MainActor
    func testManualSignIn_noChangeDuringFlight_restoreBehavesAsBefore() async {
        // The base case, re-run through the same in-flight seam so the seam itself is not what makes
        // the two above pass: with nothing moved, the live read gives exactly the answer the old
        // snapshot gave, which is what testManualSignIn_failureRestoresActiveAccountJar asserts.
        let storage = StorageService(defaults: defaults, prefix: "cb_")
        let accountStore = AccountStore(storage: storage)
        let x = Account(email: "x@test.com", sessionKey: "sk-X", organizationId: "org-X",
                        allCookieHeader: "sessionKey=sk-X; __cf_bm=cf-X")
        _ = accountStore.addAccount(x)
        accountStore.switchTo(x.id)
        let url = URL(string: "https://claude.ai")!
        func jarSessionKey() -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == "sessionKey" }?.value
        }

        let session = InFlightHookSession(data: Data(), statusCode: 401, duringRequest: {})
        let auth = AuthManager(storage: storage, accountStore: accountStore, session: session)

        let result = await auth.manualSignIn("sessionKey=sk-Y; __cf_bm=cf-Y")

        XCTAssertEqual(result, .authFailed(suggestFullHeader: false))
        XCTAssertEqual(jarSessionKey(), "sk-X",
                       "no switch, no removal: the working account's cookies are still what the jar serves")
    }

    @MainActor
    func testCapture_rejectedWhenLoginTornDownMidStoreRead() async {
        // The post-await liveness guard's reject branch: a store read that resolves AFTER the
        // login is torn down must not capture or sign in (the whole point of the concurrency fix).
        let auth = makeAuthManager()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        await config.websiteDataStore.httpCookieStore.setCookie(makeCookie(value: "sk-late"))
        auth.loginWebView = webView
        mockSession.responseData = #"[{"uuid": "org-late"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        // Trigger a re-read, then tear down (nil loginWebView) synchronously before yielding, so
        // the spawned Task's post-await guard observes the torn-down state.
        auth.webViewDidClose(WKWebView(frame: .zero, configuration: WKWebViewConfiguration()))
        auth.loginWebView = nil

        let captured = await waitUntil(timeout: 2) { auth.accountStore.accounts.count == 1 || auth.pendingSessionKey != nil }
        XCTAssertFalse(captured, "A store read resolving after teardown must not capture or sign in")
        XCTAssertEqual(auth.accountStore.accounts.count, 0)
    }

    // MARK: - Domain allowlist + OAuth popup gate (pattern #2 / #7)

    @MainActor
    func testIsAllowedDomain_tableDriven() {
        let auth = makeAuthManager()
        for host in ["claude.ai", "api.claude.ai", "accounts.google.com", "foo.gstatic.com", "x.challenges.cloudflare.com"] {
            XCTAssertTrue(auth.isAllowedDomain(host), "\(host) should be allowed")
        }
        for host in ["evil-claude.ai", "claude.ai.attacker.com", "notgoogle.com", "google.com.evil.com"] {
            XCTAssertFalse(auth.isAllowedDomain(host), "\(host) must be rejected (pattern #2)")
        }
    }

    @MainActor
    func testIsAllowedDomain_localizedGoogleOAuthCCTLDs() {
        let auth = makeAuthManager()
        // Localized Google OAuth hosts 302 back to accounts.google.com; blocking them
        // dead-ends sign-in on a blank screen in those regions (#17, #25; PR #24).
        for host in ["accounts.google.com.tr", "accounts.google.co.uk",
                     "accounts.google.de", "accounts.google.com.br",
                     "foo.accounts.google.com.tr"] {
            XCTAssertTrue(auth.isAllowedDomain(host), "\(host) should be allowed")
        }
        // Exact/leading-dot matching must still reject spoofs, ccTLDs Google does not
        // serve, and trailing-domain injection. The earlier `labels.last?.count == 2`
        // wildcard would have wrongly accepted accounts.google.io and accounts.google.zz.
        // Fail-closed: case variants and trailing-dot FQDN forms are rejected (WKWebView
        // lowercases the host and strips the trailing dot before this is reached).
        for host in ["evilaccounts.google.com.tr", "accounts.google.io",
                     "accounts.google.zz", "accounts.google.com.tr.evil.com",
                     "ACCOUNTS.GOOGLE.COM.TR", "accounts.google.com.tr."] {
            XCTAssertFalse(auth.isAllowedDomain(host), "\(host) must be rejected (pattern #2)")
        }
    }

    @MainActor
    func testAllowsOAuthPopup_schemeBeforeHost() {
        let auth = makeAuthManager()
        // about: bootstraps have no host and must be allowed BEFORE any host check (pattern #7).
        XCTAssertTrue(auth.allowsOAuthPopup(for: URL(string: "about:blank")!))
        XCTAssertTrue(auth.allowsOAuthPopup(for: URL(string: "about:srcdoc")!))
        XCTAssertTrue(auth.allowsOAuthPopup(for: URL(string: "https://accounts.google.com/o/oauth2")!))
        XCTAssertFalse(auth.allowsOAuthPopup(for: URL(string: "https://evil.com")!))
        XCTAssertFalse(auth.allowsOAuthPopup(for: URL(string: "https://evil-claude.ai")!))
    }

    // MARK: - webViewDidClose popup teardown (U1)

    @MainActor
    func testWebViewDidClose_tearsDownMatchingPopup() {
        let auth = makeAuthManager()
        let login = makeLoginWebView()
        auth.loginWebView = login
        let popup = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        login.addSubview(popup)
        auth.popupWebView = popup

        auth.webViewDidClose(popup)

        XCTAssertNil(auth.popupWebView, "Matching popup should be cleared")
        XCTAssertNil(popup.superview, "Popup should be removed from its superview")
    }

    @MainActor
    func testWebViewDidClose_afterCaptureDoesNotRecapture() {
        let auth = makeAuthManager()
        auth.loginWebView = makeLoginWebView()
        auth.captureSessionCookie(from: [makeCookie(value: "sk-first")])
        XCTAssertEqual(auth.pendingSessionKey, "sk-first")

        // A later popup close must not start a second capture (the !hasCapturedSession guard).
        auth.webViewDidClose(WKWebView(frame: .zero, configuration: WKWebViewConfiguration()))
        XCTAssertEqual(auth.pendingSessionKey, "sk-first", "No re-capture after hasCapturedSession")
    }

    // MARK: - Error overlay affordances (U2 + U5 integration)

    @MainActor
    func testOverlayManualTapped_firesHookAndTearsDown() {
        let auth = makeAuthManager()
        auth.loginWebView = makeLoginWebView()
        auth.loginState = .error("boom")
        var manualRequested = false
        auth.onManualSignInRequested = { manualRequested = true }

        auth.overlayManualTapped()

        XCTAssertTrue(manualRequested, "\"Sign in manually\" must invoke the hook that opens Settings")
        XCTAssertEqual(auth.loginState, .idle)
        XCTAssertEqual(auth.loginOverlayKind, .none, "Overlay torn down")
    }

    @MainActor
    func testOverlayRetryTapped_clearsPendingState() {
        let auth = makeAuthManager()
        auth.loginWebView = makeLoginWebView()
        auth.loginState = .error("boom")
        auth.pendingSessionKey = "sk-stale"

        auth.overlayRetryTapped()

        XCTAssertNil(auth.pendingSessionKey, "Retry clears the stale pending key")
        XCTAssertEqual(auth.loginState, .idle)
        XCTAssertEqual(auth.loginOverlayKind, .none)
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

    // MARK: - selectOrg (pure org-selection rule shared by both sign-in paths, MAINT-3)

    func testSelectOrg_singleOrg_takesIt() {
        let a = Organization(uuid: "org-a", name: nil, billingType: nil, emailAddress: nil)
        guard case .single(let org) = AuthManager.selectOrg(orgs: [a], accounts: []) else {
            return XCTFail("a single org should be selected directly")
        }
        XCTAssertEqual(org.uuid, "org-a")
    }

    func testSelectOrg_multiOrg_oneAlreadyStored_requiresChoice() {
        // Issue #32: the silent auto-match is gone. When one org of a multi-org account is already
        // stored, selectOrg must return .needsChoice (not reuse the stored org) so the picker can
        // offer the second, un-added org.
        let a = Organization(uuid: "org-a", name: nil, billingType: nil, emailAddress: nil)
        let b = Organization(uuid: "org-b", name: nil, billingType: nil, emailAddress: nil)
        let acct = Account(email: "x@test.com", sessionKey: "sk", organizationId: "org-b", allCookieHeader: nil)
        guard case .needsChoice(let choices) = AuthManager.selectOrg(orgs: [a, b], accounts: [acct]) else {
            return XCTFail("one-of-two orgs stored must still require a choice, not silently auto-match")
        }
        XCTAssertEqual(choices.map(\.uuid), ["org-a", "org-b"])
    }

    func testSelectOrg_multiOrg_allAlreadyStored_reportsAllAdded() {
        let a = Organization(uuid: "org-a", name: nil, billingType: nil, emailAddress: nil)
        let b = Organization(uuid: "org-b", name: nil, billingType: nil, emailAddress: nil)
        let acctA = Account(email: "x@test.com", sessionKey: "sk", organizationId: "org-a", allCookieHeader: nil)
        let acctB = Account(email: "x@test.com", sessionKey: "sk", organizationId: "org-b", allCookieHeader: nil)
        guard case .allAlreadyAdded(let orgs) = AuthManager.selectOrg(orgs: [a, b], accounts: [acctA, acctB]) else {
            return XCTFail("every org already stored must report .allAlreadyAdded, not a picker")
        }
        XCTAssertEqual(orgs.map(\.uuid), ["org-a", "org-b"])
    }

    func testSelectOrg_multiOrg_noExistingMatch_requiresChoice_neverOrgsZero() {
        let a = Organization(uuid: "org-a", name: nil, billingType: nil, emailAddress: nil)
        let b = Organization(uuid: "org-b", name: nil, billingType: nil, emailAddress: nil)
        let unrelated = Account(email: "x@test.com", sessionKey: "sk", organizationId: "org-z", allCookieHeader: nil)
        guard case .needsChoice(let choices) = AuthManager.selectOrg(orgs: [a, b], accounts: [unrelated]) else {
            return XCTFail("multi-org with no existing match must require a choice, never blindly orgs[0]")
        }
        XCTAssertEqual(choices.map(\.uuid), ["org-a", "org-b"])
    }

    // MARK: - matchedAccounts (the set one sign-in repairs, R1/KTD1, issue #41)
    // The plural sibling of `matchedAccount`: that one picks the single entry the WebView path
    // switches to, this one names every stored entry the fresh credentials are good for. Pure, so
    // the refresh rule is provable without a network round trip.

    func testMatchedAccounts_returnsOnlyStoredOrgs_inStoredOrder() {
        // Three orgs come back, two are stored. Stored order wins over response order, because the
        // callers write in this order and the active-entry gate reads the ids out of it.
        let orgs = [
            Organization(uuid: "org-a", name: nil, billingType: nil, emailAddress: nil),
            Organization(uuid: "org-b", name: nil, billingType: nil, emailAddress: nil),
            Organization(uuid: "org-c", name: nil, billingType: nil, emailAddress: nil)
        ]
        let acctC = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-c", allCookieHeader: nil)
        let acctA = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-a", allCookieHeader: nil)
        let matched = AuthManager.matchedAccounts(orgs: orgs, accounts: [acctC, acctA])
        XCTAssertEqual(matched.map(\.organizationId), ["org-c", "org-a"],
                       "exactly the two stored orgs, in the order they are stored")
    }

    func testMatchedAccounts_noStoredOrgMatches_returnsEmpty() {
        let orgs = [
            Organization(uuid: "org-a", name: nil, billingType: nil, emailAddress: nil),
            Organization(uuid: "org-b", name: nil, billingType: nil, emailAddress: nil)
        ]
        let unrelated = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-z", allCookieHeader: nil)
        XCTAssertTrue(AuthManager.matchedAccounts(orgs: orgs, accounts: [unrelated]).isEmpty,
                      "credentials that list no stored org repair nothing")
    }

    func testMatchedAccounts_excludesStoredOrgAbsentFromList() {
        // R4: an entry the credentials do not list can never be written to, so it can never be
        // added, removed or reordered by a refresh.
        let orgs = [Organization(uuid: "org-a", name: nil, billingType: nil, emailAddress: nil)]
        let acctA = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-a", allCookieHeader: nil)
        let acctB = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-b", allCookieHeader: nil)
        let matched = AuthManager.matchedAccounts(orgs: orgs, accounts: [acctA, acctB])
        XCTAssertEqual(matched.map(\.organizationId), ["org-a"],
                       "org-b is stored but unlisted, so it stays untouched")
    }

    func testMatchedAccounts_excludesOtherEmailsUnlistedOrg() {
        // AE4: a second claude.ai login's entry is out of the set, so its stored credentials
        // survive a refresh of this login's orgs.
        let orgs = [
            Organization(uuid: "org-a", name: nil, billingType: nil, emailAddress: "me@x.com"),
            Organization(uuid: "org-b", name: nil, billingType: nil, emailAddress: "me@x.com")
        ]
        let mine = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-a", allCookieHeader: nil)
        let theirs = Account(email: "other@y.com", sessionKey: "sk-other", organizationId: "org-other", allCookieHeader: nil)
        let matched = AuthManager.matchedAccounts(orgs: orgs, accounts: [mine, theirs])
        XCTAssertEqual(matched.map(\.organizationId), ["org-a"],
                       "the other email's unlisted org is never in the refreshed set")
    }

    func testMatchedAccounts_duplicateOrgUuidInResponse_yieldsOneEntry() {
        // A repeated uuid in the response must not make the caller write the same entry twice, or
        // the reported count (R6) would overstate what was repaired.
        let orgs = [
            Organization(uuid: "org-a", name: nil, billingType: nil, emailAddress: nil),
            Organization(uuid: "org-a", name: "Acme again", billingType: nil, emailAddress: nil)
        ]
        let acctA = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-a", allCookieHeader: nil)
        XCTAssertEqual(AuthManager.matchedAccounts(orgs: orgs, accounts: [acctA]).count, 1,
                       "one stored entry, one write, however many times the response names its org")
    }

    func testMatchedAccounts_emptyOrgList_returnsEmpty() {
        // The failure mode this guards: an empty list read as "matches everything" would repoint
        // every stored entry at one set of credentials.
        let acctA = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-a", allCookieHeader: nil)
        let acctB = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-b", allCookieHeader: nil)
        XCTAssertTrue(AuthManager.matchedAccounts(orgs: [], accounts: [acctA, acctB]).isEmpty,
                      "no orgs listed means nothing to repair, not everything")
    }

    // MARK: - Issue #32: reach a second org of the same account; jar discipline when all stored

    @MainActor
    func testManualSignIn_addsSecondOrgOfSameAccount() async {
        let auth = makeAuthManager()
        _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-A",
            organizationId: "org-a", organizationName: "Acme", allCookieHeader: "sessionKey=sk-A"))

        mockSession.responseData = #"[{"uuid":"org-a","name":"Acme","email_address":"me@x.com"},{"uuid":"org-b","name":"Beta","email_address":"me@x.com"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf")
        guard case .needsOrgChoice(let orgs) = result else {
            return XCTFail("one org stored, one addable must show the picker, got \(result)")
        }
        XCTAssertEqual(orgs.map(\.uuid), ["org-a", "org-b"])

        let completed = auth.completeManualSignIn(org: orgs[1])
        guard case .success = completed else { return XCTFail("adding org-b should succeed, got \(completed)") }
        XCTAssertEqual(auth.accountStore.accounts.count, 2, "both orgs of the account persist as separate accounts")
        XCTAssertTrue(auth.accountStore.accounts.contains { $0.organizationId == "org-a" })
        XCTAssertTrue(auth.accountStore.accounts.contains { $0.organizationId == "org-b" })
    }

    @MainActor
    func testManualSignIn_pickingStoredOrgReactivatesNoDuplicate() async {
        let auth = makeAuthManager()
        _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-old",
            organizationId: "org-a", allCookieHeader: "sessionKey=sk-old"))

        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-new; __cf_bm=cf")
        guard case .needsOrgChoice(let orgs) = result else { return XCTFail("expected picker, got \(result)") }
        // Re-pick org-a (already stored) to refresh it.
        let completed = auth.completeManualSignIn(org: orgs[0])
        guard case .success = completed else { return XCTFail("reactivating org-a should succeed") }
        XCTAssertEqual(auth.accountStore.accounts.count, 1, "reactivate, not duplicate")
        XCTAssertEqual(auth.accountStore.accounts.first?.sessionKey, "sk-new", "session refreshed")
    }

    @MainActor
    func testManualSignIn_allOrgsStored_activeMatched_refreshesJarBranchA() async {
        let auth = makeAuthManager()
        let url = URL(string: "https://claude.ai")!
        func jarSessionKey() -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == "sessionKey" }?.value
        }
        // Both orgs of the account are stored; the org-a account is active with STALE cookies.
        let a = Account(email: "me@x.com", sessionKey: "sk-stale", organizationId: "org-a",
                        allCookieHeader: "sessionKey=sk-stale; __cf_bm=cf-stale")
        _ = auth.accountStore.addAccount(a)
        let b = Account(email: "me@x.com", sessionKey: "sk-b",
                        organizationId: "org-b", allCookieHeader: "sessionKey=sk-b")
        _ = auth.accountStore.addAccount(b)
        auth.accountStore.switchTo(a.id)
        XCTAssertEqual(jarSessionKey(), "sk-stale", "precondition: jar holds the active account's stale cookies")
        var authSuccessCount = 0
        auth.onAuthSuccess = { authSuccessCount += 1 }

        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")

        XCTAssertEqual(result, .alreadySignedInAllOrgs(refreshedCount: 2, activeAccountRefreshed: true))
        XCTAssertEqual(auth.accountStore.activeAccountId, a.id, "active account unchanged, no switch")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == a.id }?.sessionKey, "sk-fresh",
                       "the active account's stored session is refreshed to the pasted value")
        // Issue #41: the sibling is repaired by the SAME paste. It used to keep sk-b and need a
        // second paste after switching org in Settings.
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == b.id }?.sessionKey, "sk-fresh",
                       "the non-active sibling is refreshed by the same paste")
        XCTAssertEqual(jarSessionKey(), "sk-fresh",
                       "Branch A: the shared jar serves the FRESH cookies, not the stale snapshot (no restore)")
        XCTAssertEqual(authSuccessCount, 1,
                       "the active entry was refreshed, so polling is restarted exactly once (KTD2)")
    }

    @MainActor
    func testManualSignIn_allOrgsStored_activeNotInList_restoresJarBranchB() async {
        let auth = makeAuthManager()
        let url = URL(string: "https://claude.ai")!
        func jarSessionKey() -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == "sessionKey" }?.value
        }
        // Active account C is unrelated to the pasted account (orgs a, b), both already stored.
        let c = Account(email: "c@other.com", sessionKey: "sk-C", organizationId: "org-c",
                        allCookieHeader: "sessionKey=sk-C; __cf_bm=cf-C")
        _ = auth.accountStore.addAccount(c)
        let a = Account(email: "me@x.com", sessionKey: "sk-a", organizationId: "org-a", allCookieHeader: "sessionKey=sk-a")
        _ = auth.accountStore.addAccount(a)
        let b = Account(email: "me@x.com", sessionKey: "sk-b", organizationId: "org-b", allCookieHeader: "sessionKey=sk-b")
        _ = auth.accountStore.addAccount(b)
        auth.accountStore.switchTo(c.id)
        XCTAssertEqual(jarSessionKey(), "sk-C", "precondition: jar holds active account C")
        var authSuccessCount = 0
        auth.onAuthSuccess = { authSuccessCount += 1 }

        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")

        XCTAssertEqual(result, .alreadySignedInAllOrgs(refreshedCount: 2, activeAccountRefreshed: false))
        XCTAssertEqual(auth.accountStore.activeAccountId, c.id, "active account C is unchanged, no silent switch")
        // Issue #41: BOTH background entries are repaired now, not only the first match.
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == a.id }?.sessionKey, "sk-fresh",
                       "background org-a is refreshed")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == b.id }?.sessionKey, "sk-fresh",
                       "background org-b is refreshed by the same paste")
        XCTAssertEqual(jarSessionKey(), "sk-C",
                       "Branch B: the real active account C keeps serving its own cookies (jar restored)")
        XCTAssertEqual(authSuccessCount, 0,
                       "the viewed account was not among those repaired, so nothing restarts its polling")
    }

    @MainActor
    func testManualSignIn_allOrgsStored_threeOrgs_refreshesEveryStoredEntry() async {
        // AE1/R1: one paste repairs every stored org those credentials enumerate. Before issue #41
        // only the matched entry was written and the other two kept their dead keys, so the user
        // had to switch org in Settings and paste the same credentials a second time.
        let auth = makeAuthManager()
        for uuid in ["org-a", "org-b", "org-c"] {
            _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old; __cf_bm=cf-old"))
        }
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")

        XCTAssertEqual(result, .alreadySignedInAllOrgs(refreshedCount: 3, activeAccountRefreshed: true))
        for uuid in ["org-a", "org-b", "org-c"] {
            let acct = auth.accountStore.accounts.first { $0.organizationId == uuid }
            XCTAssertEqual(acct?.sessionKey, "sk-fresh", "\(uuid) must hold the pasted key, not its own stale one")
            XCTAssertEqual(acct?.allCookieHeader, "sessionKey=sk-fresh; __cf_bm=cf-fresh",
                           "\(uuid) takes the fresh cookie header too, not only the key")
        }
    }

    @MainActor
    func testManualSignIn_allOrgsStored_activeOrderedLast_sameOutcome() async {
        // The fixtures elsewhere make the FIRST added entry active, which hides any dependence on
        // stored order. Here the active entry is written last by the loop; the outcome must be
        // identical, because the gate reads the refreshed id set and not the first write (KTD1).
        let auth = makeAuthManager()
        let url = URL(string: "https://claude.ai")!
        func jarSessionKey() -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == "sessionKey" }?.value
        }
        var ids: [String: UUID] = [:]
        for uuid in ["org-a", "org-b", "org-c"] {
            let acct = Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old")
            _ = auth.accountStore.addAccount(acct)
            ids[uuid] = acct.id
        }
        auth.accountStore.switchTo(ids["org-c"]!)
        var authSuccessCount = 0
        auth.onAuthSuccess = { authSuccessCount += 1 }

        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")

        XCTAssertEqual(result, .alreadySignedInAllOrgs(refreshedCount: 3, activeAccountRefreshed: true))
        XCTAssertEqual(auth.accountStore.activeAccountId, ids["org-c"], "still no switch on the manual path")
        XCTAssertEqual(jarSessionKey(), "sk-fresh",
                       "the last-written entry is the active one, so the jar keeps the fresh cookies")
        XCTAssertEqual(authSuccessCount, 1, "the active entry was refreshed, wherever it sits in the array")
    }

    @MainActor
    func testManualSignIn_allOrgsStored_unrelatedEmailEntryUntouched() async {
        // AE4: a second claude.ai login's entry is not in the returned org list, so the refresh
        // cannot reach it and its stored credentials survive byte for byte.
        let auth = makeAuthManager()
        let mine = Account(email: "me@x.com", sessionKey: "sk-a-old", organizationId: "org-a",
                           allCookieHeader: "sessionKey=sk-a-old")
        _ = auth.accountStore.addAccount(mine)
        _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-b-old",
            organizationId: "org-b", allCookieHeader: "sessionKey=sk-b-old"))
        let theirs = Account(email: "other@y.com", sessionKey: "sk-other", organizationId: "org-other",
                             allCookieHeader: "sessionKey=sk-other; __cf_bm=cf-other")
        _ = auth.accountStore.addAccount(theirs)
        auth.accountStore.switchTo(mine.id)

        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")

        XCTAssertEqual(result, .alreadySignedInAllOrgs(refreshedCount: 2, activeAccountRefreshed: true),
                       "only the two listed orgs are repaired; the other login's entry is not counted")
        let after = auth.accountStore.accounts.first { $0.id == theirs.id }
        XCTAssertEqual(after?.sessionKey, "sk-other", "the other login's key is untouched")
        XCTAssertEqual(after?.allCookieHeader, "sessionKey=sk-other; __cf_bm=cf-other",
                       "and so is its cookie header")
    }

    @MainActor
    func testManualSignIn_allOrgsStored_leavesStoredOrgSetUnchanged() async {
        // R4: repair only. The refresh adds no org, removes none, and reorders none.
        let auth = makeAuthManager()
        for uuid in ["org-a", "org-b", "org-c"] {
            _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old"))
        }
        let before = auth.accountStore.accounts.map(\.organizationId)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        _ = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")

        XCTAssertEqual(auth.accountStore.accounts.count, 3, "no entry added or removed by a refresh")
        XCTAssertEqual(auth.accountStore.accounts.map(\.organizationId), before,
                       "the stored orgs are the same, in the same order")
    }

    @MainActor
    func testManualSignIn_allOrgsStored_firesSuccessCallbackOncePerPaste() async {
        // KTD2: onAuthSuccess is wired to the polling service's account switch, which clears the
        // cached usage and chains a restart. Three matching entries must still fire it once, or the
        // popover blanks three times and three restarts race.
        let auth = makeAuthManager()
        for uuid in ["org-a", "org-b", "org-c"] {
            _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old"))
        }
        var authSuccessCount = 0
        auth.onAuthSuccess = { authSuccessCount += 1 }
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        _ = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")

        XCTAssertEqual(authSuccessCount, 1, "one paste, one success callback, however many entries it repaired")
    }

    @MainActor
    func testManualSignIn_allOrgsStored_threeOrgs_confirmationNamesTheCount() async {
        // AE2 (R6). This branch is taken at any N >= 2, as it always was, but the result no longer
        // stops at "which branch": it carries the number the user is shown. Before #41 the message
        // was "Refreshed the session" while two of the three entries still held dead keys.
        let auth = makeAuthManager()
        for uuid in ["org-a", "org-b", "org-c"] {
            _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)"))
        }
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf")

        guard case .alreadySignedInAllOrgs(let count, let activeRefreshed) = result else {
            return XCTFail("expected the all-already-stored branch, got \(result)")
        }
        XCTAssertEqual(count, 3, "all three stored entries were repaired by the one paste")
        XCTAssertTrue(activeRefreshed, "the first added entry is active and its org is in the list")
        // Settings builds its status line from exactly these two values, so the message the user
        // reads is asserted here (there are no view-body tests in this project, KTD9).
        XCTAssertEqual(AuthManager.repairConfirmation(refreshedCount: count,
                                                      viewedAccountRepaired: activeRefreshed),
                       "Refreshed 3 organizations.")
    }

    @MainActor
    func testManualSignIn_atEntryLimit_allOrgsStored_repairsRatherThanReportingTheLimit() async {
        // F5 (R7/R9): a full store is the case where the paste box used to be hidden, so this route
        // was unreachable exactly when it was needed most. A refresh consumes no slot, so being at
        // the limit is irrelevant here: every stored entry is repaired and none is added.
        let auth = makeAuthManager()
        var stored: [Account] = []
        for i in 0..<AccountStore.maxAccounts {
            let acct = Account(email: "me@x.com", sessionKey: "sk-\(i)-old", organizationId: "org-\(i)",
                               allCookieHeader: "sessionKey=sk-\(i)-old; __cf_bm=cf-\(i)")
            XCTAssertTrue(auth.accountStore.addAccount(acct), "fixture must fill the store to the limit")
            stored.append(acct)
        }
        let listed = stored.map { #"{"uuid":"\#($0.organizationId)"}"# }
        mockSession.responseData = "[\(listed.joined(separator: ","))]".data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")

        XCTAssertEqual(result, .alreadySignedInAllOrgs(refreshedCount: AccountStore.maxAccounts,
                                                       activeAccountRefreshed: true),
                       "a full store still refreshes; it must not report the add limit")
        XCTAssertEqual(auth.accountStore.accounts.count, AccountStore.maxAccounts, "nothing added")
        for acct in stored {
            XCTAssertEqual(auth.accountStore.accounts.first { $0.id == acct.id }?.sessionKey, "sk-fresh",
                           "\(acct.organizationId) is repaired even with every slot taken")
        }
    }

    // MARK: - Issue #41 U3: the manual PICKER route repairs the picked org's stored siblings
    // The picker appears when at least one org is addable (issue #32). Picking a stored org used
    // to repair only that one, so a user with two stored orgs and a third visible had to pick,
    // paste, switch org in Settings and paste again. The sibling loop runs behind the success
    // check and after switchTo (KTD3), reading the org list carried on the pending context (KTD5).

    @MainActor
    func testCompleteManualSignIn_pickingStoredOrg_refreshesStoredSiblings() async {
        // AE3: two orgs stored, a third visible but never added. Picking a stored org repairs its
        // stored sibling in the same action, and does NOT add the unstored org (R4, D1).
        let auth = makeAuthManager()
        let a = Account(email: "me@x.com", sessionKey: "sk-a-old", organizationId: "org-a",
                        allCookieHeader: "sessionKey=sk-a-old; __cf_bm=cf-a")
        _ = auth.accountStore.addAccount(a)
        let b = Account(email: "me@x.com", sessionKey: "sk-b-old", organizationId: "org-b",
                        allCookieHeader: "sessionKey=sk-b-old; __cf_bm=cf-b")
        _ = auth.accountStore.addAccount(b)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")
        guard case .needsOrgChoice(let orgs) = result else {
            return XCTFail("one addable org must still show the picker, got \(result)")
        }

        let completed = auth.completeManualSignIn(org: orgs[0])
        guard case .success = completed else {
            return XCTFail("picking the stored org-a should succeed, got \(completed)")
        }
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == a.id }?.sessionKey, "sk-fresh",
                       "the picked entry is refreshed, as it always was")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == b.id }?.sessionKey, "sk-fresh",
                       "and its stored sibling is repaired by the same pick (R2, issue #41)")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == b.id }?.allCookieHeader,
                       "sessionKey=sk-fresh; __cf_bm=cf-fresh",
                       "the sibling takes the fresh cookie header too, not only the key")
        XCTAssertEqual(auth.accountStore.accounts.count, 2, "a repair adds no entry")
        XCTAssertFalse(auth.accountStore.accounts.contains { $0.organizationId == "org-c" },
                       "org-c was visible but never stored, and a pick must not add it")
        XCTAssertEqual(auth.accountStore.activeAccountId, a.id,
                       "the pick route switches to the picked org, which is pre-existing behaviour (R3)")
    }

    @MainActor
    func testCompleteManualSignIn_pickingStoredOrg_jarServesPickedAccountNotSibling() async {
        // KTD3 as the jar sees it. A bare-key paste keeps each entry's own non-session cookies
        // (updateSessionKey substitutes the key inside the stored header), so the two entries end
        // up with DIFFERENT __cf_bm values and the jar can say which one primed it. switchTo of the
        // picked account must stay the last jar-touching step; the sibling writes that follow are
        // non-active and therefore jar-neutral.
        let auth = makeAuthManager()
        let url = URL(string: "https://claude.ai")!
        func jarCookie(_ name: String) -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == name }?.value
        }
        let a = Account(email: "me@x.com", sessionKey: "sk-a-old", organizationId: "org-a",
                        allCookieHeader: "sessionKey=sk-a-old; __cf_bm=cf-a")
        _ = auth.accountStore.addAccount(a)
        let b = Account(email: "me@x.com", sessionKey: "sk-b-old", organizationId: "org-b",
                        allCookieHeader: "sessionKey=sk-b-old; __cf_bm=cf-b")
        _ = auth.accountStore.addAccount(b)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sk-fresh")
        guard case .needsOrgChoice(let orgs) = result else {
            return XCTFail("expected the picker, got \(result)")
        }
        _ = auth.completeManualSignIn(org: orgs[0])

        XCTAssertEqual(jarCookie("sessionKey"), "sk-fresh", "the jar serves the freshly pasted key")
        XCTAssertEqual(jarCookie("__cf_bm"), "cf-a",
                       "the jar holds the PICKED account's cookies; a sibling write must not clobber them")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == b.id }?.allCookieHeader,
                       "sessionKey=sk-fresh; __cf_bm=cf-b",
                       "the sibling keeps its own Cloudflare cookies and takes only the fresh key")
    }

    @MainActor
    func testCompleteManualSignIn_atLimitPickingUnstoredOrg_leavesStoredCredentialsUnchanged() async {
        // AE10 / KTD3: the sibling loop sits BEHIND the success check. Picking an org that is not
        // stored while every slot is taken fails, and that failure must leave storage exactly as it
        // was, rather than reporting a limit error having already rewritten several entries.
        let auth = makeAuthManager()
        let url = URL(string: "https://claude.ai")!
        func jarSessionKey() -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == "sessionKey" }?.value
        }
        var stored: [Account] = []
        for i in 0..<AccountStore.maxAccounts {
            let acct = Account(email: "me@x.com", sessionKey: "sk-\(i)-old", organizationId: "org-\(i)",
                               allCookieHeader: "sessionKey=sk-\(i)-old; __cf_bm=cf-\(i)")
            XCTAssertTrue(auth.accountStore.addAccount(acct), "fixture must fill the store to the limit")
            stored.append(acct)
        }
        // Every stored org plus one that is not stored, so the picker appears rather than the
        // all-already-stored refresh.
        let listed = stored.map { #"{"uuid":"\#($0.organizationId)"}"# } + [#"{"uuid":"org-new"}"#]
        mockSession.responseData = "[\(listed.joined(separator: ","))]".data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")
        guard case .needsOrgChoice(let orgs) = result else {
            return XCTFail("an addable org means the picker, got \(result)")
        }
        guard let unstored = orgs.first(where: { $0.uuid == "org-new" }) else {
            return XCTFail("the unstored org must be offered in the picker")
        }

        let completed = auth.completeManualSignIn(org: unstored)

        XCTAssertEqual(completed, .accountLimitReached, "no free slot, so the add fails")
        XCTAssertEqual(auth.accountStore.accounts.count, AccountStore.maxAccounts, "nothing added")
        for acct in stored {
            let after = auth.accountStore.accounts.first { $0.id == acct.id }
            XCTAssertEqual(after?.sessionKey, acct.sessionKey,
                           "\(acct.organizationId) keeps its own key after a failed pick")
            XCTAssertEqual(after?.allCookieHeader, acct.allCookieHeader,
                           "\(acct.organizationId) keeps its own cookie header after a failed pick")
        }
        XCTAssertEqual(jarSessionKey(), stored[0].sessionKey,
                       "and the active account's jar is left alone by the failure")
    }

    @MainActor
    func testCompleteManualSignIn_pickingLoneStoredOrg_behavesAsBefore() async {
        // The no-sibling case must be exactly what it was before the loop existed: one write, one
        // switch, no new entry. This is the shape most users hit, so it is asserted, not assumed.
        let auth = makeAuthManager()
        let a = Account(email: "me@x.com", sessionKey: "sk-a-old", organizationId: "org-a",
                        allCookieHeader: "sessionKey=sk-a-old; __cf_bm=cf-a")
        _ = auth.accountStore.addAccount(a)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")
        guard case .needsOrgChoice(let orgs) = result else {
            return XCTFail("expected the picker, got \(result)")
        }

        let completed = auth.completeManualSignIn(org: orgs[0])

        guard case .success = completed else { return XCTFail("re-picking org-a should succeed, got \(completed)") }
        XCTAssertEqual(auth.accountStore.accounts.count, 1, "reactivate, not duplicate, and org-b is not added")
        XCTAssertEqual(auth.accountStore.accounts.first?.sessionKey, "sk-fresh", "the picked entry is refreshed")
        XCTAssertEqual(auth.accountStore.accounts.first?.allCookieHeader, "sessionKey=sk-fresh; __cf_bm=cf-fresh",
                       "and takes the pasted header")
        XCTAssertEqual(auth.accountStore.activeAccountId, a.id, "still switches to the picked org")
    }

    @MainActor
    func testCompleteManualSignIn_pickingStoredOrg_leavesStoredOrgSetUnchanged() async {
        // R4: repair only. Picking a stored org while a fourth is visible adds nothing, removes
        // nothing, and reorders nothing.
        let auth = makeAuthManager()
        for uuid in ["org-a", "org-b", "org-c"] {
            _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old"))
        }
        let before = auth.accountStore.accounts.map(\.organizationId)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"},{"uuid":"org-d"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")
        guard case .needsOrgChoice(let orgs) = result else {
            return XCTFail("expected the picker, got \(result)")
        }
        guard let orgB = orgs.first(where: { $0.uuid == "org-b" }) else {
            return XCTFail("org-b must be offered in the picker")
        }

        _ = auth.completeManualSignIn(org: orgB)

        XCTAssertEqual(auth.accountStore.accounts.count, 3, "no entry added or removed by a pick that repairs")
        XCTAssertEqual(auth.accountStore.accounts.map(\.organizationId), before,
                       "the stored orgs are the same, in the same order")
        XCTAssertFalse(auth.accountStore.accounts.contains { $0.organizationId == "org-d" },
                       "the visible-but-unstored org stays unstored")
    }

    @MainActor
    func testCompleteManualSignIn_secondCallAfterAPickIsInvalidAndWritesNothing() async {
        // The pending context now carries the org list the sibling loop reads (KTD5), so a stale
        // context must never be reusable: the first pick clears it and a second call is invalid
        // input that repairs nothing. The no-context-at-all case is covered by
        // testCompleteManualSignIn_withoutPendingContextIsInvalid.
        let auth = makeAuthManager()
        _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-a-old",
            organizationId: "org-a", allCookieHeader: "sessionKey=sk-a-old"))
        _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-b-old",
            organizationId: "org-b", allCookieHeader: "sessionKey=sk-b-old"))
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")
        guard case .needsOrgChoice(let orgs) = result else {
            return XCTFail("expected the picker, got \(result)")
        }
        _ = auth.completeManualSignIn(org: orgs[0])
        let afterFirstPick = auth.accountStore.accounts

        let second = auth.completeManualSignIn(org: orgs[1])

        XCTAssertEqual(second, .invalidInput, "the context is consumed by the first pick")
        XCTAssertEqual(auth.accountStore.accounts.map(\.organizationId), afterFirstPick.map(\.organizationId),
                       "a second completion adds nothing")
        XCTAssertEqual(auth.accountStore.accounts.map(\.sessionKey), afterFirstPick.map(\.sessionKey),
                       "and rewrites nothing")
    }

    @MainActor
    func testFetchOrganizationId_partialStored_showsPickerNotAutoMatch() async {
        let auth = makeAuthManager()
        _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-a",
            organizationId: "org-a", allCookieHeader: "sessionKey=sk-a"))
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-fresh"
        // A captured header is now required to reach the org-selection switch at all (KTD4, #41),
        // so supply one: this test is about which branch the switch takes, not the guard.
        auth.pendingCookieHeader = "sessionKey=sk-fresh; __cf_bm=cf-fresh"

        await auth.fetchOrganizationId()

        // No login window in tests, so .needsChoice -> picker returns nil -> graceful failure. The
        // point: it routed to .needsChoice, NOT the removed .autoMatched (which would have silently
        // reactivated org-a and overwritten its sessionKey with sk-fresh — the #32 bug).
        XCTAssertEqual(auth.accountStore.accounts.count, 1, "no account added or removed")
        XCTAssertEqual(auth.accountStore.accounts.first?.sessionKey, "sk-a",
                       "org-a must NOT be silently reactivated")
    }

    @MainActor
    func testFetchOrganizationId_allStored_refreshesMatchedAndSwitches() async {
        let auth = makeAuthManager()
        let a = Account(email: "me@x.com", sessionKey: "sk-a-old", organizationId: "org-a", allCookieHeader: "sessionKey=sk-a-old")
        _ = auth.accountStore.addAccount(a)
        _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-b", organizationId: "org-b", allCookieHeader: "sessionKey=sk-b"))
        auth.accountStore.switchTo(a.id)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-a-fresh"
        // Required since KTD4 (#41): a nil captured header now refuses the write outright.
        auth.pendingCookieHeader = "sessionKey=sk-a-fresh; __cf_bm=cf-fresh"

        await auth.fetchOrganizationId()

        XCTAssertEqual(auth.accountStore.accounts.count, 2, "all-stored: no new account")
        XCTAssertEqual(auth.accountStore.activeAccountId, a.id)
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == a.id }?.sessionKey, "sk-a-fresh",
                       "WebView all-stored refreshes the matched account's session")
        XCTAssertEqual(auth.loginState, .idle, "window closes via the success path")
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

        // Set the pending session key (normally set by handleCookieCaptured) and the captured
        // cookie header (normally enumerated from the login WebView's store), which KTD4 (#41)
        // now requires before any credential write.
        auth.pendingSessionKey = "sk-test-fetch-org"
        auth.pendingCookieHeader = "sessionKey=sk-test-fetch-org; __cf_bm=cf-1"

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
        // A header is supplied so the flow reaches the picker; the nil-header refusal (KTD4, #41)
        // is covered separately and would otherwise stop this test short of what it asserts.
        auth.pendingCookieHeader = "sessionKey=sk-multi-org; __cf_bm=cf-1"

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
            XCTAssertTrue(message.contains("No Claude organizations were found"),
                          "Expected the no-organizations message, got: \(message)")
            XCTAssertTrue(message.contains("Pro or Max"),
                          "Expected the subscription hint folded into the overlay copy, got: \(message)")
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
        // Required since KTD4 (#41): no captured header means no credential write.
        auth.pendingCookieHeader = "sessionKey=sk-refreshed-key; __cf_bm=cf-1"

        await auth.fetchOrganizationId()

        // Should still have one account, not two
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.sessionKey, "sk-refreshed-key",
                       "Session key should be updated on re-auth")
        XCTAssertEqual(auth.loginState, .idle)
    }

    // MARK: - Browser sign-in refresh-all + the nil-header guard (U4, R1/R2/R3/R4/R5, issue #41)
    // The WebView path carries its own copy of the repair logic, so it gets its own coverage. Its
    // picker needs a real NSAlert sheet (unavailable headless), which is why the two pick-route
    // scenarios drive `addOrReactivateWebViewAccount` - the tail both the picker and the single-org
    // route fall into - rather than `fetchOrganizationId`.

    @MainActor
    func testFetchOrganizationId_allStored_threeOrgs_refreshesEveryStoredEntry() async {
        // AE11's repair half: one browser sign-in repairs all three stored orgs, not just the one
        // being viewed, and still switches to the matched account as it always did.
        let auth = makeAuthManager()
        var stored: [Account] = []
        for uuid in ["org-a", "org-b", "org-c"] {
            let acct = Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old", organizationId: uuid,
                               allCookieHeader: "sessionKey=sk-\(uuid)-old; __cf_bm=cf-\(uuid)")
            XCTAssertTrue(auth.accountStore.addAccount(acct))
            stored.append(acct)
        }
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-fresh"
        auth.pendingCookieHeader = "sessionKey=sk-fresh; __cf_bm=cf-fresh"

        await auth.fetchOrganizationId()

        for acct in stored {
            let after = auth.accountStore.accounts.first { $0.id == acct.id }
            XCTAssertEqual(after?.sessionKey, "sk-fresh",
                           "\(acct.organizationId) must be repaired by the one sign-in (R1)")
            XCTAssertEqual(after?.allCookieHeader, "sessionKey=sk-fresh; __cf_bm=cf-fresh",
                           "\(acct.organizationId) takes the captured header, not only the key")
        }
        XCTAssertEqual(auth.accountStore.accounts.count, 3, "a repair adds and removes nothing")
        XCTAssertEqual(auth.accountStore.activeAccountId, stored[0].id,
                       "the matched account is still switched to, which is pre-existing behaviour (R3)")
        XCTAssertEqual(auth.loginState, .idle, "the window closes through the success path")
    }

    @MainActor
    func testFetchOrganizationId_allStored_switchTargetFollowsActivePreferenceNotStoredOrder() async {
        // KTD1: the loop writes in stored order, so if the switch target were taken from the loop
        // the app would switch to org-a here. It must stay `matchedAccount`, which prefers the
        // ACTIVE account whenever its org is in the response (the rule issue #32 made mandatory).
        let auth = makeAuthManager()
        let a = Account(email: "me@x.com", sessionKey: "sk-a-old", organizationId: "org-a",
                        allCookieHeader: "sessionKey=sk-a-old; __cf_bm=cf-a")
        _ = auth.accountStore.addAccount(a)
        let b = Account(email: "me@x.com", sessionKey: "sk-b-old", organizationId: "org-b",
                        allCookieHeader: "sessionKey=sk-b-old; __cf_bm=cf-b")
        _ = auth.accountStore.addAccount(b)
        auth.accountStore.switchTo(b.id)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-fresh"
        auth.pendingCookieHeader = "sessionKey=sk-fresh; __cf_bm=cf-fresh"

        await auth.fetchOrganizationId()

        XCTAssertEqual(auth.accountStore.activeAccountId, b.id,
                       "the active account stays active; the switch target is not the loop's first write")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == a.id }?.sessionKey, "sk-fresh",
                       "the non-active sibling is repaired all the same")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == b.id }?.sessionKey, "sk-fresh")
    }

    @MainActor
    func testFetchOrganizationId_allStored_unrelatedEmailEntryUntouched() async {
        // AE4 on the browser path: an entry whose org the credentials do not list is not written to,
        // and the jar ends up holding the account this sign-in switched to.
        let auth = makeAuthManager()
        let url = URL(string: "https://claude.ai")!
        func jarCookie(_ name: String) -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == name }?.value
        }
        let a = Account(email: "me@x.com", sessionKey: "sk-a-old", organizationId: "org-a",
                        allCookieHeader: "sessionKey=sk-a-old; __cf_bm=cf-a")
        _ = auth.accountStore.addAccount(a)
        let b = Account(email: "me@x.com", sessionKey: "sk-b-old", organizationId: "org-b",
                        allCookieHeader: "sessionKey=sk-b-old; __cf_bm=cf-b")
        _ = auth.accountStore.addAccount(b)
        let z = Account(email: "other@y.com", sessionKey: "sk-z", organizationId: "org-z",
                        allCookieHeader: "sessionKey=sk-z; __cf_bm=cf-z")
        _ = auth.accountStore.addAccount(z)
        auth.accountStore.switchTo(z.id)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-fresh"
        auth.pendingCookieHeader = "sessionKey=sk-fresh; __cf_bm=cf-fresh"

        await auth.fetchOrganizationId()

        let afterZ = auth.accountStore.accounts.first { $0.id == z.id }
        XCTAssertEqual(afterZ?.sessionKey, "sk-z", "the other email's entry keeps its own key")
        XCTAssertEqual(afterZ?.allCookieHeader, "sessionKey=sk-z; __cf_bm=cf-z",
                       "and its stored header is byte-identical afterwards")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == a.id }?.sessionKey, "sk-fresh")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == b.id }?.sessionKey, "sk-fresh")
        XCTAssertEqual(auth.accountStore.activeAccountId, a.id,
                       "org-z is not in the response, so the switch target falls back to the first stored match")
        XCTAssertEqual(jarCookie("__cf_bm"), "cf-fresh",
                       "the jar holds the account this sign-in switched to; no restore fights the switch")
    }

    @MainActor
    func testFetchOrganizationId_allStored_leavesStoredOrgSetUnchanged() async {
        // R4 on the browser all-stored route: repair only, nothing added, removed, or reordered.
        let auth = makeAuthManager()
        for uuid in ["org-a", "org-b", "org-c"] {
            _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old"))
        }
        let before = auth.accountStore.accounts.map(\.organizationId)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-fresh"
        auth.pendingCookieHeader = "sessionKey=sk-fresh; __cf_bm=cf-fresh"

        await auth.fetchOrganizationId()

        XCTAssertEqual(auth.accountStore.accounts.map(\.organizationId), before,
                       "the same orgs, in the same order")
        XCTAssertEqual(auth.accountStore.accounts.count, 3)
    }

    @MainActor
    func testFetchOrganizationId_nilCookieHeader_allStoredRouteWritesNothing() async {
        // KTD4: with no captured header the organizations request is authenticated by whatever is
        // in the shared jar, so the response can describe the PREVIOUSLY ACTIVE account. Writing on
        // it would repoint that whole account's entries at a key that is not theirs.
        let auth = makeAuthManager()
        let a = Account(email: "me@x.com", sessionKey: "sk-a-old", organizationId: "org-a",
                        allCookieHeader: "sessionKey=sk-a-old; __cf_bm=cf-a")
        _ = auth.accountStore.addAccount(a)
        let b = Account(email: "me@x.com", sessionKey: "sk-b-old", organizationId: "org-b",
                        allCookieHeader: "sessionKey=sk-b-old; __cf_bm=cf-b")
        _ = auth.accountStore.addAccount(b)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-fresh"
        auth.pendingCookieHeader = nil

        await auth.fetchOrganizationId()

        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == a.id }?.sessionKey, "sk-a-old",
                       "no captured header means no write, on any route")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == b.id }?.sessionKey, "sk-b-old")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == a.id }?.allCookieHeader,
                       "sessionKey=sk-a-old; __cf_bm=cf-a", "and stored headers are left alone too")
        if case .error(let message) = auth.loginState {
            XCTAssertTrue(message.contains("Sign-in could not be completed"),
                          "the refusal must surface as a retryable failure, got: \(message)")
        } else {
            XCTFail("Expected .error state, got \(auth.loginState)")
        }
    }

    @MainActor
    func testFetchOrganizationId_nilCookieHeader_singleOrgRouteAddsNothing() async {
        // The guard sits before the org-selection switch precisely so it also covers the route that
        // adds a first account, not only the repair routes.
        let auth = makeAuthManager()
        mockSession.responseData = #"[{"uuid":"org-only"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-fresh"
        auth.pendingCookieHeader = nil

        await auth.fetchOrganizationId()

        XCTAssertEqual(auth.accountStore.accounts.count, 0, "the single-org add route is guarded too")
        if case .error(let message) = auth.loginState {
            XCTAssertTrue(message.contains("Sign-in could not be completed"), "got: \(message)")
        } else {
            XCTFail("Expected .error state, got \(auth.loginState)")
        }
    }

    @MainActor
    func testFetchOrganizationId_nilCookieHeader_pickRouteRefusesBeforeThePicker() async {
        // The third route the one guard covers. The distinct message is what proves the refusal
        // happened before the picker rather than the picker returning nil for want of a window.
        let auth = makeAuthManager()
        let a = Account(email: "me@x.com", sessionKey: "sk-a-old", organizationId: "org-a",
                        allCookieHeader: "sessionKey=sk-a-old; __cf_bm=cf-a")
        _ = auth.accountStore.addAccount(a)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-fresh"
        auth.pendingCookieHeader = nil

        await auth.fetchOrganizationId()

        XCTAssertEqual(auth.accountStore.accounts.count, 1, "nothing added")
        XCTAssertEqual(auth.accountStore.accounts.first?.sessionKey, "sk-a-old", "nothing rewritten")
        if case .error(let message) = auth.loginState {
            XCTAssertTrue(message.contains("Sign-in could not be completed"),
                          "the guard, not the missing picker window, must be what stopped this: \(message)")
        } else {
            XCTFail("Expected .error state, got \(auth.loginState)")
        }
    }

    @MainActor
    func testAddOrReactivateWebViewAccount_pickingStoredOrg_refreshesStoredSiblings() async {
        // Two stored orgs plus one the app has never stored. Picking a stored org in the browser
        // picker repairs its stored sibling in the same action and still does not add org-c (R4, D1).
        let auth = makeAuthManager()
        let url = URL(string: "https://claude.ai")!
        func jarCookie(_ name: String) -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == name }?.value
        }
        let a = Account(email: "me@x.com", sessionKey: "sk-a-old", organizationId: "org-a",
                        allCookieHeader: "sessionKey=sk-a-old; __cf_bm=cf-a")
        _ = auth.accountStore.addAccount(a)
        let b = Account(email: "me@x.com", sessionKey: "sk-b-old", organizationId: "org-b",
                        allCookieHeader: "sessionKey=sk-b-old; __cf_bm=cf-b")
        _ = auth.accountStore.addAccount(b)
        let orgs = ["org-a", "org-b", "org-c"].map {
            Organization(uuid: $0, name: nil, billingType: nil, emailAddress: nil)
        }

        let wrote = auth.addOrReactivateWebViewAccount(org: orgs[0], orgs: orgs, sessionKey: "sk-fresh",
                                                       cookieHeader: "sessionKey=sk-fresh; __cf_bm=cf-fresh",
                                                       email: "me@x.com")

        XCTAssertTrue(wrote, "picking a stored org re-authenticates it")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == a.id }?.sessionKey, "sk-fresh",
                       "the picked entry is refreshed, as it always was")
        XCTAssertEqual(auth.accountStore.accounts.first { $0.id == b.id }?.sessionKey, "sk-fresh",
                       "and its stored sibling is repaired by the same pick (R2, issue #41)")
        XCTAssertEqual(auth.accountStore.accounts.count, 2, "a repair adds no entry")
        XCTAssertFalse(auth.accountStore.accounts.contains { $0.organizationId == "org-c" },
                       "org-c was offered but never stored, and a pick must not add it")
        XCTAssertEqual(auth.accountStore.activeAccountId, a.id,
                       "the browser pick route switches to the picked org (R3)")
        XCTAssertEqual(jarCookie("sessionKey"), "sk-fresh",
                       "switchTo is the last jar-touching step, so the jar serves the picked account")
    }

    @MainActor
    func testAddOrReactivateWebViewAccount_atLimitPickingUnstoredOrg_leavesStoredCredentialsUnchanged() async {
        // KTD3 on the browser path: the sibling loop sits BEHIND the success check. Picking an org
        // that is not stored while every slot is taken fails, and that failure must leave storage
        // exactly as it was rather than reporting a limit error having rewritten several entries.
        let auth = makeAuthManager()
        let url = URL(string: "https://claude.ai")!
        func jarSessionKey() -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == "sessionKey" }?.value
        }
        var stored: [Account] = []
        for i in 0..<AccountStore.maxAccounts {
            let acct = Account(email: "me@x.com", sessionKey: "sk-\(i)-old", organizationId: "org-\(i)",
                               allCookieHeader: "sessionKey=sk-\(i)-old; __cf_bm=cf-\(i)")
            XCTAssertTrue(auth.accountStore.addAccount(acct), "fixture must fill the store to the limit")
            stored.append(acct)
        }
        let orgs = (stored.map(\.organizationId) + ["org-new"]).map {
            Organization(uuid: $0, name: nil, billingType: nil, emailAddress: nil)
        }
        guard let unstored = orgs.first(where: { $0.uuid == "org-new" }) else {
            return XCTFail("fixture must offer the unstored org")
        }

        let wrote = auth.addOrReactivateWebViewAccount(org: unstored, orgs: orgs, sessionKey: "sk-fresh",
                                                       cookieHeader: "sessionKey=sk-fresh; __cf_bm=cf-fresh",
                                                       email: "me@x.com")

        XCTAssertFalse(wrote, "no free slot, so the add fails and the caller reports the limit")
        XCTAssertEqual(auth.accountStore.accounts.count, AccountStore.maxAccounts, "nothing added")
        for acct in stored {
            let after = auth.accountStore.accounts.first { $0.id == acct.id }
            XCTAssertEqual(after?.sessionKey, acct.sessionKey,
                           "\(acct.organizationId) keeps its own key after a failed pick")
            XCTAssertEqual(after?.allCookieHeader, acct.allCookieHeader,
                           "\(acct.organizationId) keeps its own cookie header after a failed pick")
        }
        XCTAssertEqual(jarSessionKey(), stored[0].sessionKey,
                       "and the active account's jar is left alone by the failure")
    }

    @MainActor
    func testAddOrReactivateWebViewAccount_pickingStoredOrg_leavesStoredOrgSetUnchanged() async {
        // R4 on the browser pick route: a pick that repairs adds nothing, removes nothing, and
        // reorders nothing, even with a visible org the app has never stored.
        let auth = makeAuthManager()
        for uuid in ["org-a", "org-b", "org-c"] {
            _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old"))
        }
        let before = auth.accountStore.accounts.map(\.organizationId)
        let orgs = ["org-a", "org-b", "org-c", "org-d"].map {
            Organization(uuid: $0, name: nil, billingType: nil, emailAddress: nil)
        }

        _ = auth.addOrReactivateWebViewAccount(org: orgs[1], orgs: orgs, sessionKey: "sk-fresh",
                                               cookieHeader: "sessionKey=sk-fresh; __cf_bm=cf-fresh",
                                               email: "me@x.com")

        XCTAssertEqual(auth.accountStore.accounts.map(\.organizationId), before,
                       "the stored orgs are the same, in the same order")
        XCTAssertEqual(auth.accountStore.accounts.count, 3, "no entry added or removed")
        XCTAssertFalse(auth.accountStore.accounts.contains { $0.organizationId == "org-d" },
                       "the visible-but-unstored org stays unstored")
    }

    // MARK: - R8 (#41): a bare session-key paste leaves the FRESH key serving requests

    @MainActor
    func testManualSignIn_bareKeyRefreshServesFreshKeyNotStaleHeader() async {
        let auth = makeAuthManager()
        let url = URL(string: "https://claude.ai")!
        func jarCookie(_ name: String) -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == name }?.value
        }
        // One stored org whose captured cookie header has gone stale.
        let a = Account(email: "me@x.com", sessionKey: "sk-stale", organizationId: "org-a",
                        allCookieHeader: "sessionKey=sk-stale; __cf_bm=cf-1")
        _ = auth.accountStore.addAccount(a)
        XCTAssertEqual(jarCookie("sessionKey"), "sk-stale", "precondition: the jar holds the stale key")

        mockSession.responseData = #"[{"uuid":"org-a"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        // A bare key parses to a nil cookieHeader, which is what used to leave the stale pair in
        // place: the app reported success and the next poll failed on the dead key.
        let result = await auth.manualSignIn("sk-fresh")

        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(auth.accountStore.accounts.first?.sessionKey, "sk-fresh")
        XCTAssertEqual(jarCookie("sessionKey"), "sk-fresh",
                       "a bare-key paste must not confirm success while the jar still serves the dead key (AE7)")
        XCTAssertEqual(jarCookie("__cf_bm"), "cf-1",
                       "the captured Cloudflare cookie survives the bare-key refresh")
        XCTAssertEqual(auth.accountStore.accounts.count, 1, "refresh only, no org added or removed")
    }

    // MARK: - R6/D6 (#41): a truthful confirmation with a count, on every repair route
    // The three repair routes each carry the count out of the auth layer differently - the manual
    // branches through ManualSignInResult, the WebView path through onSignInConfirmation - but they
    // all render it through the one `repairConfirmation` builder, so the wording cannot drift.
    // AE2 is covered above by testManualSignIn_allOrgsStored_threeOrgs_confirmationNamesTheCount.

    func testRepairConfirmation_oneEntryReadsSingular() {
        // "1 organizations" is the exact defect. The singular is reachable in the product: a
        // response that repeats one org uuid takes the all-already-stored branch with a single
        // matching entry, and the picker route hits it whenever the picked org has no stored sibling.
        XCTAssertEqual(AuthManager.repairConfirmation(refreshedCount: 1, viewedAccountRepaired: true),
                       "Refreshed 1 organization.")
        XCTAssertFalse(AuthManager.repairConfirmation(refreshedCount: 1, viewedAccountRepaired: true)
            .contains("1 organizations"))
        XCTAssertEqual(AuthManager.repairConfirmation(refreshedCount: 2, viewedAccountRepaired: true),
                       "Refreshed 2 organizations.", "and two is still plural")
    }

    @MainActor
    func testManualSignIn_allOrgsStored_duplicateOrgUuid_reportsOneNotTwo() async {
        // The count is the number of ENTRIES repaired, not the length of the response. A repeated
        // uuid must not inflate it into a claim the user can see is wrong.
        let auth = makeAuthManager()
        _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-a-old",
            organizationId: "org-a", allCookieHeader: "sessionKey=sk-a-old"))
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-a"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")

        XCTAssertEqual(result, .alreadySignedInAllOrgs(refreshedCount: 1, activeAccountRefreshed: true),
                       "one stored entry was repaired, however many times its org was listed")
    }

    @MainActor
    func testManualSignIn_allOrgsStored_activeNotRefreshed_messageSaysSoAndNamesTheNextStep() async {
        // AE5's message half (D6). The paste repaired two background entries and deliberately left
        // the account being viewed alone, so a bare count would be a false claim printed while the
        // menu bar still shows that account's failure marker.
        let auth = makeAuthManager()
        let c = Account(email: "c@other.com", sessionKey: "sk-C", organizationId: "org-c",
                        allCookieHeader: "sessionKey=sk-C; __cf_bm=cf-C")
        _ = auth.accountStore.addAccount(c)
        for uuid in ["org-a", "org-b"] {
            _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old"))
        }
        auth.accountStore.switchTo(c.id)
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")

        guard case .alreadySignedInAllOrgs(let count, let activeRefreshed) = result else {
            return XCTFail("expected the all-already-stored branch, got \(result)")
        }
        XCTAssertEqual(count, 2)
        XCTAssertFalse(activeRefreshed, "account C's org is not in the response, so C was not repaired")
        let message = AuthManager.repairConfirmation(refreshedCount: count, viewedAccountRepaired: activeRefreshed)
        XCTAssertNotEqual(message, "Refreshed 2 organizations.",
                          "the count alone would claim the viewed account was repaired when it was not")
        XCTAssertTrue(message.contains("not the one you're viewing"),
                      "the message must say the viewed account was left alone, got: \(message)")
        XCTAssertTrue(message.contains("switch to a refreshed one") && message.contains("cookie header"),
                      "and it must name what to do next, not leave the user at a failure marker: \(message)")
    }

    @MainActor
    func testCompleteManualSignIn_pickRouteReportsACountNotABareSuccess() async {
        // AE3's message half. Picking a stored org repairs its stored sibling too, so the pick must
        // report two. Before the count travelled with .success this route confirmed "Signed in as X"
        // and said nothing at all about the sibling it had just rescued.
        let auth = makeAuthManager()
        for uuid in ["org-a", "org-b"] {
            _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old"))
        }
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        let discovered = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")
        guard case .needsOrgChoice(let orgs) = discovered else {
            return XCTFail("one addable org means the picker, got \(discovered)")
        }

        let completed = auth.completeManualSignIn(org: orgs[0])

        guard case .success(let name, let count) = completed else {
            return XCTFail("picking the stored org-a should succeed, got \(completed)")
        }
        XCTAssertEqual(count, 2, "the picked entry and its stored sibling both got fresh credentials")
        // Composed the way Settings composes it, so the sentence the user reads is asserted.
        XCTAssertEqual("Signed in as \(name). " + AuthManager.repairConfirmation(refreshedCount: count,
                                                                                viewedAccountRepaired: true),
                       "Signed in as me@x.com. Refreshed 2 organizations.")
    }

    @MainActor
    func testCompleteManualSignIn_pickingAnUnstoredOrg_reportsNothingRepaired() async {
        // The other half of the same rule: adding an org the app never stored repairs nothing, so
        // the count is zero and Settings keeps the plain "Signed in as X" it always showed.
        let auth = makeAuthManager()
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        let discovered = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")
        guard case .needsOrgChoice(let orgs) = discovered else {
            return XCTFail("expected the picker, got \(discovered)")
        }

        let completed = auth.completeManualSignIn(org: orgs[0])

        guard case .success(_, let count) = completed else {
            return XCTFail("adding org-a should succeed, got \(completed)")
        }
        XCTAssertEqual(count, 0, "a brand-new entry is an add, not a repair")
    }

    @MainActor
    func testFetchOrganizationId_allStored_threeOrgs_reportsTheCount() async {
        // AE11's message half. The WebView path returns no result to Settings and closes its window
        // on success, so the count leaves through onSignInConfirmation instead. The app wires that
        // to a one-line alert; the test asserts the message rather than presenting it.
        let auth = makeAuthManager()
        for uuid in ["org-a", "org-b", "org-c"] {
            _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old"))
        }
        var confirmations: [String] = []
        auth.onSignInConfirmation = { confirmations.append($0) }
        mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"},{"uuid":"org-c"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200
        auth.pendingSessionKey = "sk-fresh"
        auth.pendingCookieHeader = "sessionKey=sk-fresh; __cf_bm=cf-fresh"

        await auth.fetchOrganizationId()

        XCTAssertEqual(confirmations, ["Refreshed 3 organizations."],
                       "one browser sign-in, one confirmation, naming every entry it repaired")
    }

    @MainActor
    func testAddOrReactivateWebViewAccount_pickingStoredOrg_reportsPickedPlusSiblings() async {
        // The browser picker route reports too, not only the all-already-stored route. The picked
        // org was stored, so it counts alongside the sibling the same sign-in rescued.
        let auth = makeAuthManager()
        for uuid in ["org-a", "org-b"] {
            _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old"))
        }
        var confirmations: [String] = []
        auth.onSignInConfirmation = { confirmations.append($0) }
        let orgs = ["org-a", "org-b", "org-c"].map {
            Organization(uuid: $0, name: nil, billingType: nil, emailAddress: nil)
        }

        _ = auth.addOrReactivateWebViewAccount(org: orgs[0], orgs: orgs, sessionKey: "sk-fresh",
                                               cookieHeader: "sessionKey=sk-fresh; __cf_bm=cf-fresh",
                                               email: "me@x.com")

        XCTAssertEqual(confirmations, ["Refreshed 2 organizations."],
                       "the picked entry plus the sibling repaired behind it")
    }

    @MainActor
    func testAddOrReactivateWebViewAccount_singleOrgReAuth_staysSilent() async {
        // The WebView confirmation is a modal, so it fires only when the sign-in repaired more than
        // the org the user signed in to. An ordinary single-org re-auth has no news in it and must
        // not start charging a click for one. The manual path states the count even at one, because
        // it writes to a status line it was already writing to.
        let auth = makeAuthManager()
        _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-a-old",
            organizationId: "org-a", allCookieHeader: "sessionKey=sk-a-old"))
        var confirmations: [String] = []
        auth.onSignInConfirmation = { confirmations.append($0) }
        let orgs = [Organization(uuid: "org-a", name: nil, billingType: nil, emailAddress: nil)]

        let wrote = auth.addOrReactivateWebViewAccount(org: orgs[0], orgs: orgs, sessionKey: "sk-fresh",
                                                       cookieHeader: "sessionKey=sk-fresh; __cf_bm=cf-fresh",
                                                       email: "me@x.com")

        XCTAssertTrue(wrote, "the re-auth still happens")
        XCTAssertEqual(auth.accountStore.accounts.first?.sessionKey, "sk-fresh")
        XCTAssertEqual(confirmations, [], "nothing beyond the org signed in to was repaired")
    }

    // MARK: - Issue #41 (R11): polling pauses across the network windows of a sign-in
    // The failure this prevents is a race, so a test that calls these functions in order proves
    // nothing about it. What is testable here is the invariant - every exit of both functions
    // resumes - and the ordering the invariant rests on, that the suspend precedes the first jar
    // write. The mechanism itself, an in-flight poll not being answered with the pasted
    // credentials, is exercised in UsageServiceTests where the poll lives.

    /// Build an AuthManager on its OWN storage prefix, so the cases inside one test do not inherit
    /// each other's stored accounts, record the pause callbacks in order, run `body`, and hand the
    /// recorded sequence back. The sequence and not a pair of counters, because "the pause is not
    /// held across the picker" is an ordering claim.
    @MainActor
    private func pauseEvents(prefix: String, _ body: (AuthManager) async -> Void) async -> [String] {
        let storage = StorageService(defaults: defaults, prefix: prefix)
        let accountStore = AccountStore(storage: storage)
        let auth = AuthManager(storage: storage, accountStore: accountStore, session: mockSession)
        var events: [String] = []
        auth.onSuspendPolling = { events.append("suspend") }
        auth.onResumePolling = { events.append("resume") }
        await body(auth)
        return events
    }

    @MainActor
    func testManualSignIn_everyExitResumesPolling() async {
        // A missed resume leaves polling dead until the app is restarted, which is worse than the
        // race the pause fixes, so the assertion is the invariant walked over every exit this
        // function can actually reach.
        let paste = "sessionKey=sk-fresh; __cf_bm=cf-fresh"

        // Invalid input: manualSignIn returns before discovery, so nothing is ever suspended.
        let invalid = await pauseEvents(prefix: "u9a_") { auth in
            let result = await auth.manualSignIn("   ")
            XCTAssertEqual(result, .invalidInput)
        }
        XCTAssertEqual(invalid, [], "the parse failure returns before the jar is touched, so there is no pause to undo")

        let authFailed = await pauseEvents(prefix: "u9b_") { auth in
            mockSession.responseData = Data()
            mockSession.responseStatusCode = 401
            let result = await auth.manualSignIn(paste)
            XCTAssertEqual(result, .authFailed(suggestFullHeader: false))
        }
        XCTAssertEqual(authFailed, ["suspend", "resume"], "a rejected paste must not leave polling stopped")

        let noOrgs = await pauseEvents(prefix: "u9c_") { auth in
            mockSession.responseData = "[]".data(using: .utf8)!
            mockSession.responseStatusCode = 200
            let result = await auth.manualSignIn(paste)
            XCTAssertEqual(result, .noOrganizations)
        }
        XCTAssertEqual(noOrgs, ["suspend", "resume"])

        let pickerShown = await pauseEvents(prefix: "u9d_") { auth in
            mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
            mockSession.responseStatusCode = 200
            guard case .needsOrgChoice = await auth.manualSignIn(paste) else {
                return XCTFail("expected the picker route")
            }
        }
        XCTAssertEqual(pickerShown, ["suspend", "resume"],
                       "handing off to the picker resumes: a picker waits on a person and can sit open indefinitely (KTD8)")

        let branchA = await pauseEvents(prefix: "u9e_") { auth in
            for uuid in ["org-a", "org-b"] {
                _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                    organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old"))
            }
            mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
            mockSession.responseStatusCode = 200
            let result = await auth.manualSignIn(paste)
            XCTAssertEqual(result, .alreadySignedInAllOrgs(refreshedCount: 2, activeAccountRefreshed: true))
        }
        XCTAssertEqual(branchA, ["suspend", "resume"])

        let branchB = await pauseEvents(prefix: "u9f_") { auth in
            // Active account C is unrelated to the pasted account, so it is deliberately left
            // unrepaired - and this is the route that fires no success callback, so the resume is
            // the ONLY thing that starts polling again.
            _ = auth.accountStore.addAccount(Account(email: "c@other.com", sessionKey: "sk-C",
                organizationId: "org-c", allCookieHeader: "sessionKey=sk-C"))
            for uuid in ["org-a", "org-b"] {
                _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(uuid)-old",
                    organizationId: uuid, allCookieHeader: "sessionKey=sk-\(uuid)-old"))
            }
            mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
            mockSession.responseStatusCode = 200
            let result = await auth.manualSignIn(paste)
            XCTAssertEqual(result, .alreadySignedInAllOrgs(refreshedCount: 2, activeAccountRefreshed: false))
        }
        XCTAssertEqual(branchB, ["suspend", "resume"])

        let added = await pauseEvents(prefix: "u9g_") { auth in
            mockSession.responseData = #"[{"uuid":"org-solo"}]"#.data(using: .utf8)!
            mockSession.responseStatusCode = 200
            guard case .success = await auth.manualSignIn(paste) else {
                return XCTFail("expected the single-org add to succeed")
            }
        }
        XCTAssertEqual(added, ["suspend", "resume"])

        let connectionError = await pauseEvents(prefix: "u9h_") { auth in
            // 200 with a body that is not an org array: the decode throws into the catch.
            mockSession.responseData = "not json".data(using: .utf8)!
            mockSession.responseStatusCode = 200
            let result = await auth.manualSignIn(paste)
            XCTAssertEqual(result, .connectionError)
        }
        XCTAssertEqual(connectionError, ["suspend", "resume"])

        let atLimit = await pauseEvents(prefix: "u9i_") { auth in
            for i in 0..<AccountStore.maxAccounts {
                _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(i)",
                    organizationId: "org-\(i)", allCookieHeader: "sessionKey=sk-\(i)"))
            }
            mockSession.responseData = #"[{"uuid":"org-new"}]"#.data(using: .utf8)!
            mockSession.responseStatusCode = 200
            let result = await auth.manualSignIn(paste)
            XCTAssertEqual(result, .accountLimitReached)
        }
        XCTAssertEqual(atLimit, ["suspend", "resume"])
    }

    @MainActor
    func testCompleteManualSignIn_everyExitResumesPolling() async {
        // The second network window of the manual flow. A pause taken in the discovery function and
        // resumed only there would leave these writes unprotected, so this function suspends for
        // itself - and therefore has to resume on all three of its exits.
        let paste = "sessionKey=sk-fresh; __cf_bm=cf-fresh"

        let picked = await pauseEvents(prefix: "u9j_") { auth in
            mockSession.responseData = #"[{"uuid":"org-a"},{"uuid":"org-b"}]"#.data(using: .utf8)!
            mockSession.responseStatusCode = 200
            guard case .needsOrgChoice(let orgs) = await auth.manualSignIn(paste) else {
                return XCTFail("expected the picker route")
            }
            guard case .success = auth.completeManualSignIn(org: orgs[0]) else {
                return XCTFail("expected the pick to add the org")
            }
        }
        XCTAssertEqual(picked, ["suspend", "resume", "suspend", "resume"],
                       "two separate pauses, one per network window, with the picker sitting BETWEEN them unpaused (KTD8)")

        let limitReached = await pauseEvents(prefix: "u9k_") { auth in
            // At the entry limit, with one un-stored org in the list so the picker appears and the
            // pick then fails on the limit.
            for i in 0..<AccountStore.maxAccounts {
                _ = auth.accountStore.addAccount(Account(email: "me@x.com", sessionKey: "sk-\(i)",
                    organizationId: "org-\(i)", allCookieHeader: "sessionKey=sk-\(i)"))
            }
            mockSession.responseData = #"[{"uuid":"org-0"},{"uuid":"org-new"}]"#.data(using: .utf8)!
            mockSession.responseStatusCode = 200
            guard case .needsOrgChoice(let orgs) = await auth.manualSignIn(paste) else {
                return XCTFail("expected the picker route")
            }
            XCTAssertEqual(auth.completeManualSignIn(org: orgs[1]), .accountLimitReached)
        }
        XCTAssertEqual(limitReached, ["suspend", "resume", "suspend", "resume"],
                       "the limit failure is still an exit, and it still resumes")

        let noContext = await pauseEvents(prefix: "u9l_") { auth in
            let org = Organization(uuid: "org-x", name: nil, billingType: nil, emailAddress: nil)
            XCTAssertEqual(auth.completeManualSignIn(org: org), .invalidInput)
        }
        XCTAssertEqual(noContext, ["suspend", "resume"],
                       "the pair sits above the pending-context guard, so even the programming-error exit resumes")
    }

    @MainActor
    func testManualSignIn_thrownRequestStillResumesPolling() async {
        // The catch exit. `defer` is what makes this hold: a resume written at the end of the do
        // block is skipped by exactly this path, and polling would stay dead after a sign-in
        // attempt that failed on connectivity.
        mockSession.responseError = URLError(.notConnectedToInternet)
        let events = await pauseEvents(prefix: "u9m_") { auth in
            let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")
            XCTAssertEqual(result, .connectionError)
        }
        XCTAssertEqual(events, ["suspend", "resume"])
    }

    @MainActor
    func testManualSignIn_suspendsBeforeTheJarIsPrimed() async {
        // The ordering IS the property R11 rests on: a suspend taken after the jar has been
        // re-primed leaves open exactly the window the pause exists to close. Recorded by reading,
        // from inside the suspend callback, the jar the pause is racing - if the suspend ran first,
        // the jar still serves the account that was active when the paste began.
        let auth = makeAuthManager()
        let url = URL(string: "https://claude.ai")!
        func jarSessionKey() -> String? {
            ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?.first { $0.name == "sessionKey" }?.value
        }
        let x = Account(email: "x@test.com", sessionKey: "sk-X", organizationId: "org-X",
                        allCookieHeader: "sessionKey=sk-X; __cf_bm=cf-X")
        _ = auth.accountStore.addAccount(x)
        auth.accountStore.switchTo(x.id)
        XCTAssertEqual(jarSessionKey(), "sk-X", "precondition: the jar holds the active account")

        var jarAtSuspend: [String?] = []
        auth.onSuspendPolling = { jarAtSuspend.append(jarSessionKey()) }
        mockSession.responseData = #"[{"uuid":"org-X"}]"#.data(using: .utf8)!
        mockSession.responseStatusCode = 200

        let result = await auth.manualSignIn("sessionKey=sk-fresh; __cf_bm=cf-fresh")

        guard case .success = result else { return XCTFail("expected the re-auth to land, got \(result)") }
        XCTAssertEqual(jarAtSuspend, ["sk-X"],
                       "polling was suspended while the jar still held the old cookies, so the suspend came FIRST")
        XCTAssertEqual(jarSessionKey(), "sk-fresh",
                       "and the prime really did happen afterwards, so the assertion above is not vacuous")
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

/// An `HTTPDataFetching` double that runs `duringRequest` while the request is in flight, giving
/// the R10 tests a deterministic "the user did something mid-paste" moment instead of racing a
/// detached task against the network call. Kept here rather than folded into MockHTTPSession: the
/// hook has to be async so it can hop back to the main actor to touch the store, and nothing
/// outside the issue #41 restore tests needs it.
private final class InFlightHookSession: HTTPDataFetching {
    private let responseData: Data
    private let statusCode: Int
    private let duringRequest: @Sendable () async -> Void

    init(data: Data, statusCode: Int, duringRequest: @escaping @Sendable () async -> Void) {
        self.responseData = data
        self.statusCode = statusCode
        self.duringRequest = duringRequest
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await duringRequest()
        let url = request.url ?? URL(string: "https://claude.ai")!
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (responseData, response)
    }
}
