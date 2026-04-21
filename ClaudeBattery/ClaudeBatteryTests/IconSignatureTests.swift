import XCTest
@testable import ClaudeBattery

final class RenderStateTests: XCTestCase {

    // MARK: - Authentication short-circuits everything

    func testUnauthenticated_ignoresUsageAndFailures() {
        let state = MenuBarController.renderState(
            isAuthenticated: false,
            usage: nil,
            consecutiveFailures: 99,
            isStale: true
        )
        XCTAssertEqual(state, .unauthenticated)

        let stateWithUsage = MenuBarController.renderState(
            isAuthenticated: false,
            usage: Self.makeUsage(weeklyUtilization: 50.0),
            consecutiveFailures: 0,
            isStale: false
        )
        XCTAssertEqual(stateWithUsage, .unauthenticated)
    }

    // MARK: - Usage presence beats failure counters

    func testAuthenticatedWithUsage_returnsBatteryRegardlessOfFailures() {
        let usage = Self.makeUsage(weeklyUtilization: 25.0)

        let zeroFailures = MenuBarController.renderState(
            isAuthenticated: true,
            usage: usage,
            consecutiveFailures: 0,
            isStale: false
        )
        XCTAssertEqual(zeroFailures, .battery(usage))

        let manyFailures = MenuBarController.renderState(
            isAuthenticated: true,
            usage: usage,
            consecutiveFailures: 50,
            isStale: true
        )
        XCTAssertEqual(manyFailures, .battery(usage))
    }

    // MARK: - No usage, no failures -> loading

    func testAuthenticatedNoUsage_noFailures_returnsLoading() {
        let state = MenuBarController.renderState(
            isAuthenticated: true,
            usage: nil,
            consecutiveFailures: 0,
            isStale: false
        )
        XCTAssertEqual(state, .statusLoading)
    }

    // MARK: - Stale branch boundaries

    func testStaleBranch_failuresBelowThreshold_returnsLoading() {
        let state = MenuBarController.renderState(
            isAuthenticated: true,
            usage: nil,
            consecutiveFailures: 2,
            isStale: true
        )
        XCTAssertEqual(state, .statusLoading)
    }

    func testStaleBranch_failuresMeetThresholdButNotStale_returnsLoading() {
        let state = MenuBarController.renderState(
            isAuthenticated: true,
            usage: nil,
            consecutiveFailures: 3,
            isStale: false
        )
        XCTAssertEqual(state, .statusLoading)
    }

    func testStaleBranch_failuresAtThresholdAndStale_returnsStale() {
        let state = MenuBarController.renderState(
            isAuthenticated: true,
            usage: nil,
            consecutiveFailures: 3,
            isStale: true
        )
        XCTAssertEqual(state, .statusStale)
    }

    func testStaleBranch_failuresJustBelowErrorAndStale_returnsStale() {
        let state = MenuBarController.renderState(
            isAuthenticated: true,
            usage: nil,
            consecutiveFailures: 9,
            isStale: true
        )
        XCTAssertEqual(state, .statusStale)
    }

    // MARK: - Error branch supersedes stale

    func testErrorBranch_atThreshold_returnsError() {
        let state = MenuBarController.renderState(
            isAuthenticated: true,
            usage: nil,
            consecutiveFailures: 10,
            isStale: false
        )
        XCTAssertEqual(state, .statusError)
    }

    func testErrorBranch_atThresholdAndStale_errorSupersedesStale() {
        let state = MenuBarController.renderState(
            isAuthenticated: true,
            usage: nil,
            consecutiveFailures: 10,
            isStale: true
        )
        XCTAssertEqual(state, .statusError)
    }

    // MARK: - Battery case carries UsageData identity

    func testBatteryState_distinctUsageValues_areUnequal() {
        let usageA = Self.makeUsage(weeklyUtilization: 25.0)
        let usageB = Self.makeUsage(weeklyUtilization: 75.0)

        let stateA = MenuBarController.renderState(
            isAuthenticated: true,
            usage: usageA,
            consecutiveFailures: 0,
            isStale: false
        )
        let stateB = MenuBarController.renderState(
            isAuthenticated: true,
            usage: usageB,
            consecutiveFailures: 0,
            isStale: false
        )
        XCTAssertNotEqual(stateA, stateB)
    }

    // MARK: - Helpers

    /// Build a UsageData by round-tripping through the JSON decoder path used in production.
    static func makeUsage(weeklyUtilization: Double) -> UsageData {
        let tier = Self.makeTier(utilization: weeklyUtilization)
        let response = UsageResponse(
            fiveHour: tier,
            sevenDay: tier,
            sevenDayOpus: tier,
            sevenDaySonnet: tier,
            extraUsage: nil
        )
        return UsageData(from: response)
    }

