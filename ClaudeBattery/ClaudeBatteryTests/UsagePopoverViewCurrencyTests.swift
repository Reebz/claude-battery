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

/// Locks the pure show/hide rule and copy for the top update banner. The banner replaced the
/// footer link, which was easy to miss; the tinted full-width row is SwiftUI, only the resolved
/// content is unit-tested.
final class UsagePopoverViewUpdateBannerTests: XCTestCase {
    private let downloadURL = URL(string: "https://github.com/Reebz/claude-battery/releases/tag/v1.61")!

    func testNoUpdate_bothNil_hidesBanner() {
        XCTAssertNil(UsagePopoverView.updateBannerContent(availableVersion: nil, downloadURL: nil))
    }

    func testVersionWithoutURL_hidesBanner() {
        XCTAssertNil(UsagePopoverView.updateBannerContent(availableVersion: "1.61", downloadURL: nil))
    }

    func testURLWithoutVersion_hidesBanner() {
        XCTAssertNil(UsagePopoverView.updateBannerContent(availableVersion: nil, downloadURL: downloadURL))
    }

    func testUpdateAvailable_composesTitleAndCarriesURL() {
        let banner = UsagePopoverView.updateBannerContent(availableVersion: "1.61", downloadURL: downloadURL)

        XCTAssertEqual(banner?.title, "v1.61 available - Download")
        // Keeps the visible "Download" so Voice Control still matches the word on the button.
        XCTAssertEqual(banner?.spokenLabel, "Version 1.61 available, Download")
        XCTAssertEqual(banner?.url, downloadURL)
    }

    func testTitle_addsVPrefixOnce_forThreeSegmentVersion() {
        // UpdateChecker publishes the bare number (it strips any leading v), so the view adds it.
        let banner = UsagePopoverView.updateBannerContent(availableVersion: "99.1.2", downloadURL: downloadURL)
        XCTAssertEqual(banner?.title, "v99.1.2 available - Download")
    }

    func testTitle_usesHyphenNotEmDash() {
        // The old footer string carried a real em dash; the banner copy must not reintroduce it.
        let banner = UsagePopoverView.updateBannerContent(availableVersion: "1.61", downloadURL: downloadURL)
        XCTAssertFalse(banner?.title.contains("\u{2014}") ?? true, "got `\(banner?.title ?? "nil")`")
    }
}
