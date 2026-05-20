import XCTest
@testable import ClaudeBattery

final class UsagePopoverViewCurrencyTests: XCTestCase {
    func testFormatterPinsUSDUnderRussianLocale() {
        let formatter = UsagePopoverView.makeUSDCurrencyFormatter(
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
}
