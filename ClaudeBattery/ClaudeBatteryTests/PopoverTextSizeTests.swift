import SwiftUI
import XCTest
@testable import ClaudeBattery

/// Locks the popover text-scale arithmetic (R12, grew out of #53): the position-to-offset table, the
/// clamp that keeps a stale UserDefaults value inside it, the size floor, and the Settings caption
/// copy. All pure - this project has no view tests and this adds none.
final class PopoverTextSizeTests: XCTestCase {

    // MARK: - Offset table

    func testOffset_positions1through6_giveMinus3ThroughPlus2() {
        XCTAssertEqual(PopoverTextSize.offset(for: 1), -3)
        XCTAssertEqual(PopoverTextSize.offset(for: 2), -2)
        XCTAssertEqual(PopoverTextSize.offset(for: 3), -1)
        XCTAssertEqual(PopoverTextSize.offset(for: 4), 0)
        XCTAssertEqual(PopoverTextSize.offset(for: 5), 1)
        XCTAssertEqual(PopoverTextSize.offset(for: 6), 2)
    }

    func testDefaultPosition_isFour_andScalesNothing() {
        XCTAssertEqual(PopoverTextSize.defaultPosition, 4)
        XCTAssertEqual(PopoverTextSize.offset(for: PopoverTextSize.defaultPosition), 0)
        XCTAssertEqual(PopoverTextSize.positions, 1...6)
    }

    // MARK: - Clamping

    /// A stale or hand-edited UserDefaults value must land on a real position, not off the end of
    /// the table, so the popover can never draw a size the layout was not measured against.
    func testOffset_outOfRangePositions_clampToTheEnds() {
        XCTAssertEqual(PopoverTextSize.offset(for: 0), PopoverTextSize.offset(for: 1))
        XCTAssertEqual(PopoverTextSize.offset(for: -1), PopoverTextSize.offset(for: 1))
        XCTAssertEqual(PopoverTextSize.offset(for: 7), PopoverTextSize.offset(for: 6))
        XCTAssertEqual(PopoverTextSize.offset(for: 99), PopoverTextSize.offset(for: 6))
    }

    // MARK: - Size

    func testSize_appliesTheOffset_andFloorsAtOne() {
        XCTAssertEqual(PopoverTextSize.size(10, offset: -3), 7)
        XCTAssertEqual(PopoverTextSize.size(11, offset: 2), 13)
        XCTAssertEqual(PopoverTextSize.size(32, offset: -3), 29)
        // The smallest base in the popover is the 7pt centre clock glyph; a 1pt base at the
        // smallest position still has to come back as a drawable size.
        XCTAssertEqual(PopoverTextSize.size(1, offset: -3), 1)
    }

    // MARK: - Settings caption

    func testSettingsLabel_reportsTheCountdownLineSize() {
        XCTAssertEqual(PopoverTextSize.settingsLabel(for: 4), "Text size: 11pt")
        XCTAssertEqual(PopoverTextSize.settingsLabel(for: 1), "Text size: 8pt")
        XCTAssertEqual(PopoverTextSize.settingsLabel(for: 6), "Text size: 13pt")
        XCTAssertEqual(PopoverTextSize.settingsLabel(for: 9), "Text size: 13pt")
    }

    // MARK: - Stored key

    /// Renaming the key would silently reset every user's choice back to the default, so the
    /// literal is pinned here rather than only in the property.
    func testPositionKey_isTheStoredDefaultsKey() {
        XCTAssertEqual(PopoverTextSize.positionKey, "popoverTextSizePosition")
    }
}