    private static func makeTier(utilization: Double) -> UsageTier {
        let json: [String: Any] = ["utilization": utilization]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(UsageTier.self, from: data)
    }
}

// MARK: - IconSignature composition

final class IconSignatureTests: XCTestCase {

    // MARK: - Happy path equality

    func testIdenticalInputs_areEqual() {
        let sig1 = makeSignature(
            style: .dualHorizontal,
            isMenuBarDark: true,
            isAuthenticated: true,
            usage: RenderStateTests.makeUsage(weeklyUtilization: 50.0),
            consecutiveFailures: 0,
            isStale: false
        )
        let sig2 = makeSignature(
            style: .dualHorizontal,
            isMenuBarDark: true,
            isAuthenticated: true,
            usage: RenderStateTests.makeUsage(weeklyUtilization: 50.0),
            consecutiveFailures: 0,
            isStale: false
        )
        XCTAssertEqual(sig1, sig2)
    }

    // MARK: - Each field independently differentiates

    func testStyleChange_producesUnequalSignatures() {
        let sig1 = makeSignature(style: .dualHorizontal)
        let sig2 = makeSignature(style: .minimal)
        XCTAssertNotEqual(sig1, sig2)
    }

    func testIsMenuBarDarkFlip_producesUnequalSignatures() {
        let sig1 = makeSignature(isMenuBarDark: true)
        let sig2 = makeSignature(isMenuBarDark: false)
        XCTAssertNotEqual(sig1, sig2)
    }

    func testIsAuthenticatedFlip_producesUnequalSignatures() {
        let sig1 = makeSignature(isAuthenticated: true)
        let sig2 = makeSignature(isAuthenticated: false)
        XCTAssertNotEqual(sig1, sig2)
    }

    // MARK: - Correctness gate: usage != nil bypasses failure bucket

    func testBatteryBypass_failureStateDoesNotAffectSignature() {
        let usage = RenderStateTests.makeUsage(weeklyUtilization: 30.0)

        let lowFailures = makeSignature(
            isAuthenticated: true,
            usage: usage,
            consecutiveFailures: 0,
            isStale: false
        )
        let highFailuresStale = makeSignature(
            isAuthenticated: true,
            usage: usage,
            consecutiveFailures: 50,
            isStale: true
        )

        // When usage is present, the battery renders regardless of consecutiveFailures or isStale.
        // The signature must treat these as identical to avoid spurious re-renders.
        XCTAssertEqual(lowFailures, highFailuresStale)
    }

    // MARK: - Usage value differences

    func testDistinctUsageValues_produceUnequalSignatures() {
        let usageA = RenderStateTests.makeUsage(weeklyUtilization: 20.0)
        let usageB = RenderStateTests.makeUsage(weeklyUtilization: 80.0)

        let sigA = makeSignature(isAuthenticated: true, usage: usageA)
        let sigB = makeSignature(isAuthenticated: true, usage: usageB)
        XCTAssertNotEqual(sigA, sigB)
    }

    func testUsageNilVsPresent_produceUnequalSignatures() {
        let sigNil = makeSignature(isAuthenticated: true, usage: nil)
        let sigPresent = makeSignature(
            isAuthenticated: true,
            usage: RenderStateTests.makeUsage(weeklyUtilization: 50.0)
        )
        XCTAssertNotEqual(sigNil, sigPresent)
    }

    // MARK: - Failure bucket boundaries (usage=nil path)

    func testFailureBuckets_transitionsProduceUnequalSignatures() {
        let loading = makeSignature(
            isAuthenticated: true,
            usage: nil,
            consecutiveFailures: 0,
            isStale: false
        )
        let stale = makeSignature(
            isAuthenticated: true,
            usage: nil,
            consecutiveFailures: 3,
            isStale: true
        )
        let error = makeSignature(
            isAuthenticated: true,
            usage: nil,
            consecutiveFailures: 10,
            isStale: false
        )
        XCTAssertNotEqual(loading, stale)
        XCTAssertNotEqual(stale, error)
        XCTAssertNotEqual(loading, error)
    }

    // MARK: - Helpers

    private func makeSignature(
        style: IconStyle = .dualHorizontal,
        isMenuBarDark: Bool = true,
        isAuthenticated: Bool = true,
        usage: UsageData? = nil,
        consecutiveFailures: Int = 0,
        isStale: Bool = false
    ) -> IconSignature {
        let render = MenuBarController.renderState(
            isAuthenticated: isAuthenticated,
            usage: usage,
            consecutiveFailures: consecutiveFailures,
            isStale: isStale
        )
        return IconSignature(style: style, isMenuBarDark: isMenuBarDark, render: render)
    }
}
