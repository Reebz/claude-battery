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

    func testSessionPace_weeklyBindsAndAhead_isWeeklyLimited() {
        // Weekly nearly exhausted (5) with a high session (90) ahead of pace: defer to weekly.
        let usage = makeUsage(session: 90, weekly: 5, sessionResetsIn: 9000)
        XCTAssertEqual(UsagePopoverView.sessionPace(for: usage, now: now), .weeklyLimited)
    }

    func testSessionPace_healthyWeek_gradesRawSession() {
        // Weekly healthy (50): pace grades RAW session=90 over 5h. time 50%, delta -40 -> On Track.
        let usage = makeUsage(session: 90, weekly: 50, sessionResetsIn: 9000)
        XCTAssertEqual(UsagePopoverView.sessionPace(for: usage, now: now), .onTrack)
    }

    func testSessionPace_weeklyBindsButSessionInDanger_showsDanger() {
        // Weekly binds (14 < 15 and < 20), but RAW session (15%, 50% of the window) has delta +35
        // -> Danger. That nearer, concrete wall must win over the "Limited by weekly" label.
        let usage = makeUsage(session: 15, weekly: 14, sessionResetsIn: 9000)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        XCTAssertEqual(UsagePopoverView.sessionPace(for: usage, now: now), .danger)
    }

    func testSessionPace_neverGradesCappedValue() {
        // Discriminator: the capped gauge value (weekly=5) over the 5h window would grade Danger;
        // sessionPace must instead return .weeklyLimited (it grades the RAW session, which is ahead).
        let usage = makeUsage(session: 90, weekly: 5, sessionResetsIn: 9000)
        let wrong = UsagePopoverView.paceStatus(remainingPercent: usage.sessionDisplayRemaining,
                                                resetsAt: usage.sessionResetDate, window: s, now: now)
        XCTAssertEqual(wrong, .danger)
        XCTAssertEqual(UsagePopoverView.sessionPace(for: usage, now: now), .weeklyLimited)
    }

    // MARK: - gaugeAccessibilityLabel

    func testGaugeA11y_weeklyLimited_omitsSessionTimeAndSaysLimited() {
        // A weekly-limited Session suppresses the session time-arc (timeRemaining nil); the a11y
        // label must not announce a session time and must not pair weekly usage with session time.
        let label = UsagePopoverView.gaugeAccessibilityLabel(
            name: "Session", usage: 2, timeRemaining: nil, pace: .weeklyLimited)
        XCTAssertEqual(label, "Session usage 2 percent, limited by weekly")
    }

    func testGaugeA11y_speaksPaceWithMeaning() {
        let label = UsagePopoverView.gaugeAccessibilityLabel(
            name: "Weekly", usage: 66, timeRemaining: 84, pace: .caution)
        XCTAssertEqual(label, "Weekly usage 66 percent, time remaining 84 percent, caution, over pace")
    }
}
