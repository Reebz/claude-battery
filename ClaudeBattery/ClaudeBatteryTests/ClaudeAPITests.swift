import XCTest
@testable import ClaudeBattery

final class ClaudeAPITests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Each test starts with a clean cookie jar so priming behavior is deterministic.
        ClaudeAPI.clearClaudeCookies()
    }

    override func tearDown() {
        ClaudeAPI.clearClaudeCookies()
        super.tearDown()
    }

    // MARK: - Happy Path: makeRequest returns a valid URLRequest

    func testMakeRequestReturnsValidURL() {
        let path = "/api/organizations/uuid-123/usage"
        let request = ClaudeAPI.makeRequest(path: path, sessionKey: "sk123")

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.url?.absoluteString, "https://claude.ai/api/organizations/uuid-123/usage")
    }

    // MARK: - Cookie jar behavior
    // makeRequest only primes the jar when cookieHeader is explicitly provided.
    // With nil or empty cookieHeader, callers must prime via activateCookies at
    // account-activation boundaries (AccountStore.switchTo, etc).

    func testMakeRequestWithNilCookieHeaderDoesNotPrimeJar() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk123")

        XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"))

        let cookies = ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: request!.url!) ?? []
        let sessionCookie = cookies.first { $0.name == "sessionKey" }
        XCTAssertNil(sessionCookie, "Nil cookieHeader must not auto-prime the jar (TOCTOU fix)")
    }

    func testMakeRequestWithEmptyCookieHeaderDoesNotPrimeJar() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk123", cookieHeader: "")

        XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"))

        let cookies = ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: request!.url!) ?? []
        let sessionCookie = cookies.first { $0.name == "sessionKey" }
        XCTAssertNil(sessionCookie, "Empty cookieHeader must not prime the jar")
    }

    func testMakeRequestWithPopulatedCookieHeaderPrimesJarWithAllCookies() {
        let header = "sessionKey=sk123; __cf_bm=cf-bm-value; anthropic-csrf-token=csrf-token"
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk123", cookieHeader: header)

        XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"))

        let cookies = ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: request!.url!) ?? []
        XCTAssertEqual(cookies.first { $0.name == "sessionKey" }?.value, "sk123")
        XCTAssertEqual(cookies.first { $0.name == "__cf_bm" }?.value, "cf-bm-value")
        XCTAssertEqual(cookies.first { $0.name == "anthropic-csrf-token" }?.value, "csrf-token")
    }

    func testActivateCookiesThenMakeRequestPreservesJar() {
        let key = "sk-ant-sid01-abc123-long-session-key"
        ClaudeAPI.activateCookies(sessionKey: key, cookieHeader: nil)
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: key)

        let cookies = ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: request!.url!) ?? []
        let sessionCookie = cookies.first { $0.name == "sessionKey" }
        XCTAssertEqual(sessionCookie?.value, key)
    }

    // MARK: - Static request headers

    func testMakeRequestSetsAnthropicClientPlatform() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk123")

        XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-client-platform"), "web_claude_ai")
    }

    func testMakeRequestSetsAnthropicClientVersion() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk123")

        XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-client-version"), "1.0.0")
    }

    func testMakeRequestSetsUserAgent() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk123")

        let ua = request?.value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(ua)
        XCTAssertTrue(ua!.contains("Safari/605.1.15"), "User-Agent should contain Safari token")
        XCTAssertTrue(ua!.contains("Macintosh"), "User-Agent should contain Macintosh")
    }

    func testMakeRequestSetsSecFetchHeaders() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk123")

        XCTAssertEqual(request?.value(forHTTPHeaderField: "sec-fetch-dest"), "empty")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "sec-fetch-mode"), "cors")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "sec-fetch-site"), "same-origin")
    }

    func testMakeRequestSetsOriginAndReferer() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk123")

        XCTAssertEqual(request?.value(forHTTPHeaderField: "origin"), "https://claude.ai")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "referer"), "https://claude.ai/settings/usage")
    }

    // MARK: - Happy Path: Various paths

    func testMakeRequestWithRootPath() {
        let request = ClaudeAPI.makeRequest(path: "/", sessionKey: "sk1")

        XCTAssertEqual(request?.url?.absoluteString, "https://claude.ai/")
    }

    func testMakeRequestWithEmptyPath() {
        let request = ClaudeAPI.makeRequest(path: "", sessionKey: "sk1")

        // Empty path appended to baseURL yields "https://claude.ai"
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.url?.absoluteString, "https://claude.ai")
    }

    // MARK: - All expected URLRequest headers (Cookie lives in the jar, not on the request)

    func testMakeRequestContainsAllEightURLRequestHeaders() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk1")!

        // Cookie is managed via URLSession's cookie jar (see cookie-jar tests), not set here.
        let expectedHeaders = [
            "anthropic-client-platform",
            "anthropic-client-version",
            "User-Agent",
            "sec-fetch-dest",
            "sec-fetch-mode",
            "sec-fetch-site",
            "origin",
            "referer",
        ]
        for header in expectedHeaders {
            XCTAssertNotNil(
                request.value(forHTTPHeaderField: header),
                "Missing expected header: \(header)"
            )
        }

        // Explicit Cookie header must NOT be set - URLSession builds it from the jar so
        // rotating cookies (Cloudflare `__cf_bm`) flow through `Set-Cookie` responses.
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    // MARK: - injectCookies edge cases

    func testInjectCookiesSplitsOnBareSemicolon() {
        // RFC 6265 allows ";" without trailing space between cookie pairs
        let header = "sessionKey=sk123;__cf_bm=cfvalue"
        ClaudeAPI.activateCookies(sessionKey: "sk123", cookieHeader: header)
        let url = URL(string: "https://claude.ai")!
        let cookies = ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url) ?? []
        XCTAssertNotNil(cookies.first { $0.name == "sessionKey" }, "sessionKey missing after bare-semicolon split")
        XCTAssertNotNil(cookies.first { $0.name == "__cf_bm" }, "__cf_bm missing after bare-semicolon split")
    }

    func testInjectCookiesHandlesValueWithEquals() {
        // Base64-encoded session keys often contain "=" padding
        let header = "sessionKey=sk-ant-abc123=="
        ClaudeAPI.activateCookies(sessionKey: "x", cookieHeader: header)
        let url = URL(string: "https://claude.ai")!
        let cookies = ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url) ?? []
        let sk = cookies.first { $0.name == "sessionKey" }
        XCTAssertEqual(sk?.value, "sk-ant-abc123==", "Cookie value with = should be preserved")
    }

    func testActivateCookiesThenClearClaudeCookies() {
        ClaudeAPI.activateCookies(sessionKey: "sk-test", cookieHeader: "sessionKey=sk-test; __cf_bm=cf")
        let url = URL(string: "https://claude.ai")!
        XCTAssertTrue((ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url) ?? []).count >= 2)

        ClaudeAPI.clearClaudeCookies()
        let after = ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url) ?? []
        XCTAssertTrue(after.isEmpty, "clearClaudeCookies should remove all claude.ai cookies")
    }
}

