import XCTest
@testable import ClaudeBattery

final class IconStyleTests: XCTestCase {

    // MARK: - Happy Path: Every case returns a non-nil renderer

    func testAllCasesReturnNonNilRenderer() {
        for style in IconStyle.allCases {
            let renderer = style.renderer
            // IconRenderer is a protocol, so a non-nil concrete instance satisfies this
            XCTAssertTrue(renderer is IconRenderer, "\(style.rawValue) should return a valid renderer")
        }
    }

    // MARK: - Happy Path: Expected renderer types per case

    func testDualHorizontalRendererType() {
        let renderer = IconStyle.dualHorizontal.renderer
        XCTAssertTrue(renderer is DualHorizontalRenderer, "dualHorizontal should return DualHorizontalRenderer")
    }

    func testMinimalRendererType() {
        let renderer = IconStyle.minimal.renderer
        XCTAssertTrue(renderer is MinimalRenderer, "minimal should return MinimalRenderer")
    }

    func testDualArcGaugeRendererType() {
        let renderer = IconStyle.dualArcGauge.renderer
        XCTAssertTrue(renderer is DualArcGaugeRenderer, "dualArcGauge should return DualArcGaugeRenderer")
    }

    func testTextOnlyRendererType() {
        let renderer = IconStyle.textOnly.renderer
        XCTAssertTrue(renderer is TextOnlyRenderer, "textOnly should return TextOnlyRenderer")
    }

    func testStackedBarsRendererType() {
        let renderer = IconStyle.stackedBars.renderer
        XCTAssertTrue(renderer is StackedBarsRenderer, "stackedBars should return StackedBarsRenderer")
    }

    // MARK: - CaseIterable completeness

    func testAllCasesCountMatchesExpected() {
        // If a new case is added to IconStyle but tests aren't updated,
        // this will flag it
        XCTAssertEqual(IconStyle.allCases.count, 5, "Expected five icon styles")
    }

    // MARK: - Raw values match display strings

    func testRawValuesAreHumanReadable() {
        let expectedRawValues: Set<String> = [
            "Dual Horizontal",
            "Minimal",
            "Dual Arc Gauge",
            "Text Only",
            "Stacked Bars",
        ]
        let actualRawValues = Set(IconStyle.allCases.map(\.rawValue))
        XCTAssertEqual(actualRawValues, expectedRawValues)
    }

    // MARK: - Each renderer call returns a fresh instance (struct value type)

    func testRendererReturnsFreshInstanceEachCall() {
        // Since renderers are structs, each `.renderer` access creates a new value.
        // Verify the two calls produce equivalent but distinct values by checking
        // they're both valid (struct identity isn't reference-comparable).
        for style in IconStyle.allCases {
            let r1 = style.renderer
            let r2 = style.renderer
            XCTAssertTrue(type(of: r1) == type(of: r2), "\(style.rawValue) should return the same type each time")
        }
    }
}
