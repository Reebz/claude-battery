import XCTest
@testable import ClaudeBattery

/// Locks the U6 targeted-KVO accessor for the session-countdown toggle. The SwiftUI
/// `@AppStorage` binding and the `@objc dynamic var` accessor share one key constant
/// (`MenuBarDefaults.showSessionCountdownKey`) so they cannot drift; these tests assert the
/// accessor tracks that key and defaults to false. A dedicated suite keeps real user defaults
/// untouched.
final class SettingsCountdownToggleTests: XCTestCase {
    private let suiteName = "SettingsCountdownToggleTests.suite"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultIsFalseWhenUnset() {
        XCTAssertFalse(defaults.showSessionCountdown)
    }

    func testAccessorReflectsStoredTrue() {
        defaults.set(true, forKey: MenuBarDefaults.showSessionCountdownKey)
        XCTAssertTrue(defaults.showSessionCountdown)
    }

    func testAccessorReflectsClearedKey() {
        defaults.set(true, forKey: MenuBarDefaults.showSessionCountdownKey)
        XCTAssertTrue(defaults.showSessionCountdown)
        defaults.removeObject(forKey: MenuBarDefaults.showSessionCountdownKey)
        XCTAssertFalse(defaults.showSessionCountdown)
    }
}
