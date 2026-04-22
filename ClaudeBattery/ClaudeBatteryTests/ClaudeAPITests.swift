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

    // MARK: - Cookie jar behavior (primed via makeRequest; URLSession sends from the jar)

    func testMakeRequestWithNilCookieHeaderPrimesJarWithSessionKey() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk123")

        // URLRequest no longer carries an explicit Cookie header - URLSession builds it
        // from the per-session jar on dispatch so rotating cookies stay fresh.
        XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"))

        let cookies = ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: request!.url!) ?? []
        let sessionCookie = cookies.first { $0.name == "sessionKey" }
        XCTAssertNotNil(sessionCookie, "Jar should contain sessionKey cookie")
        XCTAssertEqual(sessionCookie?.value, "sk123")
    }

    func testMakeRequestWithEmptyCookieHeaderPrimesJarWithSessionKey() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk123", cookieHeader: "")

        XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"))

        let cookies = ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: request!.url!) ?? []
        let sessionCookie = cookies.first { $0.name == "sessionKey" }
        XCTAssertNotNil(sessionCookie, "Empty cookieHeader should still fall back to sessionKey priming")
        XCTAssertEqual(sessionCookie?.value, "sk123")
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

    func testMakeRequestEmbedsDifferentSessionKeys() {
        let key = "sk-ant-sid01-abc123-long-session-key"
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
}
