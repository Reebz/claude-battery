import SwiftUI
import XCTest
@testable import ClaudeBattery

/// The one-account "Add another account" link in the popover (#53 follow-up). With macOS Keyboard
/// navigation on, AppKit handed that link keyboard focus every time the popover opened, so it carried
/// a blue focus ring on every open. A view that always accepts focus stands in for the link here: it
/// takes focus on open with Keyboard navigation off too, so these tests mean the same thing on any
/// machine.
@MainActor
final class AddAccountLinkTests: XCTestCase {
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private struct FocusableStandIn: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { FocusableView() }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private var anchor: NSWindow?
    private var popover: NSPopover?

    override func tearDown() {
        popover?.close()
        popover = nil
        anchor?.orderOut(nil)
        anchor?.close()
        anchor = nil
        super.tearDown()
    }

    /// A popover holding one focusable view, or a text field, on a small offscreen anchor window.
    private func makePopover(textField: Bool = false) -> (NSPopover, NSView) {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 40, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        anchor = window
        let popover = NSPopover()
        popover.behavior = .transient
        if textField {
            popover.contentViewController = NSHostingController(
                rootView: TextField("", text: .constant("")).frame(width: 200)
            )
        } else {
            popover.contentViewController = NSHostingController(
                rootView: FocusableStandIn().frame(width: 200, height: 30)
            )
        }
        self.popover = popover
        return (popover, window.contentView!)
    }

    private func spin(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func firstResponder(of popover: NSPopover) -> NSResponder? {
        popover.contentViewController?.view.window?.firstResponder
    }

    /// Guards the stand-in: if a plain show stopped focusing the field, the test below would pass
    /// without proving anything.
    func testPlainShow_focusesTheFirstControl() {
        let (popover, view) = makePopover()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        spin()
        XCTAssertTrue(firstResponder(of: popover) is FocusableView,
                      "a plain show should hand the stand-in focus, got \(String(describing: firstResponder(of: popover)))")
    }

    func testPresent_opensWithNothingFocused_soNoStaleFocusRingShows() {
        let (popover, view) = makePopover()
        MenuBarController.present(popover, relativeTo: view.bounds, of: view)
        spin()
        let window = popover.contentViewController?.view.window
        XCTAssertNotNil(window)
        XCTAssertFalse(firstResponder(of: popover) is FocusableView,
                       "the popover opened with a control focused, so its focus ring shows on every open")
        XCTAssertTrue(firstResponder(of: popover) === window)
    }

    /// The nickname field is the popover's only text field. A rename left open when the popover
    /// closed has to still take typing when it reopens.
    func testPresent_leavesAFocusedTextFieldAlone() {
        let (popover, view) = makePopover(textField: true)
        MenuBarController.present(popover, relativeTo: view.bounds, of: view)
        spin()
        XCTAssertTrue(firstResponder(of: popover) is NSText,
                      "the text field lost focus on open, got \(String(describing: firstResponder(of: popover)))")
    }

    /// Clearing focus must not strand keyboard users: Tab still has to move focus into the popover.
    func testPresent_tabStillMovesFocusIn() {
        let (popover, view) = makePopover()
        MenuBarController.present(popover, relativeTo: view.bounds, of: view)
        spin()
        popover.contentViewController?.view.window?.selectNextKeyView(nil)
        spin(0.1)
        XCTAssertTrue(firstResponder(of: popover) is FocusableView,
                      "Tab after opening should focus the first control, got \(String(describing: firstResponder(of: popover)))")
    }
}
