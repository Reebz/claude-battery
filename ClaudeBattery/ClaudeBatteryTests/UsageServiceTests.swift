import XCTest
@testable import ClaudeBattery

// MARK: - UsageData Tests (pure value type, no mocks needed)

final class UsageDataTests: XCTestCase {

    /// Decode a UsageResponse from the given fixture JSON using the same
    /// decoder configuration as the production code.
    private func decodeFixture(_ name: String) throws -> UsageResponse {
        let url = Bundle(for: type(of: self)).url(
            forResource: name, withExtension: "json"
        ) ?? fixtureURL(named: name)

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageResponse.self, from: data)
    }

    /// Fallback when the fixture is not embedded in the test bundle.
    private func fixtureURL(named name: String) -> URL {
        // Walk up from the compiled test binary to find the source tree
        let file = URL(fileURLWithPath: #file)
        let testsDir = file.deletingLastPathComponent()
        return testsDir
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
    }

    // MARK: - Happy path

    func testFullResponse_correctRemainingPercentages() throws {
        let response = try decodeFixture("usage_full")
        let usage = UsageData(from: response)

        // remaining = 100 - utilization
        XCTAssertEqual(usage.weeklyRemaining, 40.0, accuracy: 0.01)   // 100 - 60
        XCTAssertEqual(usage.sessionRemaining, 65.0, accuracy: 0.01)  // 100 - 35
        XCTAssertEqual(usage.opusRemaining, 20.0, accuracy: 0.01)     // 100 - 80
        XCTAssertEqual(usage.sonnetRemaining, 90.0, accuracy: 0.01)   // 100 - 10
        XCTAssertNotNil(usage.weeklyResetDate)
        XCTAssertNotNil(usage.sessionResetDate)
    }

    // MARK: - Nil utilization -> 100% remaining

    func testNilUtilization_defaultsTo100Remaining() throws {
        let response = try decodeFixture("usage_nil_fields")
        let usage = UsageData(from: response)

        // When utilization is nil, formula is 100 - 0 = 100
        XCTAssertEqual(usage.weeklyRemaining, 100.0)
        XCTAssertEqual(usage.sessionRemaining, 100.0)
        XCTAssertEqual(usage.opusRemaining, 100.0)
        XCTAssertEqual(usage.sonnetRemaining, 100.0)
        XCTAssertNil(usage.weeklyResetDate)
        XCTAssertNil(usage.sessionResetDate)
        XCTAssertNil(usage.extraUsage)
    }

    // MARK: - Clamping: utilization > 100

    func testUtilizationOver100_clampedToZeroRemaining() {
        let tier = makeTier(utilization: 150.0)
        let response = UsageResponse(
            fiveHour: tier,
            sevenDay: tier,
            sevenDayOpus: tier,
            sevenDaySonnet: tier,
            extraUsage: nil
        )
        let usage = UsageData(from: response)

        // max(0, min(100, 100 - 150)) = max(0, -50) = 0
        XCTAssertEqual(usage.weeklyRemaining, 0.0)
        XCTAssertEqual(usage.sessionRemaining, 0.0)
        XCTAssertEqual(usage.opusRemaining, 0.0)
        XCTAssertEqual(usage.sonnetRemaining, 0.0)
    }

    // MARK: - Clamping: utilization < 0

    func testNegativeUtilization_clampedTo100Remaining() {
        let tier = makeTier(utilization: -30.0)
        let response = UsageResponse(
            fiveHour: tier,
            sevenDay: tier,
            sevenDayOpus: tier,
            sevenDaySonnet: tier,
            extraUsage: nil
        )
        let usage = UsageData(from: response)

        // max(0, min(100, 100 - (-30))) = min(100, 130) = 100
        XCTAssertEqual(usage.weeklyRemaining, 100.0)
        XCTAssertEqual(usage.sessionRemaining, 100.0)
        XCTAssertEqual(usage.opusRemaining, 100.0)
        XCTAssertEqual(usage.sonnetRemaining, 100.0)
    }

    // MARK: - Helpers

    /// Build a UsageTier by round-tripping through JSON so Codable init is used.
    private func makeTier(utilization: Double, resetsAt: Date? = nil) -> UsageTier {
        var json: [String: Any] = ["utilization": utilization]
        if let date = resetsAt {
            let formatter = ISO8601DateFormatter()
            json["resets_at"] = formatter.string(from: date)
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(UsageTier.self, from: data)
    }
}

// MARK: - ExtraUsageData Tests

final class ExtraUsageDataTests: XCTestCase {

    // MARK: - Happy path

    func testEnabledWithValidValues_correctConversion() {
        let tier = makeExtraTier(isEnabled: true, monthlyLimit: 5000, usedCredits: 1250)
        let extra = ExtraUsageData(from: tier)

        XCTAssertNotNil(extra)
        // Cents to dollars: 1250 / 100 = 12.50
        XCTAssertEqual(extra!.spent, 12.50, accuracy: 0.01)
        // Cents to dollars: 5000 / 100 = 50.00
        XCTAssertEqual(extra!.limit, 50.00, accuracy: 0.01)
        // Percentage: 1250 / 5000 * 100 = 25%
        XCTAssertEqual(extra!.percentage, 25.0, accuracy: 0.01)
    }

    // MARK: - Disabled -> nil

    func testDisabled_returnsNil() {
        let tier = makeExtraTier(isEnabled: false, monthlyLimit: 5000, usedCredits: 1000)
        XCTAssertNil(ExtraUsageData(from: tier))
    }

    func testNilTier_returnsNil() {
        XCTAssertNil(ExtraUsageData(from: nil))
    }

    // MARK: - Zero limit -> nil (division guard)

    func testZeroLimit_returnsNil() {
        let tier = makeExtraTier(isEnabled: true, monthlyLimit: 0, usedCredits: 100)
        XCTAssertNil(ExtraUsageData(from: tier))
    }

    // MARK: - Percentage clamping

    func testPercentageClamped_doesNotExceed100() {
        // usedCredits exceeds monthlyLimit
        let tier = makeExtraTier(isEnabled: true, monthlyLimit: 1000, usedCredits: 2000)
        let extra = ExtraUsageData(from: tier)

        XCTAssertNotNil(extra)
        XCTAssertEqual(extra!.percentage, 100.0, accuracy: 0.01)
    }

    func testPercentageClamped_doesNotGoBelowZero() {
        // Negative usedCredits (unlikely but defensive)
        let tier = makeExtraTier(isEnabled: true, monthlyLimit: 1000, usedCredits: -500)
        let extra = ExtraUsageData(from: tier)

        XCTAssertNotNil(extra)
        XCTAssertEqual(extra!.percentage, 0.0, accuracy: 0.01)
    }

    // MARK: - Helpers

    private func makeExtraTier(
        isEnabled: Bool,
        monthlyLimit: Double,
        usedCredits: Double
    ) -> ExtraUsageTier {
        var json: [String: Any] = [
            "is_enabled": isEnabled,
            "monthly_limit": monthlyLimit,
            "used_credits": usedCredits,
            "utilization": usedCredits / max(monthlyLimit, 1) * 100
        ]
        // Handle zero limit edge case for utilization
        if monthlyLimit == 0 {
            json["utilization"] = 0.0
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(ExtraUsageTier.self, from: data)
    }
}

// MARK: - PrepaidBalance Tests

final class PrepaidBalanceTests: XCTestCase {

    func testPositiveAmount_convertsCentsToDollars() {
        let response = makePrepaidResponse(amount: 3750)
        let balance = PrepaidBalance(from: response)
        XCTAssertNotNil(balance)
        XCTAssertEqual(balance!.dollars, 37.50, accuracy: 0.01)
    }

    func testLargeAmount_convertsCentsToDollars() {
        let response = makePrepaidResponse(amount: 50000)
        let balance = PrepaidBalance(from: response)
        XCTAssertNotNil(balance)
        XCTAssertEqual(balance!.dollars, 500.00, accuracy: 0.01)
    }

    func testZeroAmount_returnsNil() {
        let response = makePrepaidResponse(amount: 0)
        XCTAssertNil(PrepaidBalance(from: response))
    }

    func testNegativeAmount_returnsNil() {
        let response = makePrepaidResponse(amount: -100)
        XCTAssertNil(PrepaidBalance(from: response))
    }

    func testNilResponse_returnsNil() {
        XCTAssertNil(PrepaidBalance(from: nil))
    }

    func testNilAmount_returnsNil() {
        let response = makePrepaidResponse(amount: nil)
        XCTAssertNil(PrepaidBalance(from: response))
    }

    func testDecodesFromJSON() {
        let json = """
        {"amount": 1250}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try! decoder.decode(PrepaidCreditsResponse.self, from: json)
        let balance = PrepaidBalance(from: response)
        XCTAssertNotNil(balance)
        XCTAssertEqual(balance!.dollars, 12.50, accuracy: 0.01)
    }

    func testDecodesFromEmptyJSON() {
        let json = "{}".data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try! decoder.decode(PrepaidCreditsResponse.self, from: json)
        XCTAssertNil(response.amount)
        XCTAssertNil(PrepaidBalance(from: response))
    }

    private func makePrepaidResponse(amount: Double?) -> PrepaidCreditsResponse {
        if let amount {
            let json = "{\"amount\": \(amount)}".data(using: .utf8)!
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try! decoder.decode(PrepaidCreditsResponse.self, from: json)
        } else {
            let json = "{}".data(using: .utf8)!
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try! decoder.decode(PrepaidCreditsResponse.self, from: json)
        }
    }
}

// MARK: - UsageService.pollUsage() Tests

final class UsageServicePollTests: XCTestCase {

    private var suiteName: String!
    private var mockSession: MockHTTPSession!
    private var storage: StorageService!
    private var accountStore: AccountStore!

    /// Shared test account.
    private let testAccount = Account(
        email: "test@example.com",
        sessionKey: "sk-ant-test-key",
        organizationId: "org-test-123"
    )

    @MainActor
    override func setUp() {
        super.setUp()
        mockSession = MockHTTPSession()

        // Isolated UserDefaults per test to avoid cross-contamination
        suiteName = "com.claudebattery.tests.usage.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        storage = StorageService(defaults: defaults, prefix: "test_")
        accountStore = AccountStore(storage: storage)

        // Seed an active account so pollUsage has something to work with
        _ = accountStore.addAccount(testAccount)
    }

    @MainActor
    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        mockSession = nil
        storage = nil
        accountStore = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Happy path: 200 with full JSON

    @MainActor
    func testPoll200_populatesLatestUsage() async {
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        let usage = try! XCTUnwrap(service.latestUsage)
        XCTAssertEqual(usage.weeklyRemaining, 40.0, accuracy: 0.01)
        XCTAssertEqual(usage.sessionRemaining, 65.0, accuracy: 0.01)
        XCTAssertEqual(service.consecutiveFailures, 0)
        XCTAssertFalse(service.authFailed)
        XCTAssertNotNil(service.lastSuccessfulFetch)
    }

    @MainActor
    func testPoll200_capturesRequestHeaders() async {
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        let request = mockSession.lastRequest
        XCTAssertNotNil(request)
        XCTAssertTrue(request!.url!.absoluteString.contains("org-test-123"))

        // Cookie is managed via ClaudeAPI's per-session jar (primed in setUp via
        // accountStore.addAccount -> ClaudeAPI.activateCookies). URLSession constructs
        // the Cookie header on dispatch, so URLRequest.Cookie is nil here by design.
        XCTAssertNil(request!.value(forHTTPHeaderField: "Cookie"))

        let cookies = ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: request!.url!) ?? []
        let sessionCookie = cookies.first { $0.name == "sessionKey" }
        XCTAssertNotNil(sessionCookie, "Cookie jar should have been primed with sessionKey on account activation")
        XCTAssertEqual(sessionCookie?.value, "sk-ant-test-key")
    }

    // MARK: - 401 auth failure

    @MainActor
    func testPoll401_setsAuthFailed() async {
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 401

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        var authCallbackFired = false
        service.onAuthFailure = { authCallbackFired = true }

        await service.pollUsage()

        XCTAssertTrue(service.authFailed)
        XCTAssertEqual(service.consecutiveFailures, 1)
        XCTAssertTrue(authCallbackFired)
        XCTAssertNil(service.latestUsage)
    }

    // MARK: - 403 auth failure (same behavior as 401)

    @MainActor
    func testPoll403_setsAuthFailed() async {
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 403

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        var authCallbackFired = false
        service.onAuthFailure = { authCallbackFired = true }

        await service.pollUsage()

        XCTAssertTrue(service.authFailed)
        XCTAssertEqual(service.consecutiveFailures, 1)
        XCTAssertTrue(authCallbackFired)
    }

    // MARK: - 500 server error

    @MainActor
    func testPoll500_incrementsConsecutiveFailures() async {
        mockSession.responseData = Data("{\"error\":\"internal\"}".utf8)
        mockSession.responseStatusCode = 500

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        XCTAssertEqual(service.consecutiveFailures, 1)
        XCTAssertFalse(service.authFailed)
        XCTAssertNil(service.latestUsage)
    }

    @MainActor
    func testPollMultiple500s_incrementsEachTime() async {
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 500

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        // pollUsage guards against concurrent calls via isPolling;
        // await ensures each call completes before the next starts.
        await service.pollUsage()
        await service.pollUsage()
        await service.pollUsage()

        XCTAssertEqual(service.consecutiveFailures, 3)
    }

    // MARK: - 200 after failures resets counter

    @MainActor
    func testPoll200AfterFailures_resetsConsecutiveFailures() async {
        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        // Cause some failures first
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 500
        await service.pollUsage()
        await service.pollUsage()
        XCTAssertEqual(service.consecutiveFailures, 2)

        // Now succeed
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        await service.pollUsage()

        XCTAssertEqual(service.consecutiveFailures, 0)
        XCTAssertNotNil(service.latestUsage)
    }

    // MARK: - No active account -> poll is a no-op

    @MainActor
    func testPollWithNoAccount_doesNothing() async {
        // Remove the seeded account
        accountStore.removeAccount(testAccount.id)
        XCTAssertNil(accountStore.activeAccount)

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        XCTAssertTrue(mockSession.capturedRequests.isEmpty)
        XCTAssertEqual(service.consecutiveFailures, 0)
    }

    // MARK: - Network error increments failures

    @MainActor
    func testPollNetworkError_incrementsFailures() async {
        mockSession.responseError = URLError(.notConnectedToInternet)

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        XCTAssertEqual(service.consecutiveFailures, 1)
        XCTAssertNil(service.latestUsage)
    }

    // MARK: - Extra usage populated from fixture

    @MainActor
    func testPoll200WithExtraUsage_populatesExtraUsageData() async {
        mockSession.responseData = fixtureData("usage_extra_usage")
        mockSession.responseStatusCode = 200

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        let extra = try! XCTUnwrap(service.latestUsage?.extraUsage)
        // 7500 cents / 100 = $75.00
        XCTAssertEqual(extra.spent, 75.0, accuracy: 0.01)
        // 10000 cents / 100 = $100.00
        XCTAssertEqual(extra.limit, 100.0, accuracy: 0.01)
        // 7500 / 10000 * 100 = 75%
        XCTAssertEqual(extra.percentage, 75.0, accuracy: 0.01)
    }

    // MARK: - Prepaid credits integration

    @MainActor
    func testPoll200WithPrepaidCredits_populatesPrepaidBalance() async {
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        mockSession.urlOverrides["prepaid/credits"] = (
            data: """
            {"amount": 2500}
            """.data(using: .utf8)!,
            statusCode: 200
        )

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        XCTAssertNotNil(service.latestUsage)
        let balance = service.latestUsage?.prepaidBalance
        XCTAssertNotNil(balance,
                        "Prepaid balance should be populated when credits endpoint returns valid data")
        if let dollars = balance?.dollars {
            XCTAssertEqual(dollars, 25.0, accuracy: 0.01,
                           "2500 cents should convert to $25.00")
        }
    }

    @MainActor
    func testPoll200WithCredits401_prepaidBalanceIsNil() async {
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        mockSession.urlOverrides["prepaid/credits"] = (
            data: Data(),
            statusCode: 401
        )

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        XCTAssertNotNil(service.latestUsage)
        XCTAssertNil(service.latestUsage?.prepaidBalance,
                     "Prepaid balance should be nil when credits endpoint returns 401")
        XCTAssertEqual(service.consecutiveFailures, 0,
                       "Credits 401 should not affect consecutiveFailures")
    }

    @MainActor
    func testPoll200WithMalformedCredits_prepaidBalanceIsNil() async {
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        mockSession.urlOverrides["prepaid/credits"] = (
            data: "not json".data(using: .utf8)!,
            statusCode: 200
        )

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        XCTAssertNotNil(service.latestUsage)
        XCTAssertNil(service.latestUsage?.prepaidBalance,
                     "Prepaid balance should be nil when credits response is malformed")
    }

    // MARK: - Auth failure clears latestUsage

    @MainActor
    func testPoll401_clearsLatestUsage() async {
        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        // First, get some usage data
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        await service.pollUsage()
        XCTAssertNotNil(service.latestUsage, "Should have usage data after successful poll")

        // Now simulate auth failure
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 401
        await service.pollUsage()

        XCTAssertTrue(service.authFailed)
        XCTAssertNil(service.latestUsage,
                     "latestUsage should be cleared on auth failure so popover shows re-auth screen")
    }

    // MARK: - switchAccount resets authFailed

    @MainActor
    func testSwitchAccount_resetsAuthFailedAndConsecutiveFailures() async {
        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        // Simulate auth failure state
        mockSession.responseData = Data()
        mockSession.responseStatusCode = 401
        await service.pollUsage()
        XCTAssertTrue(service.authFailed)
        XCTAssertEqual(service.consecutiveFailures, 1)

        // switchAccount should reset everything
        service.switchAccount()

        XCTAssertFalse(service.authFailed, "switchAccount should clear authFailed")
        XCTAssertEqual(service.consecutiveFailures, 0, "switchAccount should reset consecutiveFailures")
        XCTAssertNil(service.latestUsage, "switchAccount should clear latestUsage")
    }

    // MARK: - Helpers

    private func fixtureData(_ name: String) -> Data {
        let file = URL(fileURLWithPath: #file)
        let testsDir = file.deletingLastPathComponent()
        let url = testsDir
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
        return try! Data(contentsOf: url)
    }
}
