import XCTest
@testable import ClaudeBattery

/// Locks the pure `MenuBarController.countdownCell(usage:enabled:now:)` mapping. The returned
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
        let usage = UsageData(from: response, planRatio: PlanRatio.max5x)
        // Guard the fixture itself: the decode must yield the reset date the cases assume, and
        // must NOT trip the weekly gate - with no weekly entry the decode falls back to the
        // legacy tier and lands on 100 remaining, so the cases below see a plain countdown.
        XCTAssertEqual(usage.sessionResetDate, resetDate)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
        return usage
    }

    /// Build a weekly-limited UsageData: session healthy (80 remaining) but weekly nearly gone
    /// (5 remaining), which on the Max 5x ratio converts to 63.1% of a session and so caps the
    /// session pill the countdown cell sits beside. `weekly_all` is the kind the production
    /// decode reads for the weekly tier. Same `resets_at` as `makeUsage`, so a valid future
    /// session reset exists and the weekly gate is the only thing that can explain an empty
    /// countdown. The plan ratio is required: with none stored there is nothing to convert and
    /// the cap cannot fire at all.
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
        let usage = UsageData(from: response, planRatio: PlanRatio.max5x)
        // Assert the fixture really is weekly-limited, so the case cannot silently rot into
        // testing nothing if the gate's shape moves.
        XCTAssertEqual(usage.sessionResetDate, resetDate)
        XCTAssertTrue(usage.isSessionWeeklyLimited)
        return usage
    }

    /// The same two-limit shape and the same plan ratio, with a HEALTHY weekly (90 remaining),
    /// so the gate stays shut. The control for `makeWeeklyLimitedUsage`: proves the suppression
    /// is gated on the weekly limit binding rather than on merely having a weekly limit in the
    /// response.
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
        let usage = UsageData(from: response, planRatio: PlanRatio.max5x)
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
        let title = MenuBarController.countdownCell(
            usage: usage, enabled: true, now: now(secondsBeforeReset: 4 * 3600 + 20 * 60)
        )
        XCTAssertEqual(title.text, "4h+")
    }

    func testEnabled_thirtyTwoMinutesOut_isMinutes() throws {
        let usage = try makeUsage()
        let title = MenuBarController.countdownCell(
            usage: usage, enabled: true, now: now(secondsBeforeReset: 32 * 60)
        )
        XCTAssertEqual(title.text, "32m")
    }

    func testEnabled_fortySecondsOut_isLessThanAMinute() throws {
        let usage = try makeUsage()
        let title = MenuBarController.countdownCell(
            usage: usage, enabled: true, now: now(secondsBeforeReset: 40)
        )
        XCTAssertEqual(title.text, "<1m")
    }

    func testEnabled_nilSessionResetDate_isEmpty() throws {
        let usage = try makeUsageWithoutSessionReset()
        let title = MenuBarController.countdownCell(usage: usage, enabled: true, now: now(secondsBeforeReset: 600))
        XCTAssertEqual(title.text, "")
    }

    func testEnabled_nilUsage_isEmpty() {
        let title = MenuBarController.countdownCell(usage: nil, enabled: true, now: resetDate)
        XCTAssertEqual(title.text, "")
    }

    func testDisabled_isEmptyDespiteValidResetDate() throws {
        let usage = try makeUsage()
        let title = MenuBarController.countdownCell(
            usage: usage, enabled: false, now: now(secondsBeforeReset: 32 * 60)
        )
        XCTAssertEqual(title.text, "")
    }

    func testEnabled_pastResetDate_isEmpty() throws {
        let usage = try makeUsage()
        // now AFTER the reset -> non-positive countdown -> "" (never traps, never misleads).
        let title = MenuBarController.countdownCell(
            usage: usage, enabled: true, now: now(secondsBeforeReset: -60)
        )
        XCTAssertEqual(title.text, "")
    }

    /// The countdown is deliberately NOT suppressed while the weekly limit binds. Suppressing it
    /// was implemented and then reverted: it took the reset time away in the state where users
    /// most want it. The known cost is locked here rather than left implicit - the pill beside
    /// this cell shows the weekly quota, so this clock runs out without that number changing.
    /// A future "consistency" change that empties the cell here has to overturn that decision.
    func testEnabled_weeklyLimited_stillReturnsTheSessionCountdown() throws {
        let usage = try makeWeeklyLimitedUsage()
        let title = MenuBarController.countdownCell(
            usage: usage, enabled: true, now: now(secondsBeforeReset: 32 * 60)
        )
        XCTAssertEqual(title.text, "32m")
    }

    func testEnabled_weeklyHealthy_stillReturnsCountdown() throws {
        let usage = try makeWeeklyHealthyUsage()
        // The control: same two-limit shape with the gate shut. Together with the case above this
        // pins that the cell is indifferent to the weekly gate, in both directions.
        let title = MenuBarController.countdownCell(
            usage: usage, enabled: true, now: now(secondsBeforeReset: 32 * 60)
        )
        XCTAssertEqual(title.text, "32m")
    }

    func testDefaultFixture_withNoWeeklyLimit_isNotWeeklyLimited() throws {
        let usage = try makeUsage()
        // An absent weekly entry decodes to 100 remaining, which never binds. Keeps the two cases
        // above honest: their difference really is the weekly gate and not the fixture shape.
        XCTAssertEqual(usage.weeklyRemaining, 100)
        XCTAssertFalse(usage.isSessionWeeklyLimited)
    }

    func testSessionCountdown_isAlwaysNeutral() throws {
        // The session timer keeps its plain look, so its images are unchanged by the tone.
        let usage = try makeWeeklyLimitedUsage()
        let cell = MenuBarController.countdownCell(usage: usage, enabled: true, now: now(secondsBeforeReset: 32 * 60))
        XCTAssertEqual(cell.tone, .neutral)
    }

    // MARK: - No 5-hour limit: the cell shows the weekly run-out estimate

    /// An account with no 5-hour limit, `weeklyLeft` percent of the week remaining, and the weekly
    /// reset at `resetEpoch`.
    private func makeWeeklyOnlyUsage(weeklyLeft: Double) throws -> UsageData {
        let json = """
        {
          "five_hour": null,
          "limits": [
            { "kind": "weekly_all", "percent": \(100 - weeklyLeft), "resets_at": \(Int(resetEpoch)) }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let usage = UsageData(from: try decoder.decode(UsageResponse.self, from: Data(json.utf8)))
        XCTAssertFalse(usage.hasSessionLimit)
        XCTAssertEqual(usage.weeklyResetDate, resetDate)
        return usage
    }

    /// What the popover's Weekly dial prints for the same snapshot and clock.
    private func weeklyDial(weeklyLeft: Double, at now: Date) -> UsagePopoverView.DialLines {
        let window = UsagePopoverView.weeklyWindow
        let pace = UsagePopoverView.paceStatus(remainingPercent: weeklyLeft, resetsAt: resetDate,
                                               window: window, now: now)
        return UsagePopoverView.dialLines(pace: pace, rawRemaining: weeklyLeft, resetsAt: resetDate,
                                          window: window, now: now)
    }

    func testNoSessionLimit_caution_showsTheDialsRunOutInOrange() throws {
        let at = now(secondsBeforeReset: 72 * 3600)
        let cell = MenuBarController.countdownCell(usage: try makeWeeklyOnlyUsage(weeklyLeft: 25), enabled: true, now: at)
        XCTAssertEqual(cell.text, "32h")
        XCTAssertEqual(cell.tone, .caution)

        let dial = weeklyDial(weeklyLeft: 25, at: at)
        XCTAssertEqual(dial.runOutSeconds, 32 * 3600)
        XCTAssertEqual(dial.runOut, "Out in ~1d 08h")
    }

    func testNoSessionLimit_cautionUnderTheTwentyPercentFloor_isRed() throws {
        // The popover paints the pace word red below 20% left whatever the pace says, and the cell
        // follows it so the two surfaces never disagree about how bad things are.
        let at = now(secondsBeforeReset: 39 * 3600)
        let cell = MenuBarController.countdownCell(usage: try makeWeeklyOnlyUsage(weeklyLeft: 10), enabled: true, now: at)
        XCTAssertEqual(cell.text, "14h")
        XCTAssertEqual(cell.tone, .danger)

        let dial = weeklyDial(weeklyLeft: 10, at: at)
        XCTAssertEqual(dial.caption, "Caution")
        XCTAssertEqual(dial.runOutSeconds, 14 * 3600)
        XCTAssertEqual(dial.runOut, "Out in ~14h")
    }

    func testNoSessionLimit_danger_isRedAndMatchesTheDial() throws {
        let at = now(secondsBeforeReset: 100 * 3600)
        let cell = MenuBarController.countdownCell(usage: try makeWeeklyOnlyUsage(weeklyLeft: 5), enabled: true, now: at)
        XCTAssertEqual(cell.text, "4h")
        XCTAssertEqual(cell.tone, .danger)
        XCTAssertEqual(weeklyDial(weeklyLeft: 5, at: at).runOutSeconds, 4 * 3600)
    }

    func testNoSessionLimit_onTrack_showsNoCell() throws {
        let cell = MenuBarController.countdownCell(usage: try makeWeeklyOnlyUsage(weeklyLeft: 60), enabled: true,
                                                   now: now(secondsBeforeReset: 72 * 3600))
        XCTAssertEqual(cell, .none)
    }

    func testNoSessionLimit_weekUsedUp_showsNoCell() throws {
        let cell = MenuBarController.countdownCell(usage: try makeWeeklyOnlyUsage(weeklyLeft: 0), enabled: true,
                                                   now: now(secondsBeforeReset: 39 * 3600))
        XCTAssertEqual(cell, .none)
    }

    func testNoSessionLimit_tooEarlyInTheWeekToProject_showsNoCell() throws {
        // Heavy use eight hours into the week is Danger, but the dial projects nothing that early,
        // so neither does the menu bar.
        let at = now(secondsBeforeReset: 160 * 3600)
        let cell = MenuBarController.countdownCell(usage: try makeWeeklyOnlyUsage(weeklyLeft: 50), enabled: true, now: at)
        XCTAssertEqual(cell, .none)
        XCTAssertNil(weeklyDial(weeklyLeft: 50, at: at).runOutSeconds)
    }

    /// The popover grades the Weekly dial's pace once per poll and only re-prints the durations on
    /// its minute clock, so the cell must grade the pace at the poll too. Here the week sits right on
    /// the Caution line at the poll (time 40.005% left against 30% usage left) and slips below it a
    /// minute later, before the next poll.
    func testNoSessionLimit_paceStaysAsGradedAtThePoll_untilTheNextPoll() throws {
        let polledAt = now(secondsBeforeReset: 241_950)
        let minuteLater = polledAt.addingTimeInterval(60)
        let usage = try makeWeeklyOnlyUsage(weeklyLeft: 30)

        let window = UsagePopoverView.weeklyWindow
        let pace = UsagePopoverView.paceStatus(remainingPercent: 30, resetsAt: resetDate, window: window, now: polledAt)
        XCTAssertEqual(pace, .caution)
        XCTAssertEqual(UsagePopoverView.paceStatus(remainingPercent: 30, resetsAt: resetDate, window: window,
                                                   now: minuteLater), .onTrack, "the fixture must cross the line")
        let dial = UsagePopoverView.dialLines(pace: pace, rawRemaining: 30, resetsAt: resetDate,
                                              window: window, now: minuteLater)

        let cell = MenuBarController.countdownCell(usage: usage, enabled: true, now: minuteLater, paceGradedAt: polledAt)
        XCTAssertEqual(cell.text, "43h")
        XCTAssertEqual(cell.tone, .caution)
        XCTAssertEqual(dial.runOutSeconds, 43 * 3600)
    }

    func testNoSessionLimit_disabled_showsNoCell() throws {
        let cell = MenuBarController.countdownCell(usage: try makeWeeklyOnlyUsage(weeklyLeft: 25), enabled: false,
                                                   now: now(secondsBeforeReset: 72 * 3600))
        XCTAssertEqual(cell, .none)
    }

    // MARK: - Version menu title (#48)

    /// The right-click menu's first item is a disabled "Claude Battery v1.70". Only the title
    /// mapping is tested; a nil title means the item is omitted from the menu.
    func testVersionMenuTitle_prefixesAppName() {
        XCTAssertEqual(MenuBarController.versionMenuTitle("1.70"), "Claude Battery v1.70")
    }

    func testVersionMenuTitle_nil_isNil() {
        XCTAssertNil(MenuBarController.versionMenuTitle(nil))
    }

    func testVersionMenuTitle_empty_isNil() {
        XCTAssertNil(MenuBarController.versionMenuTitle(""))
    }

    // MARK: - PopoverClock (KTD10: one clock, started and stopped by the popover show/close hooks)

    /// The clock `MenuBarController.popoverWillShow` starts and `popoverDidClose` stops. Only the
    /// clock is testable here (the controller needs a live status item); the two hooks are one-line
    /// forwards to `start()` and `stop()`.
    @MainActor
    func testPopoverClock_startRefreshesNowTicksAndStopEndsTicks() async {
        let clock = PopoverClock(interval: 0.05, now: .distantPast)
        XCTAssertFalse(clock.isRunning)
        XCTAssertEqual(clock.now, .distantPast)

        // start() refreshes `now` at once (the popover must open on the current minute, not the
        // minute it last closed on) and arms the timer.
        clock.start()
        XCTAssertTrue(clock.isRunning)
        XCTAssertLessThan(abs(clock.now.timeIntervalSinceNow), 5)
        let atStart = clock.now

        let ticked = expectation(description: "tick")
        ticked.assertForOverFulfill = false
        let tickSink = clock.$now.dropFirst().sink { _ in ticked.fulfill() }
        await fulfillment(of: [ticked], timeout: 2)
        tickSink.cancel()
        XCTAssertGreaterThan(clock.now, atStart)

        // A second start() is a no-op on the timer (one clock, not two).
        clock.start()
        XCTAssertTrue(clock.isRunning)

        clock.stop()
        XCTAssertFalse(clock.isRunning)
        let silent = expectation(description: "no tick after stop")
        silent.isInverted = true
        let silentSink = clock.$now.dropFirst().sink { _ in silent.fulfill() }
        await fulfillment(of: [silent], timeout: 0.3)
        silentSink.cancel()
    }

    @MainActor
    func testPopoverClock_stopWithoutStartIsHarmless() {
        let clock = PopoverClock(interval: 0.05)
        clock.stop()
        XCTAssertFalse(clock.isRunning)
    }
}
