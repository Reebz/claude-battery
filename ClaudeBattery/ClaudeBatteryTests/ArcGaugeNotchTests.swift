import XCTest
@testable import ClaudeBattery

/// Locks the pure gauge-notch geometry (U6). The visual stroke itself is not unit-tested.
final class ArcGaugeNotchTests: XCTestCase {
    func testSessionFractions_fourInteriorTicks() {
        let fractions = GaugeTicks.fractions(count: 5)
        XCTAssertEqual(fractions.count, 4)
        zip(fractions, [0.2, 0.4, 0.6, 0.8]).forEach { actual, expected in
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
    }

    func testWeeklyFractions_sixInteriorTicks() {
        let fractions = GaugeTicks.fractions(count: 7)
        XCTAssertEqual(fractions.count, 6)
        zip(fractions, (1...6).map { Double($0) / 7.0 }).forEach { actual, expected in
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
    }

    func testAngleMapping() {
        XCTAssertEqual(GaugeTicks.angle(fraction: 0.2), 189, accuracy: 1e-9)  // 135 + 270*0.2
        XCTAssertEqual(GaugeTicks.angle(fraction: 0.0), 135, accuracy: 1e-9)
        XCTAssertEqual(GaugeTicks.angle(fraction: 1.0), 405, accuracy: 1e-9)
    }

    func testCountBelowTwo_hasNoTicks() {
        XCTAssertTrue(GaugeTicks.fractions(count: 1).isEmpty)
        XCTAssertTrue(GaugeTicks.fractions(count: 0).isEmpty)
    }
}
