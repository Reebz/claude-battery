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

final class UsagePopoverViewBatteryColorTests: XCTestCase {
    func testHighRemainingIsGreen() {
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 75), .green)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 100), .green)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 50), .green)
    }

    func testMidRemainingIsOrange() {
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 30), .orange)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 20), .orange)
        XCTAssertEqual(UsagePopoverView.batteryColor(remainingPercent: 49), .orange)
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
