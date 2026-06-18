import XCTest
import SwiftUI
@testable import ClaudeBattery

/// Locks the pure time-remaining math (U2). The bar itself is SwiftUI layout (U3) and reuses
/// the tested batteryColor scale for its fill.
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
}
