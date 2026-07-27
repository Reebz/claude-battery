import AppKit

struct TextOnlyRenderer: IconRenderer {

    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private let separatorFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .light)
    private let iconHeight: CGFloat = 18

    private func makeTextIcon(session: String, weekly: String, alpha: CGFloat = 1.0, color: NSColor) -> NSImage {
        let tintedColor = color.withAlphaComponent(alpha)
        let numAttrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: tintedColor]
        let sepAttrs: [NSAttributedString.Key: Any] = [.font: separatorFont,
                                                        .foregroundColor: tintedColor.withAlphaComponent(0.5)]
        let sessionStr = session as NSString
        let weeklyStr = weekly as NSString
        let sep = "|" as NSString
        let sessionSize = sessionStr.size(withAttributes: numAttrs)
        let weeklySize = weeklyStr.size(withAttributes: numAttrs)
        let sepSize = sep.size(withAttributes: sepAttrs)
        let gap: CGFloat = 2
        let totalWidth = sessionSize.width + gap + sepSize.width + gap + weeklySize.width

        let image = NSImage(size: NSSize(width: totalWidth, height: iconHeight), flipped: false) { _ in
            let baseline = (iconHeight - sessionSize.height) / 2
            sessionStr.draw(at: NSPoint(x: 0, y: baseline), withAttributes: numAttrs)
            sep.draw(at: NSPoint(x: sessionSize.width + gap, y: (iconHeight - sepSize.height) / 2), withAttributes: sepAttrs)
            weeklyStr.draw(at: NSPoint(x: sessionSize.width + gap + sepSize.width + gap, y: baseline), withAttributes: numAttrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    func makeUnauthenticatedIcon(color: NSColor) -> NSImage {
        makeTextIcon(session: "--", weekly: "--", alpha: 0.4, color: color)
    }

    func makeStatusIcon(text: String, color: NSColor, alpha: CGFloat) -> NSImage {
        let tintedColor = color.withAlphaComponent(alpha)
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: tintedColor]
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        let image = NSImage(size: NSSize(width: size.width, height: iconHeight), flipped: false) { _ in
            str.draw(at: NSPoint(x: 0, y: (iconHeight - size.height) / 2), withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    func makeBatteryIcon(usage: UsageData, color: NSColor) -> NSImage {
        makeTextIcon(session: "\(Int(usage.sessionDisplayRemaining.rounded(.toNearestOrEven)))",
                     weekly: "\(Int(usage.weeklyRemaining.rounded(.toNearestOrEven)))",
                     color: color)
    }
}
