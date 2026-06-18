import XCTest
@testable import ClaudeBattery

/// Locks the pure text mapping for the combined Credits row (U5). The single-line layout
/// (status truncates, balance pinned) is SwiftUI; only the composed strings are unit-tested.
final class UsageCreditsRowTests: XCTestCase {
    func testDisabledReason_orgLevel_mapsToPausedMonthlyLimit() {
        XCTAssertEqual(
            UsagePopoverView.usageCreditsDisabledText(reason: "org_level_disabled_until", resetDate: nil),
            "Paused - monthly limit reached"
        )
    }

    func testEnabledStatus_composesSpentAndPercentUsed() {
        let status = UsagePopoverView.usageCreditsEnabledStatus(spentFormatted: "$12.00", percent: 60)
        XCTAssertEqual(status, "$12.00 spent · 60% used")
    }

    func testEnabledStatus_roundsPercent() {
        XCTAssertEqual(
            UsagePopoverView.usageCreditsEnabledStatus(spentFormatted: "$5.00", percent: 49.6),
            "$5.00 spent · 50% used"
        )
    }

    func testEnabledStatus_uncappedPercentOverHundred_preserved() {
        // KTD7: spend percent is uncapped; the status string carries it as-is (rounded).
        XCTAssertEqual(
            UsagePopoverView.usageCreditsEnabledStatus(spentFormatted: "A$205.13", percent: 103),
            "A$205.13 spent · 103% used"
        )
    }

    /// Each value formats in its OWN currency code (KTD6): a USD spend and an AUD balance must
    /// not collapse to one symbol. Pinned to a US locale so the divergence is deterministic.
    func testCurrencyDivergence_usdSpend_vsAudBalance_keepDistinctSymbols() {
        let locale = Locale(identifier: "en_US")
        let usd = UsagePopoverView.makeCurrencyFormatter(code: "USD", locale: locale)
        let aud = UsagePopoverView.makeCurrencyFormatter(code: "AUD", locale: locale)

        guard let usdString = usd.string(from: NSNumber(value: 12.00)),
              let audString = aud.string(from: NSNumber(value: 8.50)) else {
            XCTFail("currency formatters returned nil")
            return
        }

        // Under a US locale: USD renders the bare "$", AUD renders the disambiguated "A$".
        XCTAssertTrue(usdString.contains("$"), "USD missing $: \(usdString)")
        XCTAssertFalse(usdString.contains("A$"), "USD should not carry the AUD form: \(usdString)")
        XCTAssertTrue(audString.contains("A$"), "AUD missing A$ form: \(audString)")
        XCTAssertNotEqual(usdString, audString)

        // And the enabled status composes the USD-spent string verbatim (no currency leakage).
        XCTAssertEqual(
            UsagePopoverView.usageCreditsEnabledStatus(spentFormatted: usdString, percent: 60),
            "\(usdString) spent · 60% used"
        )
    }
}
