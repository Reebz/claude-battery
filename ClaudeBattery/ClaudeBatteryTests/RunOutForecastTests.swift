import XCTest
import SwiftUI
@testable import ClaudeBattery

/// Locks the pure pace-status math (#31 RAG simplification). Pace delta = timeRemaining% -
/// usageRemaining% (percentage points; positive = burning faster than the clock), bucketed
/// On Track (<10) / Caution (>=10, <25) / Danger (>=25). Being ahead of pace (negative delta)
/// is always On Track; 0% usage remaining is Danger. A fixed `now`, a `resetsIn` helper, and
/// pure static calls, mirroring `PaceBarTests`.
final class RunOutForecastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let s = UsagePopoverView.sessionWindow   // 18000
    private let w = UsagePopoverView.weeklyWindow     // 604800

    private func resetsIn(_ interval: TimeInterval) -> Date { now.addingTimeInterval(interval) }

    /// `r == nil` models a nil `resetsAt`; otherwise the reset is `r` seconds from `now`.
    private func pace(_ remaining: Double, _ r: TimeInterval?, _ window: TimeInterval) -> UsagePopoverView.PaceStatus {
        UsagePopoverView.paceStatus(remainingPercent: remaining, resetsAt: r.map(resetsIn), window: window, now: now)
    }

    // MARK: - paceStatus buckets
    // Session window 18000s; r=9000 => timeRemaining 50%. delta = 50 - remaining%.

    func test01_aheadOfPace_onTrack()       { XCTAssertEqual(pace(90, 9000, s), .onTrack) }   // delta -40
    func test02_slightlyOver_onTrack()      { XCTAssertEqual(pace(45, 9000, s), .onTrack) }   // delta +5
    func test03_boundaryCautionAt10()       { XCTAssertEqual(pace(40, 9000, s), .caution) }   // delta +10 (inclusive)
    func test04_midCaution()                { XCTAssertEqual(pace(30, 9000, s), .caution) }   // delta +20
    func test05_justUnderDanger()           { XCTAssertEqual(pace(26, 9000, s), .caution) }   // delta +24
    func test06_boundaryDangerAt25()        { XCTAssertEqual(pace(25, 9000, s), .danger) }    // delta +25 (inclusive)
    func test07_wellOverPace_danger()       { XCTAssertEqual(pace(10, 9000, s), .danger) }    // delta +40
    func test08_fullyUsed_danger()          { XCTAssertEqual(pace(0, 3600, s), .danger) }     // 0% remaining
    func test09_fullUsage_onTrack()         { XCTAssertEqual(pace(100, 9000, s), .onTrack) }  // delta -50
    func test10_nilResetsAt_unknown()       { XCTAssertEqual(pace(40, nil, s), .unknown) }
    func test11_pastReset_unknown()         { XCTAssertEqual(pace(40, -3600, s), .unknown) }
    func test12_clockSkewBeyondWindow_capsTimeAt100_danger() {
        // r=21600 > window 18000 -> time capped at 100; remaining 20 -> delta +80 -> Danger.
        XCTAssertEqual(pace(20, 21600, s), .danger)
    }
    func test13_weekly_aheadOfPace_onTrack() { XCTAssertEqual(pace(80, 345600, w), .onTrack) } // time ~57%, delta ~-23
    func test14_weekly_burningFast_danger()  { XCTAssertEqual(pace(10, 259200, w), .danger) }  // time ~42.9%, delta ~+32.9
    func test15_reportedWeekly_caution() {
        // The reported screenshot case: 84% time remaining, 66% usage remaining -> delta +18 -> Caution.
        XCTAssertEqual(pace(66, 0.84 * w, w), .caution)
    }

    // MARK: - Constants

    func testPaceConstants() {
        XCTAssertEqual(UsagePopoverView.cautionDelta, 10, accuracy: 0.0001)
        XCTAssertEqual(UsagePopoverView.dangerDelta, 25, accuracy: 0.0001)
    }

    // MARK: - paceCaption

    func testCaption_states() {
        XCTAssertEqual(UsagePopoverView.paceCaption(.onTrack), "On Track")
        XCTAssertEqual(UsagePopoverView.paceCaption(.caution), "Caution")
        XCTAssertEqual(UsagePopoverView.paceCaption(.danger), "Danger")
        XCTAssertEqual(UsagePopoverView.paceCaption(.weeklyLimited), "Limited by weekly")
        XCTAssertNil(UsagePopoverView.paceCaption(.unknown))
    }

    func testColor_RAG() {
        XCTAssertEqual(UsagePopoverView.paceColor(.onTrack), Color.green)
        XCTAssertEqual(UsagePopoverView.paceColor(.caution), Color.orange)
        XCTAssertEqual(UsagePopoverView.paceColor(.danger), Color.red)
    }

    // MARK: - sessionPace (weekly-gated Session card, #31 must stay on RAW session)

    /// UsageData with session/weekly derived independently and a session reset `sessionResetsIn`
    /// seconds from `now`. These cases carry the Max 5x plan ratio by default, because a non-zero
    /// weekly can only bind once it has been converted into session units and with no ratio there
    /// is nothing to convert. An exhausted week is the exception - it converts to zero on every
    /// plan - so the case below states `planRatio: nil` outright.
    private func makeUsage(session: Double, weekly: Double, sessionResetsIn: TimeInterval?,
                           planRatio: Double? = PlanRatio.max5x) -> UsageData {
        UsageData(from: UsageResponse(
            fiveHour: makeTier(utilization: 100 - session, resetsAt: sessionResetsIn.map(resetsIn)),
            sevenDay: makeTier(utilization: 100 - weekly),
            sevenDayOpus: nil, sevenDaySonnet: nil, extraUsage: nil, limits: nil, spend: nil),
                  planRatio: planRatio)
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

    func testSessionPace_weeklyBindsAndAhead_isWeeklyLimited() {
        // Weekly nearly exhausted (5, or 63.1% of a session once converted) with a high session
        // (90) ahead of pace: defer to weekly.
        let usage = makeUsage(session: 90, weekly: 5, sessionResetsIn: 9000)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        XCTAssertEqual(UsagePopoverView.sessionPace(for: usage, now: now), .weeklyLimited)
    }

    func testSessionPace_healthyWeek_gradesRawSession() {
        // Weekly healthy (50): pace grades RAW session=90 over 5h. time 50%, delta -40 -> On Track.
        let usage = makeUsage(session: 90, weekly: 50, sessionResetsIn: 9000)
        XCTAssertEqual(UsagePopoverView.sessionPace(for: usage, now: now), .onTrack)
    }

    func testSessionPace_weeklyBindsButSessionInDanger_showsDanger() {
        // Weekly binds (1% of the week is 12.6% of a session, under the session's 15), but RAW
        // session (15%, 50% of the window) has delta +35 -> Danger. That nearer, concrete wall
        // must win over the "Limited by weekly" label.
        let usage = makeUsage(session: 15, weekly: 1, sessionResetsIn: 9000)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        XCTAssertEqual(UsagePopoverView.sessionPace(for: usage, now: now), .danger)
    }

    func testSessionPace_neverGradesCappedValue() {
        // Discriminator: the capped gauge value (weekly 1 -> 12.6 in session units) over the 5h
        // window would grade Danger; sessionPace must instead return .weeklyLimited (it grades the
        // RAW session, which is ahead).
        let usage = makeUsage(session: 90, weekly: 1, sessionResetsIn: 9000)
        let wrong = UsagePopoverView.paceStatus(remainingPercent: usage.sessionDisplayRemaining,
                                                resetsAt: usage.sessionResetDate, window: s, now: now)
        XCTAssertEqual(wrong, .danger)
        XCTAssertEqual(UsagePopoverView.sessionPace(for: usage, now: now), .weeklyLimited)
    }

    func testSessionPace_weeklyExhaustedWithNoRatio_stillSaysLimitedByWeekly() {
        // The caption half of the exhausted-week case. With no plan ratio the pace used to fall
        // through to the RAW session (100 remaining, half the window left, delta -50) and print
        // "On Track" in green while the week was spent. Zero needs no ratio to convert, so the
        // caption fires on an account whose plan is unknown - which is every account carried over
        // from v1.60, since the tier is written only on the sign-in and re-auth routes.
        let usage = makeUsage(session: 100, weekly: 0, sessionResetsIn: 9000, planRatio: nil)
        XCTAssertNil(usage.planRatio)
        XCTAssertTrue(usage.isSessionWeeklyLimited, "this also suppresses the session time arc")
        let pace = UsagePopoverView.sessionPace(for: usage, now: now)
        XCTAssertEqual(pace, .weeklyLimited)
        XCTAssertEqual(UsagePopoverView.paceCaption(pace), "Limited by weekly")
    }

    // MARK: - runOutSeconds (KTD1: the projection reads the pace status, never re-derives it)

    /// Projection on the same inputs as `pace`, with the pace supplied from `paceStatus` unless
    /// `paceOverride` is given.
    private func runOut(_ remaining: Double, _ r: TimeInterval?, _ window: TimeInterval,
                        paceOverride: UsagePopoverView.PaceStatus? = nil) -> TimeInterval? {
        UsagePopoverView.runOutSeconds(remainingPercent: remaining,
                                       resetsAt: r.map(resetsIn),
                                       window: window,
                                       pace: paceOverride ?? pace(remaining, r, window),
                                       now: now)
    }

    private func assertSeconds(_ value: TimeInterval?, _ expected: TimeInterval,
                               file: StaticString = #file, line: UInt = #line) {
        guard let value else { return XCTFail("expected \(expected)s, got nil", file: file, line: line) }
        XCTAssertEqual(value, expected, accuracy: 1, file: file, line: line)
    }

    // Session window 18000s. (20, 7200): time 40%, delta +20 -> Caution; elapsed 60%.
    func testRunOut01_caution_session_projects2700s() {
        XCTAssertEqual(pace(20, 7200, s), .caution)
        assertSeconds(runOut(20, 7200, s), 2700)
        XCTAssertEqual(UsagePopoverView.quantiseRunOut(2700, window: s), 45 * 60)  // AE1: "Out in ~45m"
    }
    func testRunOut02_slowerThanClock_onTrack_nil()  { XCTAssertEqual(pace(70, 7200, s), .onTrack); XCTAssertNil(runOut(70, 7200, s)) }
    func testRunOut03_deltaZero_onTrack_nil()         { XCTAssertEqual(pace(40, 7200, s), .onTrack); XCTAssertNil(runOut(40, 7200, s)) }
    func testRunOut04_underTenPercentElapsed_nil() {
        // 98% of the window left: the pace gate passes (delta +58) but only 1.7% has elapsed, and
        // a burst at the start of a fresh window would project a run-out minutes away.
        XCTAssertNotEqual(pace(40, 17700, s), .onTrack)
        XCTAssertNil(runOut(40, 17700, s))
    }
    func testRunOut05_lessTimeThanUsageLeft_onTrack_nil() { XCTAssertEqual(pace(10, 300, s), .onTrack); XCTAssertNil(runOut(10, 300, s)) }
    func testRunOut06_depleted_danger_nil() {
        // The caption already says Danger; there is nothing left to project.
        XCTAssertEqual(pace(0, 3600, s), .danger)
        XCTAssertNil(runOut(0, 3600, s))
    }
    func testRunOut07_nothingUsed_onTrack_nil_noDivideByZero() { XCTAssertEqual(pace(100, 7200, s), .onTrack); XCTAssertNil(runOut(100, 7200, s)) }
    func testRunOut08_tooLittleUsed_onTrack_nil() {
        // AE3: 97% and 95% left early in the window are On Track, so the gate hides them.
        XCTAssertEqual(pace(97, 16000, s), .onTrack); XCTAssertNil(runOut(97, 16000, s))
        XCTAssertEqual(pace(95, 16000, s), .onTrack); XCTAssertNil(runOut(95, 16000, s))
    }
    func testRunOut09_boundaryCaution_projects6000s() {
        // (40, 9000): time 50%, delta +10 -> Caution (inclusive). (18000 - 9000) * 40 / 60 = 6000.
        XCTAssertEqual(pace(40, 9000, s), .caution)
        assertSeconds(runOut(40, 9000, s), 6000)
    }
    func testRunOut10_resetBeyondWindow_clockSkew_nil() {
        // r=21600 > window 18000: paceStatus caps time at 100 and says Danger, but elapsed time
        // would be negative, so the projection declines.
        XCTAssertEqual(pace(20, 21600, s), .danger)
        XCTAssertNil(runOut(20, 21600, s))
    }
    func testRunOut11_nilAndPastReset_nil() {
        XCTAssertNil(runOut(20, nil, s))
        XCTAssertNil(runOut(20, -3600, s))
    }
    func testRunOut12_weekly_danger_projects38400s() {
        // (10, 259200, w): time ~42.9%, delta ~+32.9 -> Danger. (604800 - 259200) * 10 / 90 = 38400.
        XCTAssertEqual(pace(10, 259200, w), .danger)
        assertSeconds(runOut(10, 259200, w), 38400)
        XCTAssertEqual(UsagePopoverView.quantiseRunOut(38400, window: w), 11 * 3600)
    }
    func testRunOut13_weekly_freshWindow_onTrack_nil() { XCTAssertEqual(pace(98, 596160, w), .onTrack); XCTAssertNil(runOut(98, 596160, w)) }

    func testRunOut_invariant_projectionLandsBeforeReset() {
        // For every Caution and Danger case in the table that projects, the run-out is below the
        // seconds to reset: (window - r) * remaining / (100 - remaining) < r exactly when the pace
        // delta is positive (KTD1).
        let cases: [(Double, TimeInterval, TimeInterval)] = [(20, 7200, s), (40, 9000, s), (10, 259200, w)]
        for (remaining, r, window) in cases {
            let p = pace(remaining, r, window)
            XCTAssertTrue(p == .caution || p == .danger, "case \(remaining)/\(r) is \(p)")
            guard let seconds = runOut(remaining, r, window) else {
                return XCTFail("case \(remaining)/\(r) projected nil")
            }
            XCTAssertLessThan(seconds, r, "case \(remaining)/\(r) projects past its own reset")
        }
    }

    func testRunOut_paceGate_onlyCautionAndDangerProject() {
        // Same inputs as testRunOut01, but the pace handed in is not Caution or Danger.
        XCTAssertNil(runOut(20, 7200, s, paceOverride: .onTrack))
        XCTAssertNil(runOut(20, 7200, s, paceOverride: .weeklyLimited))
        XCTAssertNil(runOut(20, 7200, s, paceOverride: .unknown))
        assertSeconds(runOut(20, 7200, s, paceOverride: .danger), 2700)
    }

    // MARK: - quantiseRunOut (5 min on the session, 1 h on the weekly, never below one quantum)

    func testQuantise_session_nearestFiveMinutes() {
        XCTAssertEqual(UsagePopoverView.quantiseRunOut(2710, window: s), 45 * 60)
        XCTAssertEqual(UsagePopoverView.quantiseRunOut(2880, window: s), 50 * 60)
    }
    func testQuantise_weekly_nearestHour() {
        XCTAssertEqual(UsagePopoverView.quantiseRunOut(38400, window: w), 11 * 3600)
    }
    func testQuantise_floorsAtOneQuantum() {
        XCTAssertEqual(UsagePopoverView.quantiseRunOut(200, window: s), 5 * 60)
        XCTAssertEqual(UsagePopoverView.quantiseRunOut(1, window: s), 5 * 60)
        XCTAssertEqual(UsagePopoverView.quantiseRunOut(1, window: w), 3600)
    }

    // MARK: - runOutLine (KD6: relative, "Out in ~")

    func testRunOutLine_formatsMinuteResolution() {
        XCTAssertEqual(UsagePopoverView.runOutLine(seconds: 6000), "Out in ~1h 40m")
        XCTAssertEqual(UsagePopoverView.runOutLine(seconds: 45 * 60), "Out in ~45m")
        XCTAssertEqual(UsagePopoverView.runOutLine(seconds: 11 * 3600), "Out in ~11h 00m")
    }
    func testRunOutLine_nilHidesTheLine() {
        // AE2 together with the pace gate: On Track projects nil, and nil prints nothing.
        XCTAssertNil(UsagePopoverView.runOutLine(seconds: nil))
        XCTAssertNil(UsagePopoverView.runOutLine(seconds: runOut(45, 9000, s)))
    }

    // MARK: - sessionDialLines(...).runOutSeconds (KD7: weekly-limited hides the run-out unless the raw session is in Danger)

    func testSessionRunOut_weeklyLimitedAndRawOnTrack_nil() {
        let usage = makeUsage(session: 90, weekly: 5, sessionResetsIn: 9000)
        XCTAssertEqual(UsagePopoverView.sessionPace(for: usage, now: now), .weeklyLimited)
        XCTAssertNil(UsagePopoverView.sessionDialLines(for: usage, now: now).runOutSeconds)
    }

    func testSessionRunOut_weeklyLimitedButRawDanger_projectsRawSession() {
        // AE4 second half: the raw session (15%, half the window left) is in Danger, so the
        // run-out shows and it is the RAW session's projection: 9000 * 15 / 85 (1588 s), which
        // `sessionDialLines` quantises to the nearest 5 minutes on the session window (1500 s).
        let usage = makeUsage(session: 15, weekly: 1, sessionResetsIn: 9000)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        XCTAssertEqual(UsagePopoverView.sessionPace(for: usage, now: now), .danger)
        assertSeconds(UsagePopoverView.sessionDialLines(for: usage, now: now).runOutSeconds,
                      UsagePopoverView.quantiseRunOut(9000 * 15 / 85, window: s))
        assertSeconds(UsagePopoverView.sessionDialLines(for: usage, now: now).runOutSeconds, 25 * 60)
    }

    func testSessionRunOut_healthyWeek_projectsRawSession() {
        // 6000 s is already on a 5-minute boundary, so quantising leaves it unchanged.
        let usage = makeUsage(session: 40, weekly: 50, sessionResetsIn: 9000)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        assertSeconds(UsagePopoverView.sessionDialLines(for: usage, now: now).runOutSeconds,
                      UsagePopoverView.quantiseRunOut(6000, window: s))
        assertSeconds(UsagePopoverView.sessionDialLines(for: usage, now: now).runOutSeconds, 6000)
    }

    func testSessionRunOut_neverProjectsTheCappedValue() {
        // Discriminator: the capped display value (weekly 1 -> 12.6 in session units) over the 5h
        // window would grade Danger and project a run-out; the raw session (90) is ahead, so the
        // Session card must show nothing.
        let usage = makeUsage(session: 90, weekly: 1, sessionResetsIn: 9000)
        let wrongPace = UsagePopoverView.paceStatus(remainingPercent: usage.sessionDisplayRemaining,
                                                    resetsAt: usage.sessionResetDate, window: s, now: now)
        XCTAssertEqual(wrongPace, .danger)
        XCTAssertNotNil(UsagePopoverView.runOutSeconds(remainingPercent: usage.sessionDisplayRemaining,
                                                       resetsAt: usage.sessionResetDate, window: s,
                                                       pace: wrongPace, now: now))
        XCTAssertNil(UsagePopoverView.sessionDialLines(for: usage, now: now).runOutSeconds)
    }

    // MARK: - ringColor (KD5: pace colour with a red floor below the nearly-empty threshold)

    func testRingColor_followsPaceAboveTheFloor() {
        XCTAssertEqual(UsagePopoverView.ringColor(remaining: 30, pace: .danger), Color.red)    // AE6
        XCTAssertEqual(UsagePopoverView.ringColor(remaining: 30, pace: .onTrack), Color.green)  // AE6
        XCTAssertEqual(UsagePopoverView.ringColor(remaining: 30, pace: .caution), Color.orange)
    }
    func testRingColor_redFloorBelowThreshold() {
        XCTAssertEqual(UsagePopoverView.ringColor(remaining: 15, pace: .onTrack), Color.red)    // AE6
        XCTAssertEqual(UsagePopoverView.ringColor(remaining: 19.9, pace: .caution), Color.red)
        XCTAssertEqual(UsagePopoverView.ringColor(remaining: 20, pace: .caution), Color.orange) // boundary
    }
    func testRingColor_fallsBackToLevelColourWithoutAPace() {
        XCTAssertEqual(UsagePopoverView.ringColor(remaining: 60, pace: .unknown), Color.green)
        XCTAssertEqual(UsagePopoverView.ringColor(remaining: 30, pace: .unknown), Color.orange)
        XCTAssertEqual(UsagePopoverView.ringColor(remaining: 30, pace: .weeklyLimited), Color.orange)
    }

    // MARK: - paceCaptionColor (KD13: the word shares the ring's red floor)

    func testPaceCaptionColor_sharesTheRedFloor() {
        XCTAssertEqual(UsagePopoverView.paceCaptionColor(remaining: 15, pace: .onTrack), Color.red)        // AE6
        XCTAssertEqual(UsagePopoverView.paceCaptionColor(remaining: 19.9, pace: .weeklyLimited), Color.red)
    }
    func testPaceCaptionColor_isPaceColourAboveTheFloor() {
        XCTAssertEqual(UsagePopoverView.paceCaptionColor(remaining: 30, pace: .onTrack), Color.green)
        XCTAssertEqual(UsagePopoverView.paceCaptionColor(remaining: 30, pace: .danger), Color.red)
        // "Limited by weekly" keeps its muted colour above the floor.
        XCTAssertEqual(UsagePopoverView.paceCaptionColor(remaining: 30, pace: .weeklyLimited),
                       UsagePopoverView.paceColor(.weeklyLimited))
        XCTAssertNotEqual(UsagePopoverView.paceCaptionColor(remaining: 30, pace: .weeklyLimited), Color.red)
    }

    // MARK: - lowRemainingThreshold (KTD2: one owner for "nearly empty")

    func testLowRemainingThreshold_isTwentyAndBatteryColorReadsIt() {
        XCTAssertEqual(UsageData.lowRemainingThreshold, 20, accuracy: 0.0001)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 19.9), Color.red)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 20), Color.orange)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: UsageData.lowRemainingThreshold - 0.1), Color.red)
    }

    // MARK: - gaugeAccessibilityLabel

    func testGaugeA11y_weeklyLimited_omitsSessionTimeAndSaysLimited() {
        // A weekly-limited Session suppresses the session time-arc (timeRemaining nil); the a11y
        // label must not announce a session time and must not pair weekly usage with session time.
        let label = UsagePopoverView.gaugeAccessibilityLabel(
            name: "Session", usage: 2, timeRemaining: nil, pace: .weeklyLimited)
        XCTAssertEqual(label, "Session usage 2 percent, limited by weekly")
    }

    func testGaugeA11y_roundsHalvesTheWayTheGaugePrintsThem() {
        // The gauge prints these same two Doubles with "%.0f", which rounds a half to the EVEN
        // integer: 16.5 draws "16". Plain .rounded() goes half away from zero and would speak 17,
        // so a screen reader would announce a different number from the one on screen - the #43
        // mismatch again, this time between the dial and the voice. 16.5 rather than 15.5 or 17.5
        // on purpose: only halves with an even integer part tell the two modes apart.
        let label = UsagePopoverView.gaugeAccessibilityLabel(
            name: "Session", usage: 16.5, timeRemaining: 42.5, pace: .unknown)
        XCTAssertEqual(label, "Session usage 16 percent, time remaining 42 percent")
    }

    func testGaugeA11y_speaksPaceWithMeaning() {
        let label = UsagePopoverView.gaugeAccessibilityLabel(
            name: "Weekly", usage: 66, timeRemaining: 84, pace: .caution)
        XCTAssertEqual(label, "Weekly usage 66 percent, time remaining 84 percent, caution, over pace")
    }

    // MARK: - dialLines (KTD3: the three lines under a dial from one pure function, never the display value)

    /// Lines for one card on the same inputs as `pace`, with the pace supplied from `paceStatus`
    /// unless `paceOverride` is given.
    private func lines(_ remaining: Double, _ r: TimeInterval?, _ window: TimeInterval,
                       paceOverride: UsagePopoverView.PaceStatus? = nil) -> UsagePopoverView.DialLines {
        UsagePopoverView.dialLines(pace: paceOverride ?? pace(remaining, r, window),
                                   rawRemaining: remaining,
                                   resetsAt: r.map(resetsIn),
                                   window: window,
                                   now: now)
    }

    func testDialLines_caution_captionRunOutCountdown() {
        // (40, 9000, s): Caution, run-out 6000 s (already a 5 min multiple), 2h 30m to reset.
        let l = lines(40, 9000, s)
        XCTAssertEqual(l.caption, "Caution")
        XCTAssertEqual(l.runOut, "Out in ~1h 40m")
        XCTAssertEqual(l.countdown, "Resets in 2h 30m")
        XCTAssertEqual(l.runOutSeconds ?? -1, 6000, accuracy: 1)
        XCTAssertEqual(l.resetSeconds ?? -1, 9000, accuracy: 1)
    }

    func testDialLines_onTrack_noRunOutButCountdown() {
        // AE2: the maths would give a time, but On Track hides it. The countdown still shows.
        let l = lines(45, 9000, s)
        XCTAssertEqual(l.caption, "On Track")
        XCTAssertNil(l.runOut)
        XCTAssertNil(l.runOutSeconds)
        XCTAssertEqual(l.countdown, "Resets in 2h 30m")
    }

    func testDialLines_runOutIsQuantisedBeforePrinting() {
        // AE1 shape: (20, 7200, s) projects 2700 s, which prints as the quantised "~45m", and the
        // weekly (10, 259200, w) projects 38400 s, printed to the hour. runOutLine prints what it
        // is given, so dialLines must quantise first.
        let session = lines(20, 7200, s)
        XCTAssertEqual(session.caption, "Caution")
        XCTAssertEqual(session.runOut, "Out in ~45m")
        XCTAssertEqual(session.countdown, "Resets in 2h 00m")
        let weekly = lines(10, 259200, w)
        XCTAssertEqual(weekly.caption, "Danger")
        XCTAssertEqual(weekly.runOut, "Out in ~11h 00m")
        XCTAssertEqual(weekly.countdown, "Resets in 3d 00h")
    }

    func testDialLines_noResetTime_singleUnavailableLine() {
        // AE5: no reset time -> no caption, no run-out, one "Reset time unavailable" line.
        let l = lines(40, nil, s)
        XCTAssertNil(l.caption)
        XCTAssertNil(l.runOut)
        XCTAssertEqual(l.countdown, "Reset time unavailable")
        XCTAssertNil(l.resetSeconds)
        XCTAssertNil(l.runOutSeconds)
        XCTAssertEqual(l.countdown, UsagePopoverView.resetUnavailableLine)
    }

    func testDialLines_pastResetTime_sameAsNoResetTime() {
        // A stale poll whose reset is already behind us self-omits exactly like a missing one,
        // even when the caller hands in a pace that would otherwise print a word.
        XCTAssertEqual(lines(40, -3600, s), lines(40, nil, s))
        let stale = lines(40, -3600, s, paceOverride: .caution)
        XCTAssertNil(stale.caption)
        XCTAssertNil(stale.runOut)
        XCTAssertEqual(stale.countdown, "Reset time unavailable")
    }

    func testDialLines_underAMinuteToReset_printsLessThanAMinute() {
        let l = lines(40, 30, s)
        XCTAssertEqual(l.countdown, "Resets in <1m")
    }

    // MARK: - sessionDialLines (KD7: mirrors sessionPace and picks the RAW session itself)

    func testSessionDialLines_planRatioNil_cautionCase() {
        // The packet's shape case: 40% left, 9000 s to reset, no plan ratio.
        let usage = makeUsage(session: 40, weekly: 50, sessionResetsIn: 9000, planRatio: nil)
        let l = UsagePopoverView.sessionDialLines(for: usage, now: now)
        XCTAssertEqual(l.caption, "Caution")
        XCTAssertEqual(l.runOut, "Out in ~1h 40m")
        XCTAssertEqual(l.countdown, "Resets in 2h 30m")
    }

    func testSessionDialLines_weeklyLimitedRawOnTrack_wordAndSessionCountdownOnly() {
        // AE4 first half: "Limited by weekly", the SESSION reset countdown, no run-out.
        let usage = makeUsage(session: 90, weekly: 5, sessionResetsIn: 9000)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        let l = UsagePopoverView.sessionDialLines(for: usage, now: now)
        XCTAssertEqual(l.caption, "Limited by weekly")
        XCTAssertNil(l.runOut)
        XCTAssertEqual(l.countdown, "Resets in 2h 30m")
    }

    func testSessionDialLines_weeklyLimitedRawDanger_allThreeLines() {
        // AE4 second half: raw session (15%, half the window left) is in Danger, so the word is
        // "Danger", the run-out is the RAW session's 9000 * 15 / 85 = 1588 s quantised to 25m, and
        // the countdown shows.
        let usage = makeUsage(session: 15, weekly: 1, sessionResetsIn: 9000)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        let l = UsagePopoverView.sessionDialLines(for: usage, now: now)
        XCTAssertEqual(l.caption, "Danger")
        XCTAssertEqual(l.runOut, "Out in ~25m")
        XCTAssertEqual(l.countdown, "Resets in 2h 30m")
    }

    func testSessionDialLines_neverProjectsTheCappedValue() {
        // The raw-value discriminator: the capped display value (weekly 1 -> 12.6 in session
        // units) would project a run-out over the 5h window, but the raw session (90) is ahead.
        let usage = makeUsage(session: 90, weekly: 1, sessionResetsIn: 9000)
        let wrong = UsagePopoverView.dialLines(pace: .danger, rawRemaining: usage.sessionDisplayRemaining,
                                               resetsAt: usage.sessionResetDate, window: s, now: now)
        XCTAssertNotNil(wrong.runOut, "the capped value would print a run-out")
        let l = UsagePopoverView.sessionDialLines(for: usage, now: now)
        XCTAssertNil(l.runOut)
        XCTAssertEqual(l.caption, "Limited by weekly")
    }

    func testSessionDialLines_noSessionReset_unavailable() {
        let usage = makeUsage(session: 40, weekly: 50, sessionResetsIn: nil)
        let l = UsagePopoverView.sessionDialLines(for: usage, now: now)
        XCTAssertNil(l.caption)
        XCTAssertNil(l.runOut)
        XCTAssertEqual(l.countdown, "Reset time unavailable")
    }

    // MARK: - gaugeAccessibilityLabel with the lines folded in (one spoken dial, KTD3)

    func testGaugeA11y_foldsInCountdownAndRunOut() {
        let label = UsagePopoverView.gaugeAccessibilityLabel(
            name: "Session", usage: 40, timeRemaining: 50, pace: .caution, lines: lines(40, 9000, s))
        XCTAssertTrue(label.contains("caution, over pace"), label)
        XCTAssertTrue(label.contains("resets in 2 hours 30 minutes"), label)
        XCTAssertTrue(label.contains("projected to run out in about 1 hour 40 minutes"), label)
        XCTAssertEqual(label, "Session usage 40 percent, time remaining 50 percent, caution, over pace, "
                       + "projected to run out in about 1 hour 40 minutes, resets in 2 hours 30 minutes")
    }

    func testGaugeA11y_noResetTime_speaksUnavailableAndNoTimePhrase() {
        let label = UsagePopoverView.gaugeAccessibilityLabel(
            name: "Session", usage: 40, timeRemaining: nil, pace: .unknown, lines: lines(40, nil, s))
        XCTAssertFalse(label.contains("resets in"), label)
        XCTAssertFalse(label.contains("projected to run out"), label)
        XCTAssertEqual(label, "Session usage 40 percent, reset time unavailable")
    }

    func testGaugeA11y_onTrack_speaksCountdownWithoutRunOut() {
        let label = UsagePopoverView.gaugeAccessibilityLabel(
            name: "Weekly", usage: 45, timeRemaining: 50, pace: .onTrack, lines: lines(45, 9000, s))
        XCTAssertEqual(label, "Weekly usage 45 percent, time remaining 50 percent, on track, resets in 2 hours 30 minutes")
    }

    func testGaugeA11y_roundingUnchangedWithLines() {
        // Usage 16.5 still speaks "16", like the dial prints, with the lines present.
        let label = UsagePopoverView.gaugeAccessibilityLabel(
            name: "Session", usage: 16.5, timeRemaining: 42.5, pace: .onTrack, lines: lines(16.5, 9000, s))
        XCTAssertTrue(label.hasPrefix("Session usage 16 percent, time remaining 42 percent"), label)
    }

    func testSpokenDuration_wordsForTheLinesTheDialPrints() {
        XCTAssertEqual(UsagePopoverView.spokenDuration(seconds: 2 * 3600 + 30 * 60), "2 hours 30 minutes")
        XCTAssertEqual(UsagePopoverView.spokenDuration(seconds: 3600 + 40 * 60), "1 hour 40 minutes")
        XCTAssertEqual(UsagePopoverView.spokenDuration(seconds: 7200), "2 hours")
        XCTAssertEqual(UsagePopoverView.spokenDuration(seconds: 45 * 60), "45 minutes")
        XCTAssertEqual(UsagePopoverView.spokenDuration(seconds: 60), "1 minute")
        XCTAssertEqual(UsagePopoverView.spokenDuration(seconds: 3 * 86400), "3 days")
        XCTAssertEqual(UsagePopoverView.spokenDuration(seconds: 86400 + 3600), "1 day 1 hour")
        XCTAssertEqual(UsagePopoverView.spokenDuration(seconds: 30), "less than a minute")
    }

    // MARK: - lastUpdatedText (the footer freshness line the minute clock refreshes, KTD10)

    func testLastUpdatedText_movesWithNowNotWithAPoll() {
        let fetched = now
        XCTAssertEqual(UsagePopoverView.lastUpdatedText(lastFetch: nil, now: now), "Not yet updated")
        XCTAssertEqual(UsagePopoverView.lastUpdatedText(lastFetch: fetched, now: now.addingTimeInterval(30)), "Updated just now")
        XCTAssertEqual(UsagePopoverView.lastUpdatedText(lastFetch: fetched, now: now.addingTimeInterval(60)), "Updated 1 minute ago")
        XCTAssertEqual(UsagePopoverView.lastUpdatedText(lastFetch: fetched, now: now.addingTimeInterval(5 * 60 + 10)), "Updated 5 minutes ago")
    }
}
