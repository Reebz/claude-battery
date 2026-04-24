import XCTest
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

        let store = auth.accountStore
        XCTAssertEqual(store.accounts.count, 0,
                       "No account is created when the org picker has no window to attach to")
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
