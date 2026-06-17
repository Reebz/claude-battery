import XCTest
@testable import ClaudeBattery

/// Locks the pure text mapping for the combined Credits row (U5). The single-line layout
/// (status truncates, balance pinned) is SwiftUI; only the composed strings are unit-tested.
final class UsageCreditsRowTests: XCTestCase {
    func testDisabledReason_orgLevel_mapsToPausedMonthlyLimit() {
        XCTAssertEqual(
            UsagePopoverView.usageCreditsDisabledText(reason: "org_level_disabled_until", resetDate: nil),
            "Paused - monthly limit reached"
        )
    }

    func testEnabledStatus_composesSpentAndPercentUsed() {
        let status = UsagePopoverView.usageCreditsEnabledStatus(spentFormatted: "$12.00", percent: 60)
        XCTAssertEqual(status, "$12.00 spent · 60% used")
    }

    func testEnabledStatus_roundsPercent() {
        XCTAssertEqual(
            UsagePopoverView.usageCreditsEnabledStatus(spentFormatted: "$5.00", percent: 49.6),
            "$5.00 spent · 50% used"
        )
    }

    func testEnabledStatus_uncappedPercentOverHundred_preserved() {
        // KTD7: spend percent is uncapped; the status string carries it as-is (rounded).
        XCTAssertEqual(
            UsagePopoverView.usageCreditsEnabledStatus(spentFormatted: "A$205.13", percent: 103),
            "A$205.13 spent · 103% used"
        )
    }
}
