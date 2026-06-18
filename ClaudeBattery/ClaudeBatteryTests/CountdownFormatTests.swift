import XCTest
@testable import ClaudeBattery

/// Locks the shared guarded countdown core and the compact 3-char menu-bar formatter (U1, KTD1).
/// `now` is pinned so the deltas are deterministic.
final class CountdownFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func future(_ interval: TimeInterval) -> Date {
        now.addingTimeInterval(interval)
    }

    // MARK: - compactCountdown

    func testCompact_fourHoursTwentyMinutes_hoursPlus() {
        XCTAssertEqual(CountdownFormat.compactCountdown(until: future(4 * 3600 + 20 * 60), now: now), "4h+")
    }

    func testCompact_oneHourExactly_hoursPlus() {
        XCTAssertEqual(CountdownFormat.compactCountdown(until: future(3600), now: now), "1h+")
    }

    func testCompact_tenHours_saturatesToNineHoursPlus() {
        // >= 10h would render "10h+" (4 chars), violating the <= 3-char invariant under clock
        // skew / stale reset dates, so it saturates to the truthful "at least 9h" form.
        XCTAssertEqual(CountdownFormat.compactCountdown(until: future(10 * 3600 + 5), now: now), "9h+")
    }

    func testCompact_fiftyNineMinutesThirtySeconds_minutes() {
        XCTAssertEqual(CountdownFormat.compactCountdown(until: future(59 * 60 + 30), now: now), "59m")
    }

    func testCompact_thirtyTwoMinutes_minutes() {
        XCTAssertEqual(CountdownFormat.compactCountdown(until: future(32 * 60), now: now), "32m")
    }

    func testCompact_fortySeconds_lessThanAMinute() {
        XCTAssertEqual(CountdownFormat.compactCountdown(until: future(40), now: now), "<1m")
    }

    func testCompact_zero_isNil() {
        XCTAssertNil(CountdownFormat.compactCountdown(until: now, now: now))
    }

    func testCompact_past_isNil() {
        XCTAssertNil(CountdownFormat.compactCountdown(until: future(-120), now: now))
    }

    func testCompact_everyNonNilResultIsAtMostThreeChars() {
        // Every swept interval is positive, so compactCountdown never returns nil here; the
        // >= 10h and >= 100h entries exercise the saturation that keeps the invariant universal.
        let intervals: [TimeInterval] = [
            5, 40, 59, 60, 90, 30 * 60, 59 * 60 + 59,
            3600, 3600 + 59, 2 * 3600, 4 * 3600 + 20 * 60, 5 * 3600,
            10 * 3600 + 5, 100 * 3600
        ]
        for interval in intervals {
            let result = CountdownFormat.compactCountdown(until: future(interval), now: now)
            XCTAssertNotNil(result, "compact unexpectedly nil for \(interval)s")
            XCTAssertLessThanOrEqual(result?.count ?? .max, 3, "compact `\(result ?? "nil")` for \(interval)s exceeds 3 chars")
        }
    }

    // MARK: - remainingSeconds guard

    func testRemainingSeconds_past_isNil() {
        XCTAssertNil(CountdownFormat.remainingSeconds(until: future(-1), now: now))
    }

    func testRemainingSeconds_zero_isNil() {
        XCTAssertNil(CountdownFormat.remainingSeconds(until: now, now: now))
    }

    func testRemainingSeconds_nonFinite_isNilAndDoesNotTrap() {
        // A Date built off a non-finite interval would trap an Int() conversion; the guard
        // must reject it (isFinite) and return nil instead of reaching any Int(...).
        let nonFinite = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertNil(CountdownFormat.remainingSeconds(until: nonFinite, now: now))
        XCTAssertNil(CountdownFormat.compactCountdown(until: nonFinite, now: now))
    }

    func testRemainingSeconds_validFuture_returnsDelta() {
        let delta = CountdownFormat.remainingSeconds(until: future(125), now: now)
        XCTAssertEqual(delta ?? -1, 125, accuracy: 0.001)
    }
}
