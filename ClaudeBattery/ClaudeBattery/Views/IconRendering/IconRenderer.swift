import AppKit

protocol IconRenderer {
    func makeUnauthenticatedIcon(color: NSColor) -> NSImage
    func makeStatusIcon(text: String, color: NSColor, alpha: CGFloat) -> NSImage
    func makeBatteryIcon(usage: UsageData, color: NSColor) -> NSImage
}
