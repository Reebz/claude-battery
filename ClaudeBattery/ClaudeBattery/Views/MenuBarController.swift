import AppKit
import SwiftUI
import Combine

@MainActor
class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private let authManager: AuthManager
    private let usageService: UsageService
    private let onSignOut: () -> Void
    private var settingsWindowController: NSWindowController?

    private let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    // Cached static icons

    private lazy var unauthenticatedIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 34, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 3, width: 30, height: 12), xRadius: 2, yRadius: 2)
            path.lineWidth = 1.0
            path.stroke()

            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 30, y: 5.5, width: 2, height: 5), xRadius: 0.5, yRadius: 0.5).fill()

            return true
        }
        image.isTemplate = true
        return image
    }()

    private func makeStatusIcon(text: String, color: NSColor) -> NSImage {
        let font = digitFont
        let image = NSImage(size: NSSize(width: 40, height: 18), flipped: false) { rect in
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
        image.isTemplate = true
        return image
    }

    private lazy var loadingIcon = makeStatusIcon(text: "...", color: .black)
    private lazy var staleIcon = makeStatusIcon(text: "...", color: .gray)
    private lazy var errorIcon = makeStatusIcon(text: "!", color: .gray)

    init(authManager: AuthManager, usageService: UsageService, onSignOut: @escaping () -> Void) {
        self.authManager = authManager
        self.usageService = usageService
        self.onSignOut = onSignOut

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        setupButton()
        setupPopover()
        setupObservers()

        updateIcon(nil, isAuthenticated: authManager.isAuthenticated)
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
                authManager: authManager,
                usageService: usageService,
                onSignIn: { [weak self] in self?.authManager.presentLogin() }
            )
        )
    }

    private func setupObservers() {
        usageService.$latestUsage
            .combineLatest(usageService.$consecutiveFailures, authManager.$isAuthenticated)
            .receive(on: RunLoop.main)
            .sink { [weak self] usage, _, isAuth in
                self?.updateIcon(usage, isAuthenticated: isAuth)
            }
            .store(in: &cancellables)
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

        let settingsView = SettingsView(signOut: onSignOut)
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

        if !isAuthenticated {
            image = unauthenticatedIcon
        } else if let usage = usage {
            image = makeBatteryIcon(usage: usage)
        } else if usageService.consecutiveFailures >= 10 {
            image = errorIcon
        } else if usageService.isStale && usageService.consecutiveFailures >= 3 {
            image = staleIcon
        } else {
            image = loadingIcon
        }

        statusItem.button?.image = image
    }

    private func makeBatteryIcon(usage: UsageData) -> NSImage {
        let weeklyPercent = Int(usage.weeklyRemaining)
        let sessionPercent = Int(usage.sessionRemaining)
        let isSessionLow = sessionPercent < 20
        let isWeeklyLow = weeklyPercent < 20
        let anyLow = isSessionLow || isWeeklyLow

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

        let image = NSImage(size: NSSize(width: totalWidth, height: iconHeight), flipped: false) { rect in
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

                // Template mode: .black = opaque (macOS auto-colors as menu bar text)
                // Non-template mode (anyLow): .white for outlines, .red for low fill
                let strokeColor: NSColor = anyLow ? .white : .black

                // 1. Outline
                strokeColor.setStroke()
                let outline = NSBezierPath(roundedRect: NSRect(x: bodyX, y: batteryY, width: batteryWidth, height: batteryHeight), xRadius: cornerRadius, yRadius: cornerRadius)
                outline.lineWidth = 1.0
                outline.stroke()

                // 2. Nub
                let nubX = nubOnLeft ? bodyX - nubWidth : bodyX + batteryWidth
                strokeColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: nubX, y: batteryY + (batteryHeight - nubHeight) / 2, width: nubWidth, height: nubHeight), xRadius: 0.5, yRadius: 0.5).fill()

                // 3. Fill level
                let fillWidth = interiorWidth * CGFloat(percent) / 100.0
                var fillRect = NSRect.zero
                if fillWidth > 0 {
                    let fillX: CGFloat = nubOnLeft
                        ? bodyX + fillInset + interiorWidth - fillWidth
                        : bodyX + fillInset
                    fillRect = NSRect(x: fillX, y: batteryY + fillInset, width: fillWidth, height: interiorHeight)
                    let fillColor: NSColor = anyLow ? (isLow ? .red : .white) : .black
                    fillColor.setFill()
                    NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()
                }

                // 4. Text — adaptive two-pass clipping
                // Pass 1: Knockout over filled area (clear → transparent → contrasts with fill)
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

                // Pass 2: Solid text over unfilled area
                // Template mode: .black = opaque → macOS renders as menu bar text color
                // Non-template mode: .white = visible on dark menu bar background
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
                        .foregroundColor: anyLow ? NSColor.white : NSColor.black
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

        image.isTemplate = !anyLow
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
