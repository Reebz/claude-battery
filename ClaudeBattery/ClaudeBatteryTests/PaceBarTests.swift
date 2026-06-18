import XCTest
import SwiftUI
@testable import ClaudeBattery

/// Locks the pure pace math and color mapping (U2). The bar itself is SwiftUI layout (U3).
final class PaceBarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func resetsIn(_ interval: TimeInterval) -> Date {
        now.addingTimeInterval(interval)
    }

    // MARK: - timeRemainingPercent

    func testWeekly_fiveDaysOfSeven_aboutSeventyOne() {
        let percent = UsagePopoverView.timeRemainingPercent(
            resetsAt: resetsIn(5 * 24 * 3600),
            window: UsagePopoverView.weeklyWindow,
            now: now
        )
        XCTAssertEqual(percent ?? -1, 71.43, accuracy: 0.1)  // 5/7 * 100
    }

    func testSession_oneHourOfFive_twenty() {
        let percent = UsagePopoverView.timeRemainingPercent(
            resetsAt: resetsIn(3600),
            window: UsagePopoverView.sessionWindow,
            now: now
        )
        XCTAssertEqual(percent ?? -1, 20, accuracy: 0.001)  // 1/5 * 100
    }

    func testPast_returnsNil_barOmitted() {
        // A past reset has no positive guarded delta, so the percent is nil (bar omitted, KTD4).
        let percent = UsagePopoverView.timeRemainingPercent(
            resetsAt: resetsIn(-3600),
            window: UsagePopoverView.sessionWindow,
            now: now
        )
        XCTAssertNil(percent)
    }

    func testBeyondWindow_clampsToHundred() {
        // Clock skew: reset further out than a full window clamps to 100, never overflows.
        let percent = UsagePopoverView.timeRemainingPercent(
            resetsAt: resetsIn(10 * 24 * 3600),
            window: UsagePopoverView.weeklyWindow,
            now: now
        )
        XCTAssertEqual(percent ?? -1, 100, accuracy: 0.001)
    }

    func testNilResetsAt_isNil() {
        XCTAssertNil(UsagePopoverView.timeRemainingPercent(
            resetsAt: nil,
            window: UsagePopoverView.sessionWindow,
            now: now
        ))
    }

    func testWindowConstants() {
        XCTAssertEqual(UsagePopoverView.sessionWindow, 5 * 3600)
        XCTAssertEqual(UsagePopoverView.weeklyWindow, 7 * 24 * 3600)
    }

    // MARK: - paceColor (deficit = timeRemaining - usageRemaining)

    func testDeficit51_burningTooFast_red() {
        // weekly: 71% time left, 20% usage left -> deficit 51 -> red.
        XCTAssertEqual(UsagePopoverView.paceColor(timeRemaining: 71, usageRemaining: 20), .red)
    }

    func testDeficit25_moderatelyAhead_orange() {
        XCTAssertEqual(UsagePopoverView.paceColor(timeRemaining: 50, usageRemaining: 25), .orange)
    }

    func testDeficit5_onPace_green() {
        XCTAssertEqual(UsagePopoverView.paceColor(timeRemaining: 50, usageRemaining: 45), .green)
    }

    func testNegativeDeficit_underPace_green() {
        // Usage remaining exceeds time remaining (burning slower than the clock) -> safe.
        XCTAssertEqual(UsagePopoverView.paceColor(timeRemaining: 20, usageRemaining: 80), .green)
    }

    func testBoundary_deficit10_green() {
        XCTAssertEqual(UsagePopoverView.paceColor(timeRemaining: 50, usageRemaining: 40), .green)
    }

    func testBoundary_deficit30_orange() {
        XCTAssertEqual(UsagePopoverView.paceColor(timeRemaining: 60, usageRemaining: 30), .orange)
    }
}