// MARK: - isClaudeCookie / isSessionCookie Tests

@MainActor
final class CookieDomainValidationTests: XCTestCase {

    func testIsSessionCookie_exactDomain() {
        let cookie = makeCookie(name: "sessionKey", domain: "claude.ai")
        XCTAssertTrue(AuthManager.isSessionCookie(cookie))
    }

    func testIsSessionCookie_leadingDotDomain() {
        let cookie = makeCookie(name: "sessionKey", domain: ".claude.ai")
        XCTAssertTrue(AuthManager.isSessionCookie(cookie))
    }

    func testIsSessionCookie_rejectsEvilDomain() {
        let cookie = makeCookie(name: "sessionKey", domain: "evil-claude.ai")
        XCTAssertFalse(AuthManager.isSessionCookie(cookie), "hasSuffix('.claude.ai') must not pass - Critical Pattern #2")
    }

    func testIsSessionCookie_rejectsWrongName() {
        let cookie = makeCookie(name: "__cf_bm", domain: "claude.ai")
        XCTAssertFalse(AuthManager.isSessionCookie(cookie))
    }

    func testIsClaudeCookie_exactDomain() {
        let cookie = makeCookie(name: "__cf_bm", domain: "claude.ai")
        XCTAssertTrue(AuthManager.isClaudeCookie(cookie))
    }

    func testIsClaudeCookie_leadingDotDomain() {
        let cookie = makeCookie(name: "__cf_bm", domain: ".claude.ai")
        XCTAssertTrue(AuthManager.isClaudeCookie(cookie))
    }

    func testIsClaudeCookie_rejectsEvilDomain() {
        let cookie = makeCookie(name: "__cf_bm", domain: "evil-claude.ai")
        XCTAssertFalse(AuthManager.isClaudeCookie(cookie), "hasSuffix must not pass - Critical Pattern #2")
    }

    func testIsClaudeCookie_rejectsSubdomain() {
        let cookie = makeCookie(name: "__cf_bm", domain: "cdn.claude.ai")
        XCTAssertFalse(AuthManager.isClaudeCookie(cookie), "Subdomain cookies should not pass exact-match")
    }

    func testIsClaudeCookie_rejectsUnrelatedDomain() {
        let cookie = makeCookie(name: "sessionKey", domain: "google.com")
        XCTAssertFalse(AuthManager.isClaudeCookie(cookie))
    }

    private func makeCookie(name: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: "test-value",
            .domain: domain,
            .path: "/",
            .secure: "TRUE",
        ])!
    }
}
