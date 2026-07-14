import XCTest
import AppKit
@testable import ClaudeBattery

final class RenderStateTests: XCTestCase {

    // MARK: - Authentication short-circuits everything

    func testUnauthenticated_ignoresUsageAndFailures() {
        let state = MenuBarController.renderState(
            isAuthenticated: false,
            authFailed: false,
            usage: nil,
            consecutiveFailures: 99,
            isStale: true
        )
        XCTAssertEqual(state, .unauthenticated)

        let stateWithUsage = MenuBarController.renderState(
            isAuthenticated: false,
            authFailed: false,
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
            authFailed: false,
            usage: usage,
            consecutiveFailures: 0,
            isStale: false
        )
        XCTAssertEqual(zeroFailures, .battery(usage))

        let manyFailures = MenuBarController.renderState(
            isAuthenticated: true,
            authFailed: false,
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
            authFailed: false,
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
            authFailed: false,
            usage: nil,
            consecutiveFailures: 2,
            isStale: true
        )
        XCTAssertEqual(state, .statusLoading)
    }

    func testStaleBranch_failuresMeetThresholdButNotStale_returnsLoading() {
        let state = MenuBarController.renderState(
            isAuthenticated: true,
            authFailed: false,
            usage: nil,
            consecutiveFailures: 3,
            isStale: false
        )
        XCTAssertEqual(state, .statusLoading)
    }

    func testStaleBranch_failuresAtThresholdAndStale_returnsStale() {
        let state = MenuBarController.renderState(
            isAuthenticated: true,
            authFailed: false,
            usage: nil,
            consecutiveFailures: 3,
            isStale: true
        )
        XCTAssertEqual(state, .statusStale)
    }

    func testStaleBranch_failuresJustBelowErrorAndStale_returnsStale() {
        let state = MenuBarController.renderState(
            isAuthenticated: true,
            authFailed: false,
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
            authFailed: false,
            usage: nil,
            consecutiveFailures: 10,
            isStale: false
        )
        XCTAssertEqual(state, .statusError)
    }

    func testErrorBranch_atThresholdAndStale_errorSupersedesStale() {
        let state = MenuBarController.renderState(
            isAuthenticated: true,
            authFailed: false,
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
            authFailed: false,
            usage: usageA,
            consecutiveFailures: 0,
            isStale: false
        )
        let stateB = MenuBarController.renderState(
            isAuthenticated: true,
            authFailed: false,
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
            extraUsage: nil,
            limits: nil,
            spend: nil
        )
        return UsageData(from: response)
    }

