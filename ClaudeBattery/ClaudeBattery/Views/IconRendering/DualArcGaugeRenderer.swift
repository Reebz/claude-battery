import AppKit

struct DualArcGaugeRenderer: IconRenderer {

    private let iconSize: CGFloat = 20
    private let outerRadius: CGFloat = 8
    private let innerRadius: CGFloat = 5
    private let lineWidth: CGFloat = 2.5
    private let startAngle: CGFloat = 225   // bottom-left (degrees, counterclockwise from east)
    private let sweep: CGFloat = 270        // 270-degree sweep clockwise

    private let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    /// Draws a single arc track + fill.
    private func drawArc(center: NSPoint, radius: CGFloat, fraction: CGFloat,
                         trackColor: NSColor, fillColor: NSColor) {
        let endDeg = startAngle - sweep

        // Background track
        trackColor.setStroke()
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius,
                        startAngle: startAngle, endAngle: endDeg, clockwise: true)
        track.lineWidth = lineWidth
        track.lineCapStyle = .round
        track.stroke()

        // Filled portion
        if fraction > 0 {
            fillColor.setStroke()
            let fillEnd = startAngle - sweep * fraction
            let fill = NSBezierPath()
            fill.appendArc(withCenter: center, radius: radius,
                           startAngle: startAngle, endAngle: fillEnd, clockwise: true)
            fill.lineWidth = lineWidth
            fill.lineCapStyle = .round
            fill.stroke()
        }
    }

    func makeUnauthenticatedIcon(color: NSColor) -> NSImage {
        let size = iconSize
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { [self] _ in
            let center = NSPoint(x: size / 2, y: size / 2)
            let trackColor = color.withAlphaComponent(0.15)
            drawArc(center: center, radius: outerRadius, fraction: 0,
                    trackColor: trackColor, fillColor: color)
            drawArc(center: center, radius: innerRadius, fraction: 0,
                    trackColor: trackColor, fillColor: color)
            return true
        }
        image.isTemplate = false
        return image
    }

    func makeStatusIcon(text: String, color: NSColor, alpha: CGFloat) -> NSImage {
        let size = iconSize
        let tintedColor = color.withAlphaComponent(alpha)
        let font = digitFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tintedColor]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let gap: CGFloat = 1
        let totalWidth = size + gap + textSize.width + 1

        let image = NSImage(size: NSSize(width: totalWidth, height: size), flipped: false) { [self] _ in
            let center = NSPoint(x: size / 2, y: size / 2)
            let trackColor = tintedColor.withAlphaComponent(0.15)
            drawArc(center: center, radius: outerRadius, fraction: 0,
                    trackColor: trackColor, fillColor: tintedColor)
            drawArc(center: center, radius: innerRadius, fraction: 0,
                    trackColor: trackColor, fillColor: tintedColor)

            (text as NSString).draw(
                at: NSPoint(x: size + gap, y: (size - textSize.height) / 2),
                withAttributes: attrs
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    func makeBatteryIcon(usage: UsageData, color: NSColor) -> NSImage {
        let weeklyPercent = usage.weeklyRemaining
        let sessionPercent = usage.sessionRemaining
        let size = iconSize
        let baseColor = color

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { [self] _ in
            let center = NSPoint(x: size / 2, y: size / 2)
            let trackColor = baseColor.withAlphaComponent(0.15)

            // Outer arc — weekly
            let weeklyFill: NSColor = weeklyPercent < 20 ? .red : baseColor
            drawArc(center: center, radius: outerRadius,
                    fraction: CGFloat(weeklyPercent) / 100.0,
                    trackColor: trackColor, fillColor: weeklyFill)

            // Inner arc — session
            let sessionFill: NSColor = sessionPercent < 20 ? .red : baseColor
            drawArc(center: center, radius: innerRadius,
                    fraction: CGFloat(sessionPercent) / 100.0,
                    trackColor: trackColor, fillColor: sessionFill)

            return true
        }
        image.isTemplate = false
        return image
    }
}
