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
        XCTAssertEqual(UsagePopoverView.forecastCaption(.weeklyLimited), "Limited by weekly")
        XCTAssertEqual(UsagePopoverView.forecastCaption(.tooEarly), "--")
        XCTAssertEqual(UsagePopoverView.forecastCaption(.resettingSoon), "--")
        XCTAssertNil(UsagePopoverView.forecastCaption(.unknown))
    }

    // MARK: - sessionForecast (weekly-gated Session card, #31 must stay on RAW session)

    /// UsageData with session/weekly derived independently and a session reset `sessionResetsIn`
    /// seconds from `now`.
    private func makeUsage(session: Double, weekly: Double, sessionResetsIn: TimeInterval?) -> UsageData {
        UsageData(from: UsageResponse(
            fiveHour: makeTier(utilization: 100 - session, resetsAt: sessionResetsIn.map(resetsIn)),
            sevenDay: makeTier(utilization: 100 - weekly),
            sevenDayOpus: nil, sevenDaySonnet: nil, extraUsage: nil, limits: nil, spend: nil))
    }

    private func makeTier(utilization: Double, resetsAt: Date? = nil) -> UsageTier {
        var json: [String: Any] = ["utilization": utilization]
        if let date = resetsAt {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            json["resets_at"] = f.string(from: date)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(UsageTier.self, from: try! JSONSerialization.data(withJSONObject: json))
    }

    func testSessionForecast_weeklyBindsAndLow_isWeeklyLimited() {
        // Weekly nearly exhausted (5) with a high session (90): the Session card defers to weekly.
        let usage = makeUsage(session: 90, weekly: 5, sessionResetsIn: 9000)
        XCTAssertEqual(UsagePopoverView.sessionForecast(for: usage, now: now), .weeklyLimited)
    }

    func testSessionForecast_healthyWeek_forecastsOnRawSession() {
        // Weekly healthy (50): forecast runs on RAW session=90 over the 5h window. At 50% time
        // remaining, 90% usage remaining is slower than the clock -> .willNotRunOut.
        let usage = makeUsage(session: 90, weekly: 50, sessionResetsIn: 9000)
        XCTAssertEqual(UsagePopoverView.sessionForecast(for: usage, now: now), .willNotRunOut)
    }

    func testSessionForecast_weeklyBindsButSessionRunsOutFirst_showsSessionRunOut() {
        // Weekly binds (14 < 15 and < 20), but the RAW session (15%, 50% of the window elapsed)
        // is projected to run out within ~26 min. That nearer, concrete wall must win over the
        // "Limited by weekly" label (whose reset is days away).
        let usage = makeUsage(session: 15, weekly: 14, sessionResetsIn: 9000)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        guard case .runsOut = UsagePopoverView.sessionForecast(for: usage, now: now) else {
            return XCTFail("expected .runsOut (session runs out before the weekly), got weekly-limited")
        }
    }

    func testGaugeA11y_weeklyLimited_omitsSessionTimeAndSaysLimited() {
        // P3: a weekly-limited Session shows the weekly quota, so the session time-arc is
        // suppressed (timeRemaining nil). The a11y label must then NOT announce a session time,
        // and must not pair weekly usage with session time.
        let label = UsagePopoverView.gaugeAccessibilityLabel(
            name: "Session", usage: 2, timeRemaining: nil, forecast: .weeklyLimited)
        XCTAssertEqual(label, "Session usage 2 percent, Limited by weekly")
    }

    func testSessionForecast_neverFeedsCappedValueIntoRunOut() {
        // Discriminator: if the capped gauge value (weekly=5) were fed into projectedRunOut over
        // the 5h window it would compute a bogus .runsOut. sessionForecast must instead return
        // .weeklyLimited, and must NOT equal the wrong .runsOut result.
        let usage = makeUsage(session: 90, weekly: 5, sessionResetsIn: 9000)
        let wrong = UsagePopoverView.projectedRunOut(remainingPercent: usage.sessionGaugeRemaining,
                                                     resetsAt: usage.sessionResetDate,
                                                     window: s, now: now)
        if case .runsOut = wrong {} else { XCTFail("expected the capped-value path to (wrongly) produce .runsOut") }
        XCTAssertEqual(UsagePopoverView.sessionForecast(for: usage, now: now), .weeklyLimited)
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
