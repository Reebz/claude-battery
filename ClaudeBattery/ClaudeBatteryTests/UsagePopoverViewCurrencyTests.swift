import XCTest
import SwiftUI
@testable import ClaudeBattery

final class UsagePopoverViewCurrencyTests: XCTestCase {
    func testFormatterPinsUSDUnderRussianLocale() {
        let formatter = UsagePopoverView.makeCurrencyFormatter(
            code: "USD",
            locale: Locale(identifier: "ru_RU")
        )

        let formatted = formatter.string(from: NSNumber(value: 0.74)) ?? ""

        XCTAssertTrue(
            formatted.contains("$"),
            "Expected USD `$` symbol under ru_RU locale, got `\(formatted)`"
        )
        XCTAssertFalse(
            formatted.contains("RUB"),
            "Expected no ruble currency code under ru_RU locale, got `\(formatted)`"
        )
        XCTAssertFalse(
            formatted.contains("\u{20BD}"),
            "Expected no ruble symbol under ru_RU locale, got `\(formatted)`"
        )
    }

    func testFormatterUsesAUDCodeUnderUSLocale() {
        // KTD6: an AUD account must render in AUD even under a US locale, not as plain USD.
        let formatter = UsagePopoverView.makeCurrencyFormatter(
            code: "AUD",
            locale: Locale(identifier: "en_US")
        )
        let formatted = formatter.string(from: NSNumber(value: 71.52)) ?? ""

        XCTAssertEqual(formatter.currencyCode, "AUD")
        XCTAssertTrue(
            formatted.contains("A$") || formatted.contains("AUD"),
            "Expected an AUD rendering, got `\(formatted)`"
        )
        XCTAssertTrue(formatted.contains("71.52"), "Expected the amount, got `\(formatted)`")
    }

    func testEmptyCodeFallsBackToUSD() {
        XCTAssertEqual(UsagePopoverView.makeCurrencyFormatter(code: "").currencyCode, "USD")
        XCTAssertEqual(UsagePopoverView.makeCurrencyFormatter().currencyCode, "USD")
    }
}

final class UsageCreditsSectionTests: XCTestCase {
    func testDisabledReasonMapsToPausedText() {
        XCTAssertEqual(
            UsagePopoverView.usageCreditsDisabledText(reason: "org_level_disabled_until", resetDate: nil),
            "Paused - monthly limit reached"
        )
    }

    func testUnknownDisabledReasonFallsBackToPaused() {
        XCTAssertEqual(
            UsagePopoverView.usageCreditsDisabledText(reason: "something_else", resetDate: nil),
            "Paused"
        )
    }

    func testDisabledText_withResetDate_includesResets() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let reset = cal.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let text = UsagePopoverView.usageCreditsDisabledText(reason: "org_level_disabled_until", resetDate: reset)
        XCTAssertTrue(text.hasPrefix("Paused - monthly limit reached, resets "), "got `\(text)`")
        XCTAssertTrue(text.contains("2026"), "got `\(text)`")
    }

    func testFirstOfNextMonth_rollsToFirstDayOfNextMonth() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let jan15 = cal.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9))!
        let comps = cal.dateComponents([.year, .month, .day],
                                       from: UsagePopoverView.firstOfNextMonth(after: jan15, calendar: cal))
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 2)
        XCTAssertEqual(comps.day, 1)
    }

    func testFirstOfNextMonth_decemberRollsToJanuaryNextYear() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let dec20 = cal.date(from: DateComponents(year: 2026, month: 12, day: 20))!
        let comps = cal.dateComponents([.year, .month, .day],
                                       from: UsagePopoverView.firstOfNextMonth(after: dec20, calendar: cal))
        XCTAssertEqual(comps.year, 2027)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 1)
    }
}

final class UsagePopoverViewBatteryColorTests: XCTestCase {
    // Thresholds: red < 20, orange < 45, green otherwise (U7).
    func testHighRemainingIsGreen() {
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 75), .green)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 100), .green)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 46), .green)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 45), .green)  // boundary
    }

    func testMidRemainingIsOrange() {
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 30), .orange)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 44), .orange)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 20), .orange)  // boundary
    }

    func testLowRemainingIsRed() {
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 5), .red)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 0), .red)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 19.9), .red)
    }

    func testNegativeRemainingClampsToRed() {
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: -5), .red)
    }

    func testOverflowRemainingClampsToGreen() {
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 150), .green)
    }
}
