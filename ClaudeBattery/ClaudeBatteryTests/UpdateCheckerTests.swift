import XCTest
@testable import ClaudeBattery

@MainActor
final class UpdateCheckerTests: XCTestCase {

    private var mockSession: MockHTTPSession!

    override func setUp() {
        super.setUp()
        mockSession = MockHTTPSession()
    }

    override func tearDown() {
        mockSession = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeChecker() -> UpdateChecker {
        UpdateChecker(session: mockSession)
    }

    /// Loads a JSON fixture from the Fixtures directory.
    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            // Fall back to constructing the path relative to the test file
            let testDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
            let fixtureURL = testDir.appendingPathComponent("Fixtures/\(name).json")
            return try Data(contentsOf: fixtureURL)
        }
        return try Data(contentsOf: url)
    }

    private func makeReleaseJSON(tagName: String, htmlURL: String = "https://github.com/Reebz/claude-battery/releases/tag/v2.0") -> Data {
        """
        {
          "tag_name": "\(tagName)",
          "html_url": "\(htmlURL)",
          "name": "\(tagName)",
          "draft": false,
          "prerelease": false
        }
        """.data(using: .utf8)!
    }

    // MARK: - Happy Path: New version available

    func testCheckForUpdateSetsAvailableVersionWhenNewerExists() async {
        let checker = makeChecker()
        mockSession.responseData = try! loadFixture("github_release")
        mockSession.responseStatusCode = 200

        // Trigger the check by calling startChecking, which calls checkForUpdate
        checker.startChecking()

        // UpdateChecker.startChecking() fires a detached Task internally with no await handle.
        // We sleep to allow the async work to complete. 500ms is generous for CI safety.
        try? await Task.sleep(nanoseconds: 500_000_000)

        // The fixture has tag_name "v2.0" -- current bundle version in tests is
        // typically "1.0" or similar, so 2.0 should be newer
        XCTAssertNotNil(checker.availableVersion, "Should detect v2.0 as available update")
        XCTAssertNotNil(checker.downloadURL, "Should set download URL from html_url")

        checker.stopChecking()
    }

    func testCheckForUpdateSetsCorrectDownloadURL() async {
        let checker = makeChecker()
        mockSession.responseData = makeReleaseJSON(tagName: "v2.0")
        mockSession.responseStatusCode = 200

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(
            checker.downloadURL?.absoluteString,
            "https://github.com/Reebz/claude-battery/releases/tag/v2.0"
        )

        checker.stopChecking()
    }

    // MARK: - Happy Path: Version string strips "v" prefix

    func testCheckForUpdateStripsVPrefix() async {
        let checker = makeChecker()
        mockSession.responseData = makeReleaseJSON(tagName: "v3.5")
        mockSession.responseStatusCode = 200

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        // availableVersion should be the stripped version, not "v3.5"
        XCTAssertEqual(checker.availableVersion, "3.5")

        checker.stopChecking()
    }

    // MARK: - Edge Case: Invalid version format (too many segments)

    func testCheckForUpdateRejectsInvalidVersionFormat() async {
        let checker = makeChecker()
        // "v1.0.0.0" has four segments -- isValidVersion requires ^\d+\.\d+(\.\d+)?$
        mockSession.responseData = makeReleaseJSON(tagName: "v1.0.0.0")
        mockSession.responseStatusCode = 200

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(checker.availableVersion, "Should reject version with four segments")
        XCTAssertNil(checker.downloadURL)

        checker.stopChecking()
    }

    // MARK: - Edge Case: Valid three-segment version

    func testCheckForUpdateAcceptsThreeSegmentVersion() async {
        let checker = makeChecker()
        mockSession.responseData = makeReleaseJSON(tagName: "v99.1.2")
        mockSession.responseStatusCode = 200

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(checker.availableVersion, "99.1.2")

        checker.stopChecking()
    }

    // MARK: - Edge Case: Non-numeric version string

    func testCheckForUpdateRejectsNonNumericVersion() async {
        let checker = makeChecker()
        mockSession.responseData = makeReleaseJSON(tagName: "vbeta")
        mockSession.responseStatusCode = 200

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(checker.availableVersion, "Should reject non-numeric version")

        checker.stopChecking()
    }

    // MARK: - Error Path: HTTP 404

    func testCheckForUpdateHandles404() async {
        let checker = makeChecker()
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 404

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(checker.availableVersion, "Should not set version on 404")
        XCTAssertNil(checker.downloadURL, "Should not set URL on 404")

        checker.stopChecking()
    }

    // MARK: - Error Path: Network error

    func testCheckForUpdateHandlesNetworkError() async {
        let checker = makeChecker()
        mockSession.responseError = URLError(.notConnectedToInternet)

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(checker.availableVersion, "Should not set version on network error")
        XCTAssertNil(checker.downloadURL, "Should not set URL on network error")

        checker.stopChecking()
    }

    // MARK: - Error Path: Malformed JSON

    func testCheckForUpdateHandlesMalformedJSON() async {
        let checker = makeChecker()
        mockSession.responseData = "not json".data(using: .utf8)!
        mockSession.responseStatusCode = 200

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(checker.availableVersion, "Should not set version on malformed JSON")

        checker.stopChecking()
    }

    // MARK: - Edge Case: html_url with non-GitHub host is rejected

    func testCheckForUpdateRejectsNonGitHubHost() async {
        let checker = makeChecker()
        mockSession.responseData = makeReleaseJSON(
            tagName: "v9.0",
            htmlURL: "https://evil.com/malware"
        )
        mockSession.responseStatusCode = 200

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(checker.availableVersion, "Should reject non-GitHub download URL")
        XCTAssertNil(checker.downloadURL)

        checker.stopChecking()
    }

    // MARK: - Edge Case: http scheme (not https) is rejected

    func testCheckForUpdateRejectsHTTPScheme() async {
        let checker = makeChecker()
        mockSession.responseData = makeReleaseJSON(
            tagName: "v9.0",
            htmlURL: "http://github.com/Reebz/claude-battery/releases/tag/v9.0"
        )
        mockSession.responseStatusCode = 200

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(checker.availableVersion, "Should reject http:// URL")
        XCTAssertNil(checker.downloadURL)

        checker.stopChecking()
    }

    // MARK: - Request verification

    func testCheckForUpdateSendsCorrectUserAgent() async {
        let checker = makeChecker()
        mockSession.responseData = makeReleaseJSON(tagName: "v2.0")
        mockSession.responseStatusCode = 200

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        let request = mockSession.lastRequest
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "claude-battery")

        checker.stopChecking()
    }

    func testCheckForUpdateHitsGitHubReleasesEndpoint() async {
        let checker = makeChecker()
        mockSession.responseData = makeReleaseJSON(tagName: "v2.0")
        mockSession.responseStatusCode = 200

        checker.startChecking()
        try? await Task.sleep(nanoseconds: 500_000_000)

        let request = mockSession.lastRequest
        XCTAssertTrue(
            request?.url?.absoluteString.contains("api.github.com/repos/Reebz/claude-battery/releases/latest") ?? false,
            "Should request the GitHub releases endpoint"
        )

        checker.stopChecking()
    }

    // MARK: - stopChecking clears state

    func testStopCheckingPreventsSubsequentUpdates() async {
        let checker = makeChecker()
        mockSession.responseData = makeReleaseJSON(tagName: "v2.0")
        mockSession.responseStatusCode = 200

        checker.stopChecking()

        // No startChecking called, so no request should be made
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(mockSession.capturedRequests.isEmpty)
        XCTAssertNil(checker.availableVersion)
    }

    // MARK: - Version Comparison Tests

    func testIsNewerVersion_newerMajor() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.0", than: "1.45"))
    }

    func testIsNewerVersion_newerMinor() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("1.46", than: "1.45"))
    }

    func testIsNewerVersion_newerPatch() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("1.45.1", than: "1.45"))
    }

    func testIsNewerVersion_equal() {
        XCTAssertFalse(UpdateChecker.isNewerVersion("1.45", than: "1.45"))
    }

    func testIsNewerVersion_equalWithPrecisionMismatch() {
        XCTAssertFalse(UpdateChecker.isNewerVersion("1.45.0", than: "1.45"),
                       "1.45.0 and 1.45 should be equal — the reported bug")
    }

    func testIsNewerVersion_older() {
        XCTAssertFalse(UpdateChecker.isNewerVersion("1.44", than: "1.45"))
    }

    func testIsNewerVersion_numericNotLexicographic() {
        XCTAssertTrue(UpdateChecker.isNewerVersion("2.0", than: "1.9"),
                      "2.0 > 1.9 numerically (not '2.0' < '1.9' lexicographically)")
    }

    func testIsNewerVersion_threeComponentEqual() {
        XCTAssertFalse(UpdateChecker.isNewerVersion("1.45.0", than: "1.45.0"))
    }
}
