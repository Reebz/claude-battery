import AppKit
import SwiftUI
import Combine

enum IconStyle: String, CaseIterable {
    case dualHorizontal = "Dual Horizontal"
    case minimal = "Minimal"
    case dualArcGauge = "Dual Arc Gauge"
    case textOnly = "Text Only"
    case stackedBars = "Stacked Bars"
}

@MainActor
class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private let accountStore: AccountStore
    private let authManager: AuthManager
    private let usageService: UsageService
    private var settingsWindowController: NSWindowController?
    private var appearanceObservation: NSKeyValueObservation?
    private var defaultsObserver: NSObjectProtocol?

    @AppStorage("iconStyle") private var iconStyle: String = IconStyle.dualHorizontal.rawValue

    private let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    private var isMenuBarDark: Bool {
        guard let button = statusItem.button else { return true }
        return button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The primary icon color: white on dark menu bars, black on light menu bars.
    private var iconColor: NSColor {
        isMenuBarDark ? .white : .black
    }

    // MARK: - Dynamic Icon Factories (appearance-aware, never cached)

    // Shared vertical battery geometry
    private let battBodyW: CGFloat = 10
    private let battBodyH: CGFloat = 14
    private let battNubW: CGFloat = 5
    private let battNubH: CGFloat = 2
    private let battIconW: CGFloat = 14
    private let battIconH: CGFloat = 18
    private let battCR: CGFloat = 2.5

    private var battBodyX: CGFloat { (battIconW - battBodyW) / 2 }
    private let battBodyY: CGFloat = 1
    private var battNubX: CGFloat { (battIconW - battNubW) / 2 }
    private var battNubY: CGFloat { battBodyY + battBodyH }

    /// Draws the vertical battery outline + nub. Call inside an NSImage drawing block.
    private func drawBatteryShell(color: NSColor) {
        color.setStroke()
        let outline = NSBezierPath(roundedRect: NSRect(x: battBodyX, y: battBodyY,
                                                        width: battBodyW, height: battBodyH),
                                    xRadius: battCR, yRadius: battCR)
        outline.lineWidth = 1.0
        outline.stroke()

        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: battNubX, y: battNubY,
                                          width: battNubW, height: battNubH),
                      xRadius: 0.5, yRadius: 0.5).fill()
    }

    private func makeMinimalUnauthenticatedIcon() -> NSImage {
        let color = iconColor
        let image = NSImage(size: NSSize(width: battIconW, height: battIconH), flipped: false) { [self] _ in
            drawBatteryShell(color: color)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func makeMinimalStatusIcon(text: String, alpha: CGFloat = 1.0) -> NSImage {
        let font = digitFont
        let color = iconColor.withAlphaComponent(alpha)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let gap: CGFloat = 1
        let totalWidth = battIconW + gap + textSize.width + 1

        let image = NSImage(size: NSSize(width: totalWidth, height: battIconH), flipped: false) { [self] _ in
            drawBatteryShell(color: color)

            (text as NSString).draw(
                at: NSPoint(x: battIconW + gap, y: (battIconH - textSize.height) / 2),
                withAttributes: attrs
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Horizontal (Dual Battery) Drawing

    private func makeHorizontalUnauthenticatedIcon() -> NSImage {
        let color = iconColor
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

    private func makeHorizontalStatusIcon(text: String, alpha: CGFloat = 1.0) -> NSImage {
        let font = digitFont
        let color = iconColor.withAlphaComponent(alpha)
        let image = NSImage(size: NSSize(width: 40, height: 18), flipped: false) { _ in
            color.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 0, y: 3, width: 30, height: 12), xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.0
            outline.stroke()

            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 30, y: 5.5, width: 2, height: 5), xRadius: 0.5, yRadius: 0.5).fill()

            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
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

    private func makeHorizontalBatteryIcon(usage: UsageData) -> NSImage {
        let weeklyPercent = Int(usage.weeklyRemaining)
        let sessionPercent = Int(usage.sessionRemaining)
        let isSessionLow = sessionPercent < 20
        let isWeeklyLow = weeklyPercent < 20

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
        let baseColor = iconColor

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

                baseColor.setStroke()
                let outline = NSBezierPath(roundedRect: NSRect(x: bodyX, y: batteryY, width: batteryWidth, height: batteryHeight), xRadius: cornerRadius, yRadius: cornerRadius)
                outline.lineWidth = 1.0
                outline.stroke()

                let nubX = nubOnLeft ? bodyX - nubWidth : bodyX + batteryWidth
                baseColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: nubX, y: batteryY + (batteryHeight - nubHeight) / 2, width: nubWidth, height: nubHeight), xRadius: 0.5, yRadius: 0.5).fill()

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

            drawBattery(bodyX: nubWidth, nubOnLeft: true, percent: sessionPercent, isLow: isSessionLow)
            drawBattery(bodyX: nubWidth + batteryWidth + gap, nubOnLeft: false, percent: weeklyPercent, isLow: isWeeklyLow)

            return true
        }

        image.isTemplate = false
        return image
    }

    // MARK: - Dual Arc Gauge Drawing

    private let arcIconSize: CGFloat = 20
    private let arcOuterRadius: CGFloat = 8
    private let arcInnerRadius: CGFloat = 5
    private let arcLineWidth: CGFloat = 2.5
    private let arcStartAngle: CGFloat = 225   // bottom-left (degrees, counterclockwise from east)
    private let arcSweep: CGFloat = 270         // 270° sweep clockwise

    /// Draws a single arc track + fill.
    /// `fraction` in 0...1; `center` is the arc center; angles in degrees (counterclockwise).
    private func drawArc(center: NSPoint, radius: CGFloat, fraction: CGFloat,
                         trackColor: NSColor, fillColor: NSColor) {
        let startDeg = arcStartAngle
        let endDeg = arcStartAngle - arcSweep  // counterclockwise sweep

        // Background track
        trackColor.setStroke()
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius,
                        startAngle: startDeg, endAngle: endDeg, clockwise: true)
        track.lineWidth = arcLineWidth
        track.lineCapStyle = .round
        track.stroke()

        // Filled portion
        if fraction > 0 {
            fillColor.setStroke()
            let fillEnd = startDeg - arcSweep * fraction
            let fill = NSBezierPath()
            fill.appendArc(withCenter: center, radius: radius,
                           startAngle: startDeg, endAngle: fillEnd, clockwise: true)
            fill.lineWidth = arcLineWidth
            fill.lineCapStyle = .round
            fill.stroke()
        }
    }

    private func makeArcGaugeUnauthenticatedIcon() -> NSImage {
        let size = arcIconSize
        let color = iconColor
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { [self] _ in
            let center = NSPoint(x: size / 2, y: size / 2)
            let trackColor = color.withAlphaComponent(0.15)
            drawArc(center: center, radius: arcOuterRadius, fraction: 0,
                    trackColor: trackColor, fillColor: color)
            drawArc(center: center, radius: arcInnerRadius, fraction: 0,
                    trackColor: trackColor, fillColor: color)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func makeArcGaugeStatusIcon(text: String, alpha: CGFloat = 1.0) -> NSImage {
        let size = arcIconSize
        let color = iconColor.withAlphaComponent(alpha)
        let font = digitFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let gap: CGFloat = 1
        let totalWidth = size + gap + textSize.width + 1

        let image = NSImage(size: NSSize(width: totalWidth, height: size), flipped: false) { [self] _ in
            let center = NSPoint(x: size / 2, y: size / 2)
            let trackColor = color.withAlphaComponent(0.15)
            drawArc(center: center, radius: arcOuterRadius, fraction: 0,
                    trackColor: trackColor, fillColor: color)
            drawArc(center: center, radius: arcInnerRadius, fraction: 0,
                    trackColor: trackColor, fillColor: color)

            (text as NSString).draw(
                at: NSPoint(x: size + gap, y: (size - textSize.height) / 2),
                withAttributes: attrs
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private func makeArcGaugeBatteryIcon(usage: UsageData) -> NSImage {
        let weeklyPercent = usage.weeklyRemaining
        let sessionPercent = usage.sessionRemaining
        let size = arcIconSize
        let baseColor = iconColor

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { [self] _ in
            let center = NSPoint(x: size / 2, y: size / 2)
            let trackColor = baseColor.withAlphaComponent(0.15)

            // Outer arc — weekly
            let weeklyFill: NSColor = weeklyPercent < 20 ? .red : baseColor
            drawArc(center: center, radius: arcOuterRadius,
                    fraction: CGFloat(weeklyPercent) / 100.0,
                    trackColor: trackColor, fillColor: weeklyFill)

            // Inner arc — session
            let sessionFill: NSColor = sessionPercent < 20 ? .red : baseColor
            drawArc(center: center, radius: arcInnerRadius,
                    fraction: CGFloat(sessionPercent) / 100.0,
                    trackColor: trackColor, fillColor: sessionFill)

            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Text Only Drawing

    private let textOnlyFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private let textOnlySepFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .light)

    private func makeTextOnlyIcon(session: String, weekly: String, alpha: CGFloat = 1.0) -> NSImage {
        let color = iconColor.withAlphaComponent(alpha)
        let numAttrs: [NSAttributedString.Key: Any] = [.font: textOnlyFont, .foregroundColor: color]
        let sepAttrs: [NSAttributedString.Key: Any] = [.font: textOnlySepFont,
                                                        .foregroundColor: color.withAlphaComponent(0.5)]
        let s = session as NSString
        let w = weekly as NSString
        let sep = "|" as NSString
        let sSize = s.size(withAttributes: numAttrs)
        let wSize = w.size(withAttributes: numAttrs)
        let sepSize = sep.size(withAttributes: sepAttrs)
        let gap: CGFloat = 2
        let totalW = sSize.width + gap + sepSize.width + gap + wSize.width
        let h: CGFloat = 18

        let image = NSImage(size: NSSize(width: totalW, height: h), flipped: false) { _ in
            let baseline = (h - sSize.height) / 2
            s.draw(at: NSPoint(x: 0, y: baseline), withAttributes: numAttrs)
            sep.draw(at: NSPoint(x: sSize.width + gap, y: (h - sepSize.height) / 2), withAttributes: sepAttrs)
            w.draw(at: NSPoint(x: sSize.width + gap + sepSize.width + gap, y: baseline), withAttributes: numAttrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func makeTextOnlyBatteryIcon(usage: UsageData) -> NSImage {
        let s = "\(Int(usage.sessionRemaining))"
        let w = "\(Int(usage.weeklyRemaining))"
        return makeTextOnlyIcon(session: s, weekly: w)
    }

    private func makeTextOnlyUnauthenticatedIcon() -> NSImage {
        makeTextOnlyIcon(session: "--", weekly: "--", alpha: 0.4)
    }

    private func makeTextOnlyStatusIcon(text: String, alpha: CGFloat = 1.0) -> NSImage {
        let color = iconColor.withAlphaComponent(alpha)
        let attrs: [NSAttributedString.Key: Any] = [.font: textOnlyFont, .foregroundColor: color]
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        let h: CGFloat = 18
        let image = NSImage(size: NSSize(width: size.width, height: h), flipped: false) { _ in
            str.draw(at: NSPoint(x: 0, y: (h - size.height) / 2), withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Stacked Bars Drawing

    private func makeStackedBarsIcon(sessionFraction: CGFloat, weeklyFraction: CGFloat,
                                      sessionLow: Bool, weeklyLow: Bool, alpha: CGFloat = 1.0) -> NSImage {
        let barW: CGFloat = 28
        let barH: CGFloat = 4
        let gap: CGFloat = 3
        let iconW: CGFloat = barW
        let iconH: CGFloat = 18
        let baseColor = iconColor.withAlphaComponent(alpha)
        let trackColor = baseColor.withAlphaComponent(0.18)
        let topBarY = (iconH + gap) / 2      // session bar (top)
        let botBarY = (iconH - gap) / 2 - barH  // weekly bar (bottom)

        let image = NSImage(size: NSSize(width: iconW, height: iconH), flipped: false) { _ in
            // Tracks
            trackColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: topBarY, width: barW, height: barH), xRadius: 2, yRadius: 2).fill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: botBarY, width: barW, height: barH), xRadius: 2, yRadius: 2).fill()

            // Session fill (top bar)
            let sessionFillW = barW * max(sessionFraction, 0)
            if sessionFillW > 0 {
                let c: NSColor = sessionLow ? .red : baseColor
                c.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: topBarY, width: sessionFillW, height: barH), xRadius: 2, yRadius: 2).fill()
            }

            // Weekly fill (bottom bar)
            let weeklyFillW = barW * max(weeklyFraction, 0)
            if weeklyFillW > 0 {
                let c: NSColor = weeklyLow ? .red : baseColor
                c.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: botBarY, width: weeklyFillW, height: barH), xRadius: 2, yRadius: 2).fill()
            }

            return true
        }
        image.isTemplate = false
        return image
    }

    private func makeStackedBarsBatteryIcon(usage: UsageData) -> NSImage {
        makeStackedBarsIcon(
            sessionFraction: CGFloat(usage.sessionRemaining) / 100.0,
            weeklyFraction: CGFloat(usage.weeklyRemaining) / 100.0,
            sessionLow: usage.sessionRemaining < 20,
            weeklyLow: usage.weeklyRemaining < 20
        )
    }

    private func makeStackedBarsUnauthenticatedIcon() -> NSImage {
        makeStackedBarsIcon(sessionFraction: 0, weeklyFraction: 0, sessionLow: false, weeklyLow: false, alpha: 0.4)
    }

    private func makeStackedBarsStatusIcon(alpha: CGFloat = 1.0) -> NSImage {
        makeStackedBarsIcon(sessionFraction: 0, weeklyFraction: 0, sessionLow: false, weeklyLow: false, alpha: alpha)
    }

    init(accountStore: AccountStore, authManager: AuthManager, usageService: UsageService) {
        self.accountStore = accountStore
        self.authManager = authManager
        self.usageService = usageService

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        setupButton()
        setupPopover()
        setupObservers()

        updateIcon(nil, isAuthenticated: accountStore.isAuthenticated)
    }

    // MARK: - Setup

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(handleClick)
        button.target = self
    }

    private func setupPopover() {
        popover.contentSize = NSSize(width: 300, height: 300)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(
                accountStore: accountStore,
                usageService: usageService,
                onSignIn: { [weak self] in self?.authManager.presentLogin() }
            )
        )
    }

    private func setupObservers() {
        usageService.$latestUsage
            .combineLatest(usageService.$consecutiveFailures, accountStore.$activeAccountId)
            .receive(on: RunLoop.main)
            .sink { [weak self] usage, _, activeId in
                self?.updateIcon(usage, isAuthenticated: activeId != nil)
            }
            .store(in: &cancellables)

        // Re-render when icon style preference changes in Settings
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated)
            }
        }

        // KVO on the button's effectiveAppearance — fires when wallpaper changes
        // the menu bar from dark to light (or vice versa), unlike DistributedNotificationCenter.
        appearanceObservation = statusItem.button?.observe(
            \.effectiveAppearance, options: [.new, .old]
        ) { [weak self] _, change in
            guard change.oldValue?.name != change.newValue?.name else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated)
            }
        }
    }

    // MARK: - Click Handling

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }

        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        }
    }

    @objc private func openSettings() {
        if let wc = settingsWindowController {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(
            accountStore: accountStore,
            authManager: authManager,
            closeWindow: { [weak self] in
                self?.settingsWindowController?.close()
            }
        )
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Claude Battery Settings"
        window.styleMask = [.titled, .closable]
        window.delegate = self

        // Position below the status item button
        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRect)
            let x = screenRect.midX - window.frame.width / 2
            let y = screenRect.minY - window.frame.height - 4
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Icon Rendering

    private func updateIcon(_ usage: UsageData?, isAuthenticated: Bool) {
        let image: NSImage
        let style = IconStyle(rawValue: iconStyle) ?? .dualHorizontal

        if !isAuthenticated {
            switch style {
            case .dualHorizontal: image = makeHorizontalUnauthenticatedIcon()
            case .minimal:        image = makeMinimalUnauthenticatedIcon()
            case .dualArcGauge:   image = makeArcGaugeUnauthenticatedIcon()
            case .textOnly:       image = makeTextOnlyUnauthenticatedIcon()
            case .stackedBars:    image = makeStackedBarsUnauthenticatedIcon()
            }
        } else if let usage = usage {
            switch style {
            case .dualHorizontal: image = makeHorizontalBatteryIcon(usage: usage)
            case .minimal:        image = makeMinimalBatteryIcon(usage: usage)
            case .dualArcGauge:   image = makeArcGaugeBatteryIcon(usage: usage)
            case .textOnly:       image = makeTextOnlyBatteryIcon(usage: usage)
            case .stackedBars:    image = makeStackedBarsBatteryIcon(usage: usage)
            }
        } else if usageService.consecutiveFailures >= 10 {
            switch style {
            case .dualHorizontal: image = makeHorizontalStatusIcon(text: "!", alpha: 0.5)
            case .minimal:        image = makeMinimalStatusIcon(text: "!", alpha: 0.5)
            case .dualArcGauge:   image = makeArcGaugeStatusIcon(text: "!", alpha: 0.5)
            case .textOnly:       image = makeTextOnlyStatusIcon(text: "!", alpha: 0.5)
            case .stackedBars:    image = makeStackedBarsStatusIcon(alpha: 0.5)
            }
        } else if usageService.isStale && usageService.consecutiveFailures >= 3 {
            switch style {
            case .dualHorizontal: image = makeHorizontalStatusIcon(text: "...", alpha: 0.5)
            case .minimal:        image = makeMinimalStatusIcon(text: "...", alpha: 0.5)
            case .dualArcGauge:   image = makeArcGaugeStatusIcon(text: "...", alpha: 0.5)
            case .textOnly:       image = makeTextOnlyStatusIcon(text: "...", alpha: 0.5)
            case .stackedBars:    image = makeStackedBarsStatusIcon(alpha: 0.5)
            }
        } else {
            switch style {
            case .dualHorizontal: image = makeHorizontalStatusIcon(text: "...")
            case .minimal:        image = makeMinimalStatusIcon(text: "...")
            case .dualArcGauge:   image = makeArcGaugeStatusIcon(text: "...")
            case .textOnly:       image = makeTextOnlyStatusIcon(text: "...")
            case .stackedBars:    image = makeStackedBarsStatusIcon()
            }
        }

        statusItem.button?.image = image
    }

    private func makeMinimalBatteryIcon(usage: UsageData) -> NSImage {
        let weeklyPercent = Int(usage.weeklyRemaining)
        let sessionPercent = Int(usage.sessionRemaining)
        let isSessionLow = sessionPercent < 20
        let isWeeklyLow = weeklyPercent < 20

        let fillInset: CGFloat = 1.5
        let dividerGap: CGFloat = 1.0

        let interiorW = battBodyW - fillInset * 2
        let interiorH = battBodyH - fillInset * 2
        let sectionH = (interiorH - dividerGap) / 2

        let bottomY = battBodyY + fillInset                       // weekly section bottom
        let topY    = bottomY + sectionH + dividerGap             // session section bottom
        let dividerY = bottomY + sectionH + dividerGap / 2        // center of divider

        let baseColor = iconColor

        let image = NSImage(size: NSSize(width: battIconW, height: battIconH), flipped: false) { [self] _ in
            // 1. Shell (outline + nub)
            drawBatteryShell(color: baseColor)

            let fillX = battBodyX + fillInset

            // 2. Session fill (top section) — fills upward from divider
            let sessionFillH = sectionH * CGFloat(sessionPercent) / 100.0
            if sessionFillH > 0 {
                let fillColor: NSColor = isSessionLow ? .red : baseColor
                fillColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: fillX, y: topY,
                                                  width: interiorW, height: sessionFillH),
                              xRadius: 1, yRadius: 1).fill()
            }

            // 3. Horizontal divider
            baseColor.withAlphaComponent(0.3).setStroke()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: fillX, y: dividerY))
            divider.line(to: NSPoint(x: fillX + interiorW, y: dividerY))
            divider.lineWidth = 0.5
            divider.stroke()

            // 4. Weekly fill (bottom section) — fills upward from bottom
            let weeklyFillH = sectionH * CGFloat(weeklyPercent) / 100.0
            if weeklyFillH > 0 {
                let fillColor: NSColor = isWeeklyLow ? .red : baseColor
                fillColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: fillX, y: bottomY,
                                                  width: interiorW, height: weeklyFillH),
                              xRadius: 1, yRadius: 1).fill()
            }

            return true
        }

        image.isTemplate = false
        return image
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }
}

// MARK: - NSWindowDelegate

extension MenuBarController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindowController = nil
    }
}
