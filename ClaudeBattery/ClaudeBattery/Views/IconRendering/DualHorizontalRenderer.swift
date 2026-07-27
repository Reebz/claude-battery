import AppKit

struct DualHorizontalRenderer: IconRenderer {

    private let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    func makeUnauthenticatedIcon(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 34, height: 18), flipped: false) { _ in
            color.setStroke()
            let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 3, width: 30, height: 12), xRadius: 2, yRadius: 2)
            path.lineWidth = 1.0
            path.stroke()

            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 30, y: 5.5, width: 2, height: 5), xRadius: 0.5, yRadius: 0.5).fill()

            return true
        }
        image.isTemplate = false
        return image
    }

    func makeStatusIcon(text: String, color: NSColor, alpha: CGFloat) -> NSImage {
        let font = digitFont
        let tintedColor = color.withAlphaComponent(alpha)
        let image = NSImage(size: NSSize(width: 40, height: 18), flipped: false) { _ in
            tintedColor.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 0, y: 3, width: 30, height: 12), xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.0
            outline.stroke()

            tintedColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 30, y: 5.5, width: 2, height: 5), xRadius: 0.5, yRadius: 0.5).fill()

            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tintedColor]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(
                at: NSPoint(x: (30 - size.width) / 2, y: (18 - size.height) / 2),
                withAttributes: attrs
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    func makeBatteryIcon(usage: UsageData, color: NSColor) -> NSImage {
        // Round, don't truncate: the popover prints these numbers with "%.0f", so 15.6 must not
        // draw "15" here and "16%" there. `.toNearestOrEven` because that is what "%.0f" does at
        // exact halves - plain .rounded() goes half-away-from-zero and would draw 17 against the
        // popover's 16. Low flags read the raw value, matching the popover's red.
        let weeklyPercent = Int(usage.weeklyRemaining.rounded(.toNearestOrEven))
        let sessionPercent = Int(usage.sessionDisplayRemaining.rounded(.toNearestOrEven))
        let isSessionLow = usage.sessionDisplayRemaining < 20
        let isWeeklyLow = usage.weeklyRemaining < 20

        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .heavy)
        let smallNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .heavy)
        let kern: CGFloat = -0.8

        let batteryWidth: CGFloat = 30
        let batteryHeight: CGFloat = 14
        let nubWidth: CGFloat = 2
        let nubHeight: CGFloat = 6
        let cornerRadius: CGFloat = 3
        let fillInset: CGFloat = 1.5
        let iconHeight: CGFloat = 18
        let gap: CGFloat = 4

        let totalWidth = nubWidth + batteryWidth + gap + batteryWidth + nubWidth
        let baseColor = color

        let image = NSImage(size: NSSize(width: totalWidth, height: iconHeight), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            let batteryY = (iconHeight - batteryHeight) / 2
            let interiorWidth = batteryWidth - fillInset * 2
            let interiorHeight = batteryHeight - fillInset * 2

            func drawBattery(bodyX: CGFloat, nubOnLeft: Bool, percent: Int, isLow: Bool) {
                let font = percent >= 100 ? smallNumberFont : numberFont
                let numberStr = "\(percent)" as NSString
                let numberSize = numberStr.size(withAttributes: [.font: font, .kern: kern])
                let numberPoint = NSPoint(
                    x: bodyX + (batteryWidth - numberSize.width) / 2,
                    y: (iconHeight - numberSize.height) / 2
                )

                // 1. Outline
                baseColor.setStroke()
                let outline = NSBezierPath(roundedRect: NSRect(x: bodyX, y: batteryY, width: batteryWidth, height: batteryHeight), xRadius: cornerRadius, yRadius: cornerRadius)
                outline.lineWidth = 1.0
                outline.stroke()

                // 2. Nub
                let nubX = nubOnLeft ? bodyX - nubWidth : bodyX + batteryWidth
                baseColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: nubX, y: batteryY + (batteryHeight - nubHeight) / 2, width: nubWidth, height: nubHeight), xRadius: 0.5, yRadius: 0.5).fill()

                // 3. Fill level
                let fillWidth = interiorWidth * CGFloat(percent) / 100.0
                var fillRect = NSRect.zero
                if fillWidth > 0 {
                    let fillX: CGFloat = nubOnLeft
                        ? bodyX + fillInset + interiorWidth - fillWidth
                        : bodyX + fillInset
                    fillRect = NSRect(x: fillX, y: batteryY + fillInset, width: fillWidth, height: interiorHeight)
                    let fillColor: NSColor = isLow ? .red : baseColor
                    fillColor.setFill()
                    NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()
                }

                // 4. Text — two-pass clipping for contrast
                if fillWidth > 0 {
                    ctx.saveGState()
                    ctx.clip(to: fillRect)
                    ctx.setBlendMode(.clear)
                    numberStr.draw(at: numberPoint, withAttributes: [
                        .font: font, .kern: kern,
                        .foregroundColor: NSColor.white
                    ])
                    ctx.restoreGState()
                }

                let unfilledWidth = interiorWidth - fillWidth
                if unfilledWidth > 0 {
                    let unfilledX: CGFloat = nubOnLeft
                        ? bodyX + fillInset
                        : bodyX + fillInset + fillWidth
                    let unfilledRect = NSRect(x: unfilledX, y: batteryY + fillInset,
                                              width: unfilledWidth, height: interiorHeight)
                    ctx.saveGState()
                    ctx.clip(to: unfilledRect)
                    numberStr.draw(at: numberPoint, withAttributes: [
                        .font: font, .kern: kern,
                        .foregroundColor: baseColor
                    ])
                    ctx.restoreGState()
                }
            }

            // Session battery (left, nub points left)
            drawBattery(bodyX: nubWidth, nubOnLeft: true, percent: sessionPercent, isLow: isSessionLow)

            // Weekly battery (right, nub points right)
            drawBattery(bodyX: nubWidth + batteryWidth + gap, nubOnLeft: false, percent: weeklyPercent, isLow: isWeeklyLow)

            return true
        }

        image.isTemplate = false
        return image
    }
}
