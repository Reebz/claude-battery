import XCTest
@testable import ClaudeBattery

final class ClaudeAPITests: XCTestCase {

    // MARK: - Happy Path: makeRequest returns a valid URLRequest

    func testMakeRequestReturnsValidURL() {
        let path = "/api/organizations/uuid-123/usage"
        let request = ClaudeAPI.makeRequest(path: path, sessionKey: "sk123")

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.url?.absoluteString, "https://claude.ai/api/organizations/uuid-123/usage")
    }

    func testMakeRequestSetsCookieHeader() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk123")

        XCTAssertEqual(request?.value(forHTTPHeaderField: "Cookie"), "sessionKey=sk123")
    }

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

    // MARK: - Happy Path: sessionKey embedded correctly in Cookie

    func testMakeRequestEmbedsDifferentSessionKeys() {
        let key = "sk-ant-sid01-abc123-long-session-key"
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: key)

        XCTAssertEqual(request?.value(forHTTPHeaderField: "Cookie"), "sessionKey=\(key)")
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

    // MARK: - All nine expected headers are present

    func testMakeRequestContainsAllNineHeaders() {
        let request = ClaudeAPI.makeRequest(path: "/api/test", sessionKey: "sk1")!

        let expectedHeaders = [
            "Cookie",
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
    }
}
