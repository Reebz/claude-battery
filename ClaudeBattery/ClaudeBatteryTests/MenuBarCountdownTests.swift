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
        // Guard the fixture itself: the decode must yield the reset date the cases assume.
        XCTAssertEqual(usage.sessionResetDate, resetDate)
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
}
