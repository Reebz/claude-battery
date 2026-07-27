import XCTest
@testable import ClaudeBattery

/// Locks the pure `MenuBarController.countdownTitle(usage:enabled:now:)` mapping. The returned
/// string is composed into the menu-bar icon as a leading "tag cell" and folded into the
/// IconSignature, but only the string mapping is unit-tested here. `UsageData` has no public
/// memberwise init, so the fixture decodes a real `UsageResponse` with a `session` limit and a
/// fixed `resets_at`, then drives `now` relative to that fixed reset so the deltas are exact and
/// clock-independent.
final class MenuBarCountdownTests: XCTestCase {

    /// A fixed epoch inside `ResetDate.dateFromEpoch`'s valid range (roughly 2001-2100),
    /// used as the session `resets_at`. now is set this-many-seconds before it per case.
    private let resetEpoch: TimeInterval = 1_750_000_000  // 2025-06-15, well within range
    private var resetDate: Date { Date(timeIntervalSince1970: resetEpoch) }

    /// Build a UsageData whose sessionResetDate is `resetEpoch`, via the production decode path.
    private func makeUsage() throws -> UsageData {
        let json = """
        {
          "limits": [
            { "kind": "session", "percent": 40, "resets_at": \(Int(resetEpoch)) }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(UsageResponse.self, from: Data(json.utf8))
        let usage = UsageData(from: response)
        // Guard the fixture itself: the decode must yield the reset date the cases assume, and
        // must NOT trip the weekly gate - with no weekly entry the decode falls back to the
        // legacy tier and lands on 100 remaining, so the cases below see a plain countdown.
        XCTAssertEqual(usage.sessionResetDate, resetDate)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        return usage
    }

    /// Build a weekly-limited UsageData: session healthy (80 remaining) but weekly nearly gone
    /// (5 remaining), so `sessionDisplayRemaining` - and therefore the session pill the countdown
    /// cell sits beside - shows the WEEKLY number. `weekly_all` is the kind the production decode
    /// reads for the weekly tier. Same `resets_at` as `makeUsage`, so a valid future session reset
    /// exists and the weekly gate is the only thing that can explain an empty countdown.
    private func makeWeeklyLimitedUsage() throws -> UsageData {
        let json = """
        {
          "limits": [
            { "kind": "session", "percent": 20, "resets_at": \(Int(resetEpoch)) },
            { "kind": "weekly_all", "percent": 95, "resets_at": \(Int(resetEpoch)) }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(UsageResponse.self, from: Data(json.utf8))
        let usage = UsageData(from: response)
        // Assert the fixture really is weekly-limited, so the case cannot silently rot into
        // testing nothing if the gate's threshold or shape moves.
        XCTAssertEqual(usage.sessionResetDate, resetDate)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        return usage
    }

    /// The same two-limit shape with a HEALTHY weekly (90 remaining), so the gate stays shut.
    /// The control for `makeWeeklyLimitedUsage`: proves the suppression is gated on the weekly
    /// limit binding rather than on merely having a weekly limit in the response.
    private func makeWeeklyHealthyUsage() throws -> UsageData {
        let json = """
        {
          "limits": [
            { "kind": "session", "percent": 20, "resets_at": \(Int(resetEpoch)) },
            { "kind": "weekly_all", "percent": 10, "resets_at": \(Int(resetEpoch)) }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(UsageResponse.self, from: Data(json.utf8))
        let usage = UsageData(from: response)
        XCTAssertEqual(usage.sessionResetDate, resetDate)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        return usage
    }

    /// A UsageData with no session reset window (legacy empty response).
    private func makeUsageWithoutSessionReset() throws -> UsageData {
        let json = "{}"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(UsageResponse.self, from: Data(json.utf8))
        let usage = UsageData(from: response)
        XCTAssertNil(usage.sessionResetDate)
        return usage
    }

    private func now(secondsBeforeReset seconds: TimeInterval) -> Date {
        resetDate.addingTimeInterval(-seconds)
    }

    func testEnabled_fourHoursTwentyMinutesOut_isHourPlus() throws {
        let usage = try makeUsage()
        let title = MenuBarController.countdownTitle(
            usage: usage, enabled: true, now: now(secondsBeforeReset: 4 * 3600 + 20 * 60)
        )
        XCTAssertEqual(title, "4h+")
    }

    func testEnabled_thirtyTwoMinutesOut_isMinutes() throws {
        let usage = try makeUsage()
        let title = MenuBarController.countdownTitle(
            usage: usage, enabled: true, now: now(secondsBeforeReset: 32 * 60)
        )
        XCTAssertEqual(title, "32m")
    }

    func testEnabled_fortySecondsOut_isLessThanAMinute() throws {
        let usage = try makeUsage()
        let title = MenuBarController.countdownTitle(
            usage: usage, enabled: true, now: now(secondsBeforeReset: 40)
        )
        XCTAssertEqual(title, "<1m")
    }

    func testEnabled_nilSessionResetDate_isEmpty() throws {
        let usage = try makeUsageWithoutSessionReset()
        let title = MenuBarController.countdownTitle(usage: usage, enabled: true, now: now(secondsBeforeReset: 600))
        XCTAssertEqual(title, "")
    }

    func testEnabled_nilUsage_isEmpty() {
        let title = MenuBarController.countdownTitle(usage: nil, enabled: true, now: resetDate)
        XCTAssertEqual(title, "")
    }

    func testDisabled_isEmptyDespiteValidResetDate() throws {
        let usage = try makeUsage()
        let title = MenuBarController.countdownTitle(
            usage: usage, enabled: false, now: now(secondsBeforeReset: 32 * 60)
        )
        XCTAssertEqual(title, "")
    }

    func testEnabled_pastResetDate_isEmpty() throws {
        let usage = try makeUsage()
        // now AFTER the reset -> non-positive countdown -> "" (never traps, never misleads).
        let title = MenuBarController.countdownTitle(
            usage: usage, enabled: true, now: now(secondsBeforeReset: -60)
        )
        XCTAssertEqual(title, "")
    }

    /// The countdown is deliberately NOT suppressed while the weekly limit binds. Suppressing it
    /// was implemented and then reverted: it took the reset time away in the state where users
    /// most want it. The known cost is locked here rather than left implicit - the pill beside
    /// this cell shows the weekly quota, so this clock runs out without that number changing.
    /// A future "consistency" change that empties the cell here has to overturn that decision.
    func testEnabled_weeklyLimited_stillReturnsTheSessionCountdown() throws {
        let usage = try makeWeeklyLimitedUsage()
        let title = MenuBarController.countdownTitle(
            usage: usage, enabled: true, now: now(secondsBeforeReset: 32 * 60)
        )
        XCTAssertEqual(title, "32m")
    }

    func testEnabled_weeklyHealthy_stillReturnsCountdown() throws {
        let usage = try makeWeeklyHealthyUsage()
        // The control: same two-limit shape with the gate shut. Together with the case above this
        // pins that the cell is indifferent to the weekly gate, in both directions.
        let title = MenuBarController.countdownTitle(
            usage: usage, enabled: true, now: now(secondsBeforeReset: 32 * 60)
        )
        XCTAssertEqual(title, "32m")
    }

    func testDefaultFixture_withNoWeeklyLimit_isNotWeeklyLimited() throws {
        let usage = try makeUsage()
        // An absent weekly entry decodes to 100 remaining, which never binds. Keeps the two cases
        // above honest: their difference really is the weekly gate and not the fixture shape.
        XCTAssertEqual(usage.weeklyRemaining, 100)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
    }
}