    /// UsageData with session (fiveHour) and weekly (sevenDay) utilization set independently.
    static func makeUsage(sessionUtilization: Double, weeklyUtilization: Double) -> UsageData {
        UsageData(from: UsageResponse(
            fiveHour: Self.makeTier(utilization: sessionUtilization),
            sevenDay: Self.makeTier(utilization: weeklyUtilization),
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            extraUsage: nil,
            limits: nil,
            spend: nil
        ))
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

    // The popover Session gauge caps its value to a low weekly (sessionGaugeRemaining), but the
    // menu bar must key on RAW sessionRemaining. Two snapshots with the same low weekly but
    // different session collapse to the same capped gauge value, yet must produce DIFFERENT
    // signatures - proving the weekly cap never folded into UsageData.sessionRemaining and broke
    // the menu-bar renderers (which show session and weekly side by side).
    func testMenuBarKeysOnRawSession_notWeeklyCappedGaugeValue() {
        let high = RenderStateTests.makeUsage(sessionUtilization: 20, weeklyUtilization: 95) // session 80, weekly 5
        let low = RenderStateTests.makeUsage(sessionUtilization: 92, weeklyUtilization: 95)  // session 8, weekly 5

        XCTAssertTrue(high.isSessionWeeklyLimited)
        XCTAssertTrue(low.isSessionWeeklyLimited)
        XCTAssertEqual(high.sessionGaugeRemaining, low.sessionGaugeRemaining, accuracy: 0.01) // both -> 5
        XCTAssertNotEqual(high.sessionRemaining, low.sessionRemaining, accuracy: 0.01)        // 80 vs 8

        let sigHigh = makeSignature(isAuthenticated: true, usage: high)
        let sigLow = makeSignature(isAuthenticated: true, usage: low)
        XCTAssertNotEqual(sigHigh, sigLow)
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

    // MARK: - Countdown drives the per-minute re-render

    // The countdown string is folded into the signature so a per-minute tick ("32m" -> "31m")
    // re-renders the composed icon exactly once. Two signatures identical except for the
    // countdown MUST be unequal, otherwise the new countdown would never paint.
    func testCountdownChange_producesUnequalSignatures() {
        let usage = RenderStateTests.makeUsage(weeklyUtilization: 50.0)
        let sig1 = makeSignature(isAuthenticated: true, usage: usage, countdown: "32m")
        let sig2 = makeSignature(isAuthenticated: true, usage: usage, countdown: "31m")
        XCTAssertNotEqual(sig1, sig2)
    }

    func testCountdownEmptyVsPresent_producesUnequalSignatures() {
        let usage = RenderStateTests.makeUsage(weeklyUtilization: 50.0)
        let off = makeSignature(isAuthenticated: true, usage: usage, countdown: "")
        let on = makeSignature(isAuthenticated: true, usage: usage, countdown: "4h+")
        XCTAssertNotEqual(off, on)
    }

    // MARK: - Helpers

    private func makeSignature(
        style: IconStyle = .dualHorizontal,
        isMenuBarDark: Bool = true,
        isAuthenticated: Bool = true,
        usage: UsageData? = nil,
        consecutiveFailures: Int = 0,
        isStale: Bool = false,
        countdown: String = ""
    ) -> IconSignature {
        let render = MenuBarController.renderState(
            isAuthenticated: isAuthenticated,
            authFailed: false,
            usage: usage,
            consecutiveFailures: consecutiveFailures,
            isStale: isStale
        )
        return IconSignature(style: style, isMenuBarDark: isMenuBarDark, render: render, countdown: countdown)
    }
}

// MARK: - Appearance KVO Dedup

final class AppearanceChangeDedupTests: XCTestCase {

    // MARK: - Nil handling

    func testNilNew_returnsFalse() {
        let dark = NSAppearance(named: .darkAqua)!
        XCTAssertFalse(MenuBarController.shouldReactToAppearanceChange(old: dark, new: nil))
    }

    func testNilOld_nonNilNew_returnsTrue() {
        let dark = NSAppearance(named: .darkAqua)!
        XCTAssertTrue(MenuBarController.shouldReactToAppearanceChange(old: nil, new: dark))
    }

    func testBothNil_returnsFalse() {
        XCTAssertFalse(MenuBarController.shouldReactToAppearanceChange(old: nil, new: nil))
    }

    // MARK: - Same brightness bucket should suppress

    func testSameDarkAqua_returnsFalse() {
        let a = NSAppearance(named: .darkAqua)!
        let b = NSAppearance(named: .darkAqua)!
        XCTAssertFalse(MenuBarController.shouldReactToAppearanceChange(old: a, new: b))
    }

    func testSameAqua_returnsFalse() {
        let a = NSAppearance(named: .aqua)!
        let b = NSAppearance(named: .aqua)!
        XCTAssertFalse(MenuBarController.shouldReactToAppearanceChange(old: a, new: b))
    }

    // MARK: - Correctness gate: HighContrast sub-variants collapse to the same bucket

    // This is the fix for issue #11 — .name comparison would treat these as different.
    func testAccessibilityHighContrastDarkAqua_collapsesToDark() {
        let dark = NSAppearance(named: .darkAqua)!
        let highContrastDark = NSAppearance(named: .accessibilityHighContrastDarkAqua)!
        XCTAssertFalse(MenuBarController.shouldReactToAppearanceChange(old: dark, new: highContrastDark))
        XCTAssertFalse(MenuBarController.shouldReactToAppearanceChange(old: highContrastDark, new: dark))
    }

    func testAccessibilityHighContrastAqua_collapsesToLight() {
        let light = NSAppearance(named: .aqua)!
        let highContrastLight = NSAppearance(named: .accessibilityHighContrastAqua)!
        XCTAssertFalse(MenuBarController.shouldReactToAppearanceChange(old: light, new: highContrastLight))
        XCTAssertFalse(MenuBarController.shouldReactToAppearanceChange(old: highContrastLight, new: light))
    }

    // MARK: - Real transitions should pass

    func testDarkToLight_returnsTrue() {
        let dark = NSAppearance(named: .darkAqua)!
        let light = NSAppearance(named: .aqua)!
        XCTAssertTrue(MenuBarController.shouldReactToAppearanceChange(old: dark, new: light))
    }

    func testLightToDark_returnsTrue() {
        let dark = NSAppearance(named: .darkAqua)!
        let light = NSAppearance(named: .aqua)!
        XCTAssertTrue(MenuBarController.shouldReactToAppearanceChange(old: light, new: dark))
    }

    func testHighContrastDarkToHighContrastLight_returnsTrue() {
        let hcDark = NSAppearance(named: .accessibilityHighContrastDarkAqua)!
        let hcLight = NSAppearance(named: .accessibilityHighContrastAqua)!
        XCTAssertTrue(MenuBarController.shouldReactToAppearanceChange(old: hcDark, new: hcLight))
    }
}
