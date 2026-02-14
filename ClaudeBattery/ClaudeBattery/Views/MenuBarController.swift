import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}

@MainActor
class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private let authManager: AuthManager
    private let usageService: UsageService

    private let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular)

    // Cached static icons
    private lazy var unauthenticatedIcon: NSImage = {
        let iconSize = NSSize(width: 34, height: 18)
        let image = NSImage(size: iconSize, flipped: false) { rect in
            let batteryRect = NSRect(x: 0, y: 3, width: 30, height: 12)
            let path = NSBezierPath(roundedRect: batteryRect, xRadius: 2, yRadius: 2)
            NSColor.black.setStroke()
            path.lineWidth = 1.0
            path.stroke()

            let nubRect = NSRect(x: 30, y: 5.5, width: 2, height: 5)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: nubRect, xRadius: 0.5, yRadius: 0.5).fill()

            return true
        }
        image.isTemplate = true
        return image
    }()

    private lazy var loadingIcon: NSImage = {
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
    }()

    private lazy var staleIcon: NSImage = {
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

            let text = "..." as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.gray]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: 7, y: (18 - size.height) / 2), withAttributes: attrs)

            return true
        }
        image.isTemplate = true
        return image
    }()

    private lazy var errorIcon: NSImage = {
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
    }()

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

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openSettings, object: nil)
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
        let isLowBattery = usage.weeklyRemaining < 20

        let weeklyResetText = formatResetTime(usage.weeklyResetDate)
        let sessionResetText = formatResetTime(usage.sessionResetDate)

        // Compute text sizes once
        let percentFontAttrs: [NSAttributedString.Key: Any] = [.font: digitFont]
        let resetFontAttrs: [NSAttributedString.Key: Any] = [.font: smallFont]

        let weeklyPercentStr = "\(weeklyPercent)%" as NSString
        let weeklyResetStr = weeklyResetText as NSString
        let sessionPercentStr = "\(sessionPercent)%" as NSString
        let sessionResetStr = sessionResetText as NSString

        let weeklyPercentSize = weeklyPercentStr.size(withAttributes: percentFontAttrs)
        let weeklyResetSize = weeklyResetStr.size(withAttributes: resetFontAttrs)
        let sessionPercentSize = sessionPercentStr.size(withAttributes: percentFontAttrs)
        let sessionResetSize = sessionResetStr.size(withAttributes: resetFontAttrs)

        let batteryWidth: CGFloat = 30
        let batteryHeight: CGFloat = 12
        let nubWidth: CGFloat = 2
        let nubHeight: CGFloat = 5
        let sessionBarWidth: CGFloat = 3
        let sessionBarHeight: CGFloat = 10
        let cornerRadius: CGFloat = 2
        let fillInset: CGFloat = 1.5
        let iconHeight: CGFloat = 18

        let totalWidth = batteryWidth + nubWidth + 2 + weeklyPercentSize.width + 2 + weeklyResetSize.width + 4 + 0.5 + 4 + sessionBarWidth + 2 + sessionPercentSize.width + 2 + sessionResetSize.width + 1

        let fgColor: NSColor = isLowBattery ? .white : .black
        let batteryColor: NSColor = isLowBattery ? .systemRed : .black

        let image = NSImage(size: NSSize(width: totalWidth, height: iconHeight), flipped: false) { rect in
            let batteryY: CGFloat = (iconHeight - batteryHeight) / 2

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
                NSBezierPath(roundedRect: fillRect, xRadius: 1, yRadius: 1).fill()
            }

            // Weekly % text
            let percentDrawAttrs: [NSAttributedString.Key: Any] = [.font: self.digitFont, .foregroundColor: fgColor]
            let resetDrawAttrs: [NSAttributedString.Key: Any] = [.font: self.smallFont, .foregroundColor: fgColor]

            let percentX = batteryWidth + nubWidth + 2
            weeklyPercentStr.draw(at: NSPoint(x: percentX, y: (iconHeight - weeklyPercentSize.height) / 2), withAttributes: percentDrawAttrs)

            // Weekly reset text
            let resetX = percentX + weeklyPercentSize.width + 2
            weeklyResetStr.draw(at: NSPoint(x: resetX, y: (iconHeight - weeklyResetSize.height) / 2), withAttributes: resetDrawAttrs)

            // Divider
            let dividerX = resetX + weeklyResetSize.width + 4
            let dividerColor: NSColor = isLowBattery ? .white.withAlphaComponent(0.5) : .black.withAlphaComponent(0.3)
            dividerColor.setStroke()
            let dividerPath = NSBezierPath()
            dividerPath.move(to: NSPoint(x: dividerX, y: 3))
            dividerPath.line(to: NSPoint(x: dividerX, y: iconHeight - 3))
            dividerPath.lineWidth = 0.5
            dividerPath.stroke()

            // Session bar
            let sessionBarX = dividerX + 4
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
            let sessionTextX = sessionBarX + sessionBarWidth + 2
            sessionPercentStr.draw(at: NSPoint(x: sessionTextX, y: (iconHeight - sessionPercentSize.height) / 2), withAttributes: percentDrawAttrs)

            // Session reset text
            let sessionResetX = sessionTextX + sessionPercentSize.width + 2
            sessionResetStr.draw(at: NSPoint(x: sessionResetX, y: (iconHeight - sessionResetSize.height) / 2), withAttributes: resetDrawAttrs)

            return true
        }

        image.isTemplate = !isLowBattery
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
}
