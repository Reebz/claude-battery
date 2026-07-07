import XCTest
@testable import ClaudeBattery

/// Locks the pure run-out forecast math (#31, U2), mirroring `PaceBarTests`: a fixed `now`, a
/// `resetsIn` helper, and pure static calls. `.runsOut` dates are asserted by their offset from
/// `now` with accuracy so the check stays robust to floating point; the other states compare by case.
final class RunOutForecastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let s = UsagePopoverView.sessionWindow   // 18000
    private let w = UsagePopoverView.weeklyWindow     // 604800

    private func resetsIn(_ interval: TimeInterval) -> Date { now.addingTimeInterval(interval) }

    /// `r == nil` models a nil `resetsAt`; otherwise the reset is `r` seconds from `now`.
    private func forecast(_ remaining: Double, _ r: TimeInterval?, _ window: TimeInterval) -> UsagePopoverView.RunOutForecast {
        UsagePopoverView.projectedRunOut(
            remainingPercent: remaining,
            resetsAt: r.map(resetsIn),
            window: window,
            now: now
        )
    }

    /// Assert a `.runsOut` case whose date is `offset` seconds from `now`, tolerant of FP.
    private func assertRunsOut(_ result: UsagePopoverView.RunOutForecast, offset: TimeInterval,
                               file: StaticString = #file, line: UInt = #line) {
        guard case let .runsOut(date) = result else {
            return XCTFail("expected .runsOut, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(date.timeIntervalSince(now), offset, accuracy: 1, file: file, line: line)
    }

    // MARK: - projectedRunOut

    func test01_burningFast_session_runsOut()      { assertRunsOut(forecast(20, 7200, s), offset: 2700) }
    func test02_slowerThanClock_willNotRunOut()    { XCTAssertEqual(forecast(70, 7200, s), .willNotRunOut) }
    func test03_inBand_onPace()                    { XCTAssertEqual(forecast(40, 7200, s), .onPace) }
    func test04_nearWindowStart_tooEarly()         { XCTAssertEqual(forecast(40, 17700, s), .tooEarly) }
    func test05_nearWindowEnd_resettingSoon()      { XCTAssertEqual(forecast(10, 300, s), .resettingSoon) }
    func test06_fullyUsed_depleted()               { XCTAssertEqual(forecast(0, 3600, s), .depleted) }
    func test07_zeroUsed_noDivideByZero()          { XCTAssertEqual(forecast(100, 7200, s), .willNotRunOut) }
    func test08_nilResetsAt_unknown()              { XCTAssertEqual(forecast(40, nil, s), .unknown) }
    func test09_pastReset_unknown()                { XCTAssertEqual(forecast(40, -3600, s), .unknown) }
    func test10_weekly_slowerThanClock_willNotRunOut() { XCTAssertEqual(forecast(80, 345600, w), .willNotRunOut) }
    func test11_weekly_burningFast_runsOut()       { assertRunsOut(forecast(10, 259200, w), offset: 38400) }
    func test12_weekly_nearWindowStart_tooEarly()  { XCTAssertEqual(forecast(98, 596160, w), .tooEarly) }
    func test13_clockSkew_beyondWindow_tooEarly()  { XCTAssertEqual(forecast(20, 21600, s), .tooEarly) }

    // MARK: - Constants

    func testForecastConstants() {
        XCTAssertEqual(UsagePopoverView.minElapsedFraction, 0.10, accuracy: 0.0001)
        XCTAssertEqual(UsagePopoverView.minRemainingSeconds, 600)
        XCTAssertEqual(UsagePopoverView.paceBand, 3)
    }

    // MARK: - forecastCaption (U3)

    func testCaption_states() {
        XCTAssertEqual(UsagePopoverView.forecastCaption(.onPace), "On track")
        XCTAssertEqual(UsagePopoverView.forecastCaption(.willNotRunOut), "Won't run out")
        XCTAssertEqual(UsagePopoverView.forecastCaption(.depleted), "Used up")
        XCTAssertEqual(UsagePopoverView.forecastCaption(.tooEarly), "--")
        XCTAssertEqual(UsagePopoverView.forecastCaption(.resettingSoon), "--")
        XCTAssertNil(UsagePopoverView.forecastCaption(.unknown))
    }

    func testCaption_runsOut_matchesFormattedTime() {
        let date = resetsIn(9000)
        XCTAssertEqual(UsagePopoverView.forecastCaption(.runsOut(date), now: now),
                       UsagePopoverView.formatForecastTime(date, now: now))
        XCTAssertTrue(UsagePopoverView.formatForecastTime(date, now: now).hasPrefix("~"))
    }

    func testFormatForecastTime_laterDayIncludesWeekday() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let sameDay = UsagePopoverView.formatForecastTime(now.addingTimeInterval(3600), now: now, calendar: utc)
        let laterDay = UsagePopoverView.formatForecastTime(now.addingTimeInterval(48 * 3600), now: now, calendar: utc)
        XCTAssertNotEqual(sameDay, laterDay)
        XCTAssertGreaterThan(laterDay.count, sameDay.count)  // weekday prefix makes the later-day form longer
    }
}
