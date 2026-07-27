import AppKit

struct MinimalRenderer: IconRenderer {

    // Vertical battery geometry
    private let bodyWidth: CGFloat = 10
    private let bodyHeight: CGFloat = 14
    private let nubWidth: CGFloat = 5
    private let nubHeight: CGFloat = 2
    private let iconWidth: CGFloat = 14
    private let iconHeight: CGFloat = 18
    private let cornerRadius: CGFloat = 2.5

    private var bodyX: CGFloat { (iconWidth - bodyWidth) / 2 }
    private let bodyY: CGFloat = 1
    private var nubX: CGFloat { (iconWidth - nubWidth) / 2 }
    private var nubY: CGFloat { bodyY + bodyHeight }

    private let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    /// Draws the vertical battery outline + nub.
    private func drawBatteryShell(color: NSColor) {
        color.setStroke()
        let outline = NSBezierPath(roundedRect: NSRect(x: bodyX, y: bodyY,
                                                        width: bodyWidth, height: bodyHeight),
                                    xRadius: cornerRadius, yRadius: cornerRadius)
        outline.lineWidth = 1.0
        outline.stroke()

        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: nubX, y: nubY,
                                          width: nubWidth, height: nubHeight),
                      xRadius: 0.5, yRadius: 0.5).fill()
    }

    func makeUnauthenticatedIcon(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: iconWidth, height: iconHeight), flipped: false) { [self] _ in
            drawBatteryShell(color: color)
            return true
        }
        image.isTemplate = false
        return image
    }

    func makeStatusIcon(text: String, color: NSColor, alpha: CGFloat) -> NSImage {
        let font = digitFont
        let tintedColor = color.withAlphaComponent(alpha)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tintedColor]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let gap: CGFloat = 1
        let totalWidth = iconWidth + gap + textSize.width + 1

        let image = NSImage(size: NSSize(width: totalWidth, height: iconHeight), flipped: false) { [self] _ in
            drawBatteryShell(color: tintedColor)

            (text as NSString).draw(
                at: NSPoint(x: iconWidth + gap, y: (iconHeight - textSize.height) / 2),
                withAttributes: attrs
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    func makeBatteryIcon(usage: UsageData, color: NSColor) -> NSImage {
        let weeklyPercent = Int(usage.weeklyRemaining.rounded(.toNearestOrEven))
        let sessionPercent = Int(usage.sessionDisplayRemaining.rounded(.toNearestOrEven))
        let isSessionLow = usage.sessionDisplayRemaining < 20
        let isWeeklyLow = usage.weeklyRemaining < 20

        let fillInset: CGFloat = 1.5
        let dividerGap: CGFloat = 1.0

        let interiorWidth = bodyWidth - fillInset * 2
        let interiorHeight = bodyHeight - fillInset * 2
        let sectionHeight = (interiorHeight - dividerGap) / 2

        let bottomY = bodyY + fillInset                           // weekly section bottom
        let topY    = bottomY + sectionHeight + dividerGap        // session section bottom
        let dividerY = bottomY + sectionHeight + dividerGap / 2   // center of divider

        let baseColor = color

        let image = NSImage(size: NSSize(width: iconWidth, height: iconHeight), flipped: false) { [self] _ in
            // 1. Shell (outline + nub)
            drawBatteryShell(color: baseColor)

            let fillX = bodyX + fillInset

            // 2. Session fill (top section)
            let sessionFillHeight = sectionHeight * CGFloat(sessionPercent) / 100.0
            if sessionFillHeight > 0 {
                let fillColor: NSColor = isSessionLow ? .red : baseColor
                fillColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: fillX, y: topY,
                                                  width: interiorWidth, height: sessionFillHeight),
                              xRadius: 1, yRadius: 1).fill()
            }

            // 3. Horizontal divider
            baseColor.withAlphaComponent(0.3).setStroke()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: fillX, y: dividerY))
            divider.line(to: NSPoint(x: fillX + interiorWidth, y: dividerY))
            divider.lineWidth = 0.5
            divider.stroke()

            // 4. Weekly fill (bottom section)
            let weeklyFillHeight = sectionHeight * CGFloat(weeklyPercent) / 100.0
            if weeklyFillHeight > 0 {
                let fillColor: NSColor = isWeeklyLow ? .red : baseColor
                fillColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: fillX, y: bottomY,
                                                  width: interiorWidth, height: weeklyFillHeight),
                              xRadius: 1, yRadius: 1).fill()
            }

            return true
        }

        image.isTemplate = false
        return image
    }
}
