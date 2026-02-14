import AppKit
import SwiftUI
import Combine

@MainActor
class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private let authManager: AuthManager
    private let usageService: UsageService

    private let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular)

    init(authManager: AuthManager, usageService: UsageService) {
        self.authManager = authManager
        self.usageService = usageService

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        setupButton()
        setupPopover()
        setupObservers()

        // Initial render
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
        popover.contentSize = NSSize(width: 320, height: 300)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(
                usageService: usageService,
                onSignIn: { [weak self] in self?.authManager.presentLogin() }
            )
        )
    }

    private func setupObservers() {
        usageService.$latestUsage
            .combineLatest(
                usageService.$consecutiveFailures,
                usageService.$lastSuccessfulFetch,
                authManager.$isAuthenticated
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] usage, failures, lastFetch, isAuth in
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
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        // Set targets for menu items
        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Icon Rendering

    private func updateIcon(_ usage: UsageData?, isAuthenticated: Bool) {
        let image: NSImage

        if !isAuthenticated {
            image = makeUnauthenticatedIcon()
        } else if let usage = usage {
            image = makeBatteryIcon(usage: usage)
        } else if usageService.consecutiveFailures >= 10 {
            image = makeErrorIcon()
        } else if usageService.isStale && usageService.consecutiveFailures >= 3 {
            image = makeStaleIcon()
        } else {
            image = makeLoadingIcon()
        }

        statusItem.button?.image = image
    }

    private func makeBatteryIcon(usage: UsageData) -> NSImage {
        let weeklyPercent = Int(usage.weeklyRemaining)
        let sessionPercent = Int(usage.sessionRemaining)
        let isLowBattery = usage.weeklyRemaining < 20

        let weeklyResetText = formatResetTime(usage.weeklyResetDate)
        let sessionResetText = formatResetTime(usage.sessionResetDate)

        let totalWidth: CGFloat = computeIconWidth(weeklyPercent: weeklyPercent, weeklyReset: weeklyResetText, sessionPercent: sessionPercent, sessionReset: sessionResetText)
        let iconHeight: CGFloat = 18

        let fgColor: NSColor = isLowBattery ? .white : .black
        let font = digitFont
        let sFont = smallFont
        let batteryColor: NSColor = isLowBattery ? .systemRed : .black

        let image = NSImage(size: NSSize(width: totalWidth, height: iconHeight), flipped: false) { rect in
            let batteryWidth: CGFloat = 30
            let batteryHeight: CGFloat = 12
            let batteryY: CGFloat = (iconHeight - batteryHeight) / 2
            let nubWidth: CGFloat = 2
            let nubHeight: CGFloat = 5
            let cornerRadius: CGFloat = 2
            let fillInset: CGFloat = 1.5

            // Battery outline
            let bodyRect = NSRect(x: 0, y: batteryY, width: batteryWidth, height: batteryHeight)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)
            batteryColor.setStroke()
            bodyPath.lineWidth = 1.0
            bodyPath.stroke()

            // Nub
            let nubRect = NSRect(
                x: batteryWidth,
                y: batteryY + (batteryHeight - nubHeight) / 2,
                width: nubWidth,
                height: nubHeight
            )
            let nubPath = NSBezierPath(roundedRect: nubRect, xRadius: 0.5, yRadius: 0.5)
            batteryColor.setFill()
            nubPath.fill()

            // Fill
            let fillWidth = (batteryWidth - fillInset * 2) * CGFloat(weeklyPercent) / 100.0
            if fillWidth > 0 {
                let fillRect = NSRect(
                    x: fillInset,
                    y: batteryY + fillInset,
                    width: fillWidth,
                    height: batteryHeight - fillInset * 2
                )
                let fillColor: NSColor = isLowBattery ? .systemRed : batteryColor
                fillColor.setFill()
                let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1)
                fillPath.fill()
            }

            // Weekly % text
            let percentText = "\(weeklyPercent)%" as NSString
            let percentAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fgColor]
            let percentSize = percentText.size(withAttributes: percentAttrs)
            let percentX = batteryWidth + nubWidth + 2
            percentText.draw(at: NSPoint(x: percentX, y: (iconHeight - percentSize.height) / 2), withAttributes: percentAttrs)

            // Weekly reset text
            let resetAttrs: [NSAttributedString.Key: Any] = [.font: sFont, .foregroundColor: fgColor]
            let resetText = weeklyResetText as NSString
            let resetSize = resetText.size(withAttributes: resetAttrs)
            let resetX = percentX + percentSize.width + 2
            resetText.draw(at: NSPoint(x: resetX, y: (iconHeight - resetSize.height) / 2), withAttributes: resetAttrs)

            // Divider
            let dividerX = resetX + resetSize.width + 4
            let dividerColor: NSColor = isLowBattery ? .white.withAlphaComponent(0.5) : .black.withAlphaComponent(0.3)
            dividerColor.setStroke()
            let dividerPath = NSBezierPath()
            dividerPath.move(to: NSPoint(x: dividerX, y: 3))
            dividerPath.line(to: NSPoint(x: dividerX, y: iconHeight - 3))
            dividerPath.lineWidth = 0.5
            dividerPath.stroke()

            // Session bar
            let sessionBarX = dividerX + 4
            let sessionBarWidth: CGFloat = 3
            let sessionBarHeight: CGFloat = 10
            let sessionBarY = (iconHeight - sessionBarHeight) / 2
            let sessionFillHeight = sessionBarHeight * CGFloat(sessionPercent) / 100.0

            // Session bar background
            let sessionBgRect = NSRect(x: sessionBarX, y: sessionBarY, width: sessionBarWidth, height: sessionBarHeight)
            let sessionBgColor = (isLowBattery ? NSColor.white : NSColor.black).withAlphaComponent(0.2)
            sessionBgColor.setFill()
            NSBezierPath(roundedRect: sessionBgRect, xRadius: 1, yRadius: 1).fill()

            // Session bar fill
            if sessionFillHeight > 0 {
                let sessionFillRect = NSRect(x: sessionBarX, y: sessionBarY, width: sessionBarWidth, height: sessionFillHeight)
                fgColor.setFill()
                NSBezierPath(roundedRect: sessionFillRect, xRadius: 1, yRadius: 1).fill()
            }

            // Session % text
            let sessionText = "\(sessionPercent)%" as NSString
            let sessionSize = sessionText.size(withAttributes: percentAttrs)
            let sessionTextX = sessionBarX + sessionBarWidth + 2
            sessionText.draw(at: NSPoint(x: sessionTextX, y: (iconHeight - sessionSize.height) / 2), withAttributes: percentAttrs)

            // Session reset text
            let sessionResetStr = sessionResetText as NSString
            let sessionResetSize = sessionResetStr.size(withAttributes: resetAttrs)
            let sessionResetX = sessionTextX + sessionSize.width + 2
            sessionResetStr.draw(at: NSPoint(x: sessionResetX, y: (iconHeight - sessionResetSize.height) / 2), withAttributes: resetAttrs)

            return true
        }

        image.isTemplate = !isLowBattery
        return image
    }

    private func makeUnauthenticatedIcon() -> NSImage {
        let iconSize = NSSize(width: 34, height: 18)
        let image = NSImage(size: iconSize, flipped: false) { rect in
            let batteryRect = NSRect(x: 0, y: 3, width: 30, height: 12)
            let path = NSBezierPath(roundedRect: batteryRect, xRadius: 2, yRadius: 2)
            NSColor.black.setStroke()
            path.lineWidth = 1.0
            path.stroke()

            // Nub
            let nubRect = NSRect(x: 30, y: 5.5, width: 2, height: 5)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: nubRect, xRadius: 0.5, yRadius: 0.5).fill()

            return true
        }
        image.isTemplate = true
        return image
    }

    private func makeLoadingIcon() -> NSImage {
        let iconSize = NSSize(width: 40, height: 18)
        let font = digitFont
        let image = NSImage(size: iconSize, flipped: false) { rect in
            let batteryRect = NSRect(x: 0, y: 3, width: 30, height: 12)
            let path = NSBezierPath(roundedRect: batteryRect, xRadius: 2, yRadius: 2)
            NSColor.black.setStroke()
            path.lineWidth = 1.0
            path.stroke()

            let nubRect = NSRect(x: 30, y: 5.5, width: 2, height: 5)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: nubRect, xRadius: 0.5, yRadius: 0.5).fill()

            let text = "..." as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: 7, y: (18 - size.height) / 2), withAttributes: attrs)

            return true
        }
        image.isTemplate = true
        return image
    }

    private func makeStaleIcon() -> NSImage {
        let icon = makeLoadingIcon()
        icon.lockFocus()
        NSColor.black.withAlphaComponent(0.5).setFill()
        icon.unlockFocus()
        return icon
    }

    private func makeErrorIcon() -> NSImage {
        let iconSize = NSSize(width: 40, height: 18)
        let font = digitFont
        let image = NSImage(size: iconSize, flipped: false) { rect in
            let batteryRect = NSRect(x: 0, y: 3, width: 30, height: 12)
            let path = NSBezierPath(roundedRect: batteryRect, xRadius: 2, yRadius: 2)
            NSColor.gray.setStroke()
            path.lineWidth = 1.0
            path.stroke()

            let nubRect = NSRect(x: 30, y: 5.5, width: 2, height: 5)
            NSColor.gray.setFill()
            NSBezierPath(roundedRect: nubRect, xRadius: 0.5, yRadius: 0.5).fill()

            let text = "!" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.gray]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: 12, y: (18 - size.height) / 2), withAttributes: attrs)

            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Formatting

    private func formatResetTime(_ date: Date?) -> String {
        guard let date = date else { return "--" }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "--" }

        let hours = Int(remaining / 3600)
        let minutes = Int(remaining / 60) % 60

        if hours >= 24 {
            let days = hours / 24
            return "\(days)d"
        } else if hours >= 1 {
            return "\(hours)h"
        } else {
            return "\(max(1, minutes))m"
        }
    }

    private func computeIconWidth(weeklyPercent: Int, weeklyReset: String, sessionPercent: Int, sessionReset: String) -> CGFloat {
        let percentAttrs: [NSAttributedString.Key: Any] = [.font: digitFont]
        let resetAttrs: [NSAttributedString.Key: Any] = [.font: smallFont]

        let weeklyPercentWidth = ("\(weeklyPercent)%" as NSString).size(withAttributes: percentAttrs).width
        let weeklyResetWidth = (weeklyReset as NSString).size(withAttributes: resetAttrs).width
        let sessionPercentWidth = ("\(sessionPercent)%" as NSString).size(withAttributes: percentAttrs).width
        let sessionResetWidth = (sessionReset as NSString).size(withAttributes: resetAttrs).width

        // battery(30) + nub(2) + gap(2) + weeklyPercent + gap(2) + weeklyReset + gap(4) + divider(0.5) + gap(4) + sessionBar(3) + gap(2) + sessionPercent + gap(2) + sessionReset
        return 30 + 2 + 2 + weeklyPercentWidth + 2 + weeklyResetWidth + 4 + 0.5 + 4 + 3 + 2 + sessionPercentWidth + 2 + sessionResetWidth + 1
    }
}
