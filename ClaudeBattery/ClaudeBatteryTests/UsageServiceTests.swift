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
        // Per-model now derives from seven_day_* gated on non-null (KTD3), in [Opus, Sonnet] order.
        XCTAssertEqual(usage.modelUsages.count, 2)
        XCTAssertEqual(usage.modelUsages[0].displayName, "Opus")
        XCTAssertEqual(usage.modelUsages[0].remainingPercent, 20.0, accuracy: 0.01)  // 100 - 80
        XCTAssertEqual(usage.modelUsages[1].displayName, "Sonnet")
        XCTAssertEqual(usage.modelUsages[1].remainingPercent, 90.0, accuracy: 0.01)  // 100 - 10
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
        // Null per-model now hides the bar entirely - no fabricated 100% (KTD3).
        XCTAssertTrue(usage.modelUsages.isEmpty)
        XCTAssertNil(usage.weeklyResetDate)
        XCTAssertNil(usage.sessionResetDate)
    }

    // MARK: - Clamping: utilization > 100

    func testUtilizationOver100_clampedToZeroRemaining() {
        let tier = makeTier(utilization: 150.0)
        let response = UsageResponse(
            fiveHour: tier,
            sevenDay: tier,
            sevenDayOpus: tier,
            sevenDaySonnet: tier,
            extraUsage: nil,
            limits: nil,
            spend: nil
        )
        let usage = UsageData(from: response)

        // max(0, min(100, 100 - 150)) = max(0, -50) = 0
        XCTAssertEqual(usage.weeklyRemaining, 0.0)
        XCTAssertEqual(usage.sessionRemaining, 0.0)
        XCTAssertEqual(usage.modelUsages.count, 2)
        XCTAssertTrue(usage.modelUsages.allSatisfy { $0.remainingPercent == 0.0 })
    }

    // MARK: - Clamping: utilization < 0

    func testNegativeUtilization_clampedTo100Remaining() {
        let tier = makeTier(utilization: -30.0)
        let response = UsageResponse(
            fiveHour: tier,
            sevenDay: tier,
            sevenDayOpus: tier,
            sevenDaySonnet: tier,
            extraUsage: nil,
            limits: nil,
            spend: nil
        )
        let usage = UsageData(from: response)

        // max(0, min(100, 100 - (-30))) = min(100, 130) = 100
        XCTAssertEqual(usage.weeklyRemaining, 100.0)
        XCTAssertEqual(usage.sessionRemaining, 100.0)
        XCTAssertEqual(usage.modelUsages.count, 2)
        XCTAssertTrue(usage.modelUsages.allSatisfy { $0.remainingPercent == 100.0 })
    }

    // MARK: - Session gauge capped by a low weekly (session over-reports when weekly is nearly exhausted)

    /// Build a UsageData with session and weekly derived INDEPENDENTLY from the legacy tiers,
    /// so the gating rule can be exercised across the (session, weekly) plane.
    private func makeUsage(session: Double, weekly: Double) -> UsageData {
        UsageData(from: UsageResponse(
            fiveHour: makeTier(utilization: 100 - session),
            sevenDay: makeTier(utilization: 100 - weekly),
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            extraUsage: nil,
            limits: nil,
            spend: nil
        ))
    }

    func testGauge_weeklyBindsAndLow_capsSessionToWeekly() {
        // The reported bug: weekly nearly exhausted, session still high -> gauge must drop to weekly.
        let usage = makeUsage(session: 94, weekly: 2)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 2, accuracy: 0.01)
        // Raw session is untouched (the #31 forecast and the pace keep the true 5h value).
        XCTAssertEqual(usage.sessionRemaining, 94, accuracy: 0.01)
    }

    func testGauge_weeklyExhausted_gaugeReadsZero() {
        let usage = makeUsage(session: 80, weekly: 0)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 0, accuracy: 0.01)
        XCTAssertEqual(usage.sessionRemaining, 80, accuracy: 0.01)
    }

    func testGauge_healthyWeek_doesNotDownRateSession() {
        // Regression lock: weekly < session but NOT low (63% is healthy) must leave the gauge
        // on the true session value. This is the exact fixture case (94 / 63); an unconditional
        // min() would wrongly collapse the dial to 63% here.
        let usage = makeUsage(session: 94, weekly: 63)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 94, accuracy: 0.01)
    }

    func testGauge_sessionIsTighterLimit_showsSessionNotWeekly() {
        // Weekly is low (15) but the session is even lower (8): the session is the real binding
        // limit, so the gauge shows the session and does NOT claim it is "weekly limited".
        let usage = makeUsage(session: 8, weekly: 15)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, 8, accuracy: 0.01)
    }

    func testGauge_floorBoundary_isExclusiveAtTwenty() {
        // At exactly the floor (weekly == 20) the gate is off; just below it turns on.
        XCTAssertFalse(makeUsage(session: 90, weekly: 20).isSessionWeeklyLimited)
        XCTAssertTrue(makeUsage(session: 90, weekly: 19.99).isSessionWeeklyLimited)
    }

    func testGauge_realFixture_notGated_leavesSessionRaw() throws {
        // usage_limits_spend: session 94, weekly 63 -> healthy, gauge unchanged at 94.
        let usage = UsageData(from: try decodeFixture("usage_limits_spend"))
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        XCTAssertEqual(usage.sessionDisplayRemaining, usage.sessionRemaining, accuracy: 0.01)
        XCTAssertEqual(usage.sessionDisplayRemaining, 94, accuracy: 0.01)
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

    /// Decode a UsageTier with a raw `resets_at` JSON value (number, string, or null)
    /// through the production decoder config, to lock the tolerant date parsing (#23).
    private func decodeTier(resetsAtRawJSON: String) -> UsageTier {
        let json = "{\"utilization\": 35, \"resets_at\": \(resetsAtRawJSON)}"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(UsageTier.self, from: Data(json.utf8))
    }

    // MARK: - resets_at tolerant decoding (issue #23: blank Session/Weekly resets)

    func testResetsAt_epochSeconds_decodes() {
        // The live API returns resets_at as a UNIX epoch for some accounts; .iso8601
        // can never parse a JSON number, so the old try? nil-ed it and the card went blank.
        let tier = decodeTier(resetsAtRawJSON: "1775714400")
        XCTAssertEqual(tier.resetsAt?.timeIntervalSince1970 ?? 0, 1775714400, accuracy: 0.5)
    }

    func testResetsAt_epochMilliseconds_decodes() {
        let tier = decodeTier(resetsAtRawJSON: "1775714400000")
        XCTAssertEqual(tier.resetsAt?.timeIntervalSince1970 ?? 0, 1775714400, accuracy: 0.5)
    }

    func testResetsAt_epochString_decodes() {
        let tier = decodeTier(resetsAtRawJSON: "\"1775714400\"")
        XCTAssertEqual(tier.resetsAt?.timeIntervalSince1970 ?? 0, 1775714400, accuracy: 0.5)
    }

    func testResetsAt_iso8601Fractional_decodes() {
        let tier = decodeTier(resetsAtRawJSON: "\"2026-04-10T14:00:00.000Z\"")
        XCTAssertNotNil(tier.resetsAt)
    }

    func testResetsAt_iso8601BareZ_stillDecodes() {
        // Regression guard: the format that already worked must keep working.
        let tier = decodeTier(resetsAtRawJSON: "\"2026-04-10T14:00:00Z\"")
        XCTAssertNotNil(tier.resetsAt)
    }

    func testResetsAt_presentButUnparseable_isNil() {
        let tier = decodeTier(resetsAtRawJSON: "\"not-a-date\"")
        XCTAssertNil(tier.resetsAt)
        XCTAssertEqual(tier.utilization ?? -1, 35, accuracy: 0.01)
    }

    func testResetsAt_null_decodesNilButKeepsUtilization() {
        let tier = decodeTier(resetsAtRawJSON: "null")
        XCTAssertNil(tier.resetsAt)
        XCTAssertEqual(tier.utilization ?? -1, 35, accuracy: 0.01)
    }

    func testResetsAt_absent_decodesNilButKeepsUtilization() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let tier = try! decoder.decode(UsageTier.self, from: Data("{\"utilization\": 35}".utf8))
        XCTAssertNil(tier.resetsAt)
        XCTAssertEqual(tier.utilization ?? -1, 35, accuracy: 0.01)
    }

    func testResetsAt_nonFiniteAndHuge_isNilNoCrash() {
        // Regression guard: Double("inf")/"1e400" and a huge finite number used to flow into
        // Date(timeIntervalSince1970:) and trap Int(remaining) in formatCountdown (#23 follow-up).
        for raw in ["\"inf\"", "\"-inf\"", "\"nan\"", "\"1e400\"", "1e308", "9.9e21"] {
            XCTAssertNil(decodeTier(resetsAtRawJSON: raw).resetsAt,
                         "resets_at \(raw) must decode to nil, never a trapping Date")
        }
    }

    func testResetsAt_absurdEpoch_outOfRangeIsNil() {
        // Values mapping outside ~2001-2100 are not real reset times.
        XCTAssertNil(decodeTier(resetsAtRawJSON: "99999999999").resetsAt)  // ~year 5138 as seconds
        XCTAssertNil(decodeTier(resetsAtRawJSON: "0").resetsAt)            // 1970
        XCTAssertNil(decodeTier(resetsAtRawJSON: "-1775714400").resetsAt)  // pre-1970
    }

    func testResetsAt_wrongJSONType_isNilKeepsUtilization() {
        for raw in ["true", "[]", "{}"] {
            let tier = decodeTier(resetsAtRawJSON: raw)
            XCTAssertNil(tier.resetsAt, "resets_at \(raw) must be nil")
            XCTAssertEqual(tier.utilization ?? -1, 35, accuracy: 0.01, "utilization must still decode for \(raw)")
        }
    }

    func testResetsAt_emptyString_isNil() {
        XCTAssertNil(decodeTier(resetsAtRawJSON: "\"\"").resetsAt)
    }

    func testResetsAt_iso8601FractionalAndBareZ_sameExactInstant() {
        // Strong assertion: both ISO forms resolve to the exact same instant (no silent
        // formatter fallback to a wrong epoch).
        let reference = ISO8601DateFormatter().date(from: "2026-04-10T14:00:00Z")!
        let frac = decodeTier(resetsAtRawJSON: "\"2026-04-10T14:00:00.000Z\"").resetsAt
        let bare = decodeTier(resetsAtRawJSON: "\"2026-04-10T14:00:00Z\"").resetsAt
        XCTAssertEqual(frac?.timeIntervalSince1970 ?? -1, reference.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(bare?.timeIntervalSince1970 ?? -2, reference.timeIntervalSince1970, accuracy: 0.001)
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

    // MARK: - Prepaid credits integration

    @MainActor
    func testPoll200WithCredits401_creditsBalanceIsNil() async {
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
        XCTAssertNil(service.latestUsage?.usageCredits?.balance,
                     "Credits balance should be nil when credits endpoint returns 401")
        XCTAssertEqual(service.consecutiveFailures, 0,
                       "Credits 401 should not affect consecutiveFailures")
    }

    @MainActor
    func testPoll200WithPrepaidCredits_decodesBalance() async {
        mockSession.responseData = fixtureData("usage_full")
        mockSession.responseStatusCode = 200
        mockSession.urlOverrides["prepaid/credits"] = (
            data: """
            {"amount": 20000, "currency": "AUD"}
            """.data(using: .utf8)!,
            statusCode: 200
        )

        let service = UsageService(
            storage: storage,
            accountStore: accountStore,
            session: mockSession
        )

        await service.pollUsage()

        // Currency + amount flow through the poll into the unified credits balance (KTD4/KTD6).
        XCTAssertEqual(service.latestUsage?.usageCredits?.balance?.currency, "AUD")
        XCTAssertEqual(service.latestUsage?.usageCredits?.balance?.major ?? .nan, 200.0, accuracy: 0.01)  // 20000 cents -> 200
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
        XCTAssertNil(service.latestUsage?.usageCredits?.balance,
                     "Credits balance should be nil when credits response is malformed")
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

// MARK: - limits[] / spend decode (U1)

/// Locks the newer `/usage` `limits[]`/`spend` decode and the expanded `/prepaid/credits`
/// decode, plus the shared tolerant `resets_at` parser reaching `UsageLimit` (KTD1/KTD2).
final class UsageLimitsSpendDecodeTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func fixtureURL(named name: String) -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
    }

    private func decodeUsage(_ name: String) throws -> UsageResponse {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")
            ?? fixtureURL(named: name)
        return try decoder().decode(UsageResponse.self, from: Data(contentsOf: url))
    }

    private func decodePrepaid(_ name: String) throws -> PrepaidCreditsResponse {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")
            ?? fixtureURL(named: name)
        return try decoder().decode(PrepaidCreditsResponse.self, from: Data(contentsOf: url))
    }

    /// Decode a single `UsageLimit` with a raw `resets_at` JSON value through the production
    /// decoder config, mirroring `decodeTier` so the shared `ResetDate` parser is locked for
    /// `UsageLimit` too.
    private func decodeLimit(resetsAtRawJSON: String) -> UsageLimit {
        let json = "{\"kind\": \"session\", \"resets_at\": \(resetsAtRawJSON)}"
        return try! decoder().decode(UsageLimit.self, from: Data(json.utf8))
    }

    // MARK: - Structure

    func testLimitsSpend_decodesStructure() throws {
        let r = try decodeUsage("usage_limits_spend")

        let limits = try XCTUnwrap(r.limits)
        XCTAssertEqual(limits.count, 3)
        XCTAssertEqual(limits.map(\.kind), ["session", "weekly_all", "weekly_scoped"])

        let scoped = try XCTUnwrap(limits.first { $0.kind == "weekly_scoped" })
        XCTAssertEqual(scoped.scope?.model?.displayName, "Sonnet")
        XCTAssertEqual(scoped.percent ?? -1, 3, accuracy: 0.01)

        let spend = try XCTUnwrap(r.spend)
        XCTAssertEqual(spend.enabled, false)
        XCTAssertEqual(spend.disabledReason, "org_level_disabled_until")
        XCTAssertEqual(spend.percent ?? -1, 0, accuracy: 0.01)
        XCTAssertNil(spend.limit)
        XCTAssertEqual(spend.used?.amountMinor, 0)
        XCTAssertEqual(spend.used?.currency, "USD")
        XCTAssertEqual(spend.used?.exponent, 2)
    }

    func testLimitsSpend_legacyFieldsStillDecode() throws {
        // KTD1: the newer shape must not break the existing per-field decode.
        let r = try decodeUsage("usage_limits_spend")
        XCTAssertEqual(r.fiveHour?.utilization ?? -1, 6, accuracy: 0.01)
        XCTAssertEqual(r.sevenDay?.utilization ?? -1, 37, accuracy: 0.01)
        XCTAssertEqual(r.sevenDaySonnet?.utilization ?? -1, 3, accuracy: 0.01)
        XCTAssertNil(r.sevenDayOpus)
        XCTAssertNotNil(r.fiveHour?.resetsAt)
    }

    func testLegacyFixture_hasNoLimitsOrSpend() throws {
        // No regression: a legacy body decodes with limits/spend absent.
        let r = try decodeUsage("usage_full")
        XCTAssertNil(r.limits)
        XCTAssertNil(r.spend)
    }

    func testUsageBodyLackingLimitsSpend_doesNotThrow() throws {
        let r = try decoder().decode(UsageResponse.self, from: Data("{}".utf8))
        XCTAssertNil(r.limits)
        XCTAssertNil(r.spend)
    }

    // MARK: - Shared resets_at parser reaches UsageLimit (KTD2, #23 matrix)

    func testLimitResetsAt_epochSeconds_decodes() {
        XCTAssertEqual(decodeLimit(resetsAtRawJSON: "1775714400").resetsAt?.timeIntervalSince1970 ?? 0,
                       1775714400, accuracy: 0.5)
    }

    func testLimitResetsAt_epochMilliseconds_decodes() {
        XCTAssertEqual(decodeLimit(resetsAtRawJSON: "1775714400000").resetsAt?.timeIntervalSince1970 ?? 0,
                       1775714400, accuracy: 0.5)
    }

    func testLimitResetsAt_epochString_decodes() {
        XCTAssertEqual(decodeLimit(resetsAtRawJSON: "\"1775714400\"").resetsAt?.timeIntervalSince1970 ?? 0,
                       1775714400, accuracy: 0.5)
    }

    func testLimitResetsAt_iso8601Fractional_decodes() {
        XCTAssertNotNil(decodeLimit(resetsAtRawJSON: "\"2026-04-10T14:00:00.000Z\"").resetsAt)
    }

    func testLimitResetsAt_iso8601BareZ_decodes() {
        XCTAssertNotNil(decodeLimit(resetsAtRawJSON: "\"2026-04-10T14:00:00Z\"").resetsAt)
    }

    func testLimitResetsAt_null_isNil() {
        XCTAssertNil(decodeLimit(resetsAtRawJSON: "null").resetsAt)
    }

    func testLimitResetsAt_nonFiniteAndOutOfRange_isNil() {
        for raw in ["\"inf\"", "\"nan\"", "\"1e400\"", "1e308", "99999999999", "0", "-1775714400"] {
            XCTAssertNil(decodeLimit(resetsAtRawJSON: raw).resetsAt,
                         "limit resets_at \(raw) must decode to nil, never a trapping Date")
        }
    }

    // MARK: - Prepaid credits (expanded shape)

    func testPrepaidCreditsAUD_decodes() throws {
        let p = try decodePrepaid("prepaid_credits_aud")
        XCTAssertEqual(p.amount, 7152)
        XCTAssertEqual(p.currency, "AUD")
    }

    // MARK: - Derivation: limits[]/spend -> UsageData (U2)

    func testLimitsPrimary_derivesSessionWeeklyModels() throws {
        // Covers R0.4: limits[] is the primary source when present.
        let usage = UsageData(from: try decodeUsage("usage_limits_spend"))
        XCTAssertEqual(usage.sessionRemaining, 94, accuracy: 0.01)  // 100 - 6 (session limit)
        XCTAssertEqual(usage.weeklyRemaining, 63, accuracy: 0.01)   // 100 - 37 (weekly_all)
        XCTAssertEqual(usage.modelUsages.count, 1)
        XCTAssertEqual(usage.modelUsages.first?.displayName, "Sonnet")
        XCTAssertEqual(usage.modelUsages.first?.remainingPercent ?? -1, 97, accuracy: 0.01)  // 100 - 3
        XCTAssertNotNil(usage.modelUsages.first?.resetDate)  // weekly_scoped resets_at wired through
        XCTAssertFalse(usage.modelUsages.contains { $0.displayName == "Opus" })
    }

    func testLegacyPerModel_presentTierWithNullUtilization_dropsBar() throws {
        // A present seven_day_opus tier whose utilization is null must hide the bar, not
        // render a fabricated 100% (KTD3) - the gate is on utilization, not just the tier.
        let json = """
        { "seven_day_opus": { "utilization": null },
          "seven_day_sonnet": { "utilization": 10.0 } }
        """
        let usage = UsageData(from: try decoder().decode(UsageResponse.self, from: Data(json.utf8)))
        XCTAssertEqual(usage.modelUsages.map(\.displayName), ["Sonnet"])
    }

    func testDisabledCredits_withPrepaidBalance() throws {
        // Reporter's live data: spend disabled, prepaid balance still shown (KTD5).
        let usage = UsageData(from: try decodeUsage("usage_limits_spend"),
                              prepaidCredits: try decodePrepaid("prepaid_credits_aud"))
        let credits = try XCTUnwrap(usage.usageCredits)
        guard case let .disabled(reason, resetDate) = credits.state else {
            return XCTFail("expected disabled state, got \(String(describing: credits.state))")
        }
        XCTAssertEqual(reason, "org_level_disabled_until")
        XCTAssertNil(resetDate)
        XCTAssertEqual(credits.balance?.major ?? -1, 71.52, accuracy: 0.001)  // 7152 cents -> A$71.52
        XCTAssertEqual(credits.balance?.currency, "AUD")
    }

    func testEnabledCredits_over100PercentUncapped() throws {
        // KTD7: spend.percent can exceed 100; the derived state keeps it uncapped.
        // KTD4: amount_minor / 10^exponent converts to major units exactly once.
        let json = """
        { "spend": { "used": { "amount_minor": 20513, "currency": "AUD", "exponent": 2 },
                     "limit": { "amount_minor": 20000, "currency": "AUD", "exponent": 2 },
                     "percent": 103, "severity": "normal", "enabled": true } }
        """
        let usage = UsageData(from: try decoder().decode(UsageResponse.self, from: Data(json.utf8)))
        let credits = try XCTUnwrap(usage.usageCredits)
        guard case let .enabled(spent, limit, percent, currency, _) = credits.state else {
            return XCTFail("expected enabled state, got \(String(describing: credits.state))")
        }
        XCTAssertEqual(spent, 205.13, accuracy: 0.001)   // 20513 minor / 10^2
        XCTAssertEqual(limit ?? -1, 200, accuracy: 0.001) // 20000 minor / 10^2
        XCTAssertEqual(percent, 103, accuracy: 0.01)      // uncapped
        XCTAssertEqual(currency, "AUD")
    }

    func testBalanceOnly_whenSpendAbsent() throws {
        // Legacy body (no spend) + prepaid balance -> credits carry only a balance.
        let usage = UsageData(from: try decodeUsage("usage_full"),
                              prepaidCredits: try decodePrepaid("prepaid_credits_aud"))
        let credits = try XCTUnwrap(usage.usageCredits)
        XCTAssertNil(credits.state)
        XCTAssertEqual(credits.balance?.major ?? -1, 71.52, accuracy: 0.001)
        XCTAssertEqual(credits.balance?.currency, "AUD")
    }
}
