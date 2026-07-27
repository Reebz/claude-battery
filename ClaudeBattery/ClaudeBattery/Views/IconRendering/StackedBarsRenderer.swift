import AppKit

struct StackedBarsRenderer: IconRenderer {

    private let barWidth: CGFloat = 28
    private let barHeight: CGFloat = 4
    private let gap: CGFloat = 3
    private let iconHeight: CGFloat = 18

    private func makeBarsIcon(sessionFraction: CGFloat, weeklyFraction: CGFloat,
                              sessionLow: Bool, weeklyLow: Bool,
                              alpha: CGFloat = 1.0, color: NSColor) -> NSImage {
        let baseColor = color.withAlphaComponent(alpha)
        let trackColor = baseColor.withAlphaComponent(0.18)
        let topBarY = (iconHeight + gap) / 2          // session bar (top)
        let bottomBarY = (iconHeight - gap) / 2 - barHeight  // weekly bar (bottom)

        let image = NSImage(size: NSSize(width: barWidth, height: iconHeight), flipped: false) { _ in
            // Tracks
            trackColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: topBarY, width: barWidth, height: barHeight), xRadius: 2, yRadius: 2).fill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: bottomBarY, width: barWidth, height: barHeight), xRadius: 2, yRadius: 2).fill()

            // Session fill (top bar)
            let sessionFillWidth = barWidth * max(sessionFraction, 0)
            if sessionFillWidth > 0 {
                let fillColor: NSColor = sessionLow ? .red : baseColor
                fillColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: topBarY, width: sessionFillWidth, height: barHeight), xRadius: 2, yRadius: 2).fill()
            }

            // Weekly fill (bottom bar)
            let weeklyFillWidth = barWidth * max(weeklyFraction, 0)
            if weeklyFillWidth > 0 {
                let fillColor: NSColor = weeklyLow ? .red : baseColor
                fillColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: bottomBarY, width: weeklyFillWidth, height: barHeight), xRadius: 2, yRadius: 2).fill()
            }

            return true
        }
        image.isTemplate = false
        return image
    }

    func makeUnauthenticatedIcon(color: NSColor) -> NSImage {
        makeBarsIcon(sessionFraction: 0, weeklyFraction: 0,
                     sessionLow: false, weeklyLow: false,
                     alpha: 0.4, color: color)
    }

    func makeStatusIcon(text: String, color: NSColor, alpha: CGFloat) -> NSImage {
        makeBarsIcon(sessionFraction: 0, weeklyFraction: 0,
                     sessionLow: false, weeklyLow: false,
                     alpha: alpha, color: color)
    }

    func makeBatteryIcon(usage: UsageData, color: NSColor) -> NSImage {
        makeBarsIcon(sessionFraction: CGFloat(usage.sessionDisplayRemaining) / 100.0,
                     weeklyFraction: CGFloat(usage.weeklyRemaining) / 100.0,
                     sessionLow: usage.sessionDisplayRemaining < 20,
                     weeklyLow: usage.weeklyRemaining < 20,
                     color: color)
    }
}
