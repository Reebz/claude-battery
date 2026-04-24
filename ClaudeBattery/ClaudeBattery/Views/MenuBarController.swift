import AppKit
import SwiftUI
import Combine

@MainActor
class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private let accountStore: AccountStore
    private let authManager: AuthManager
    private let usageService: UsageService
    private let updateChecker: UpdateChecker
    private var settingsWindowController: NSWindowController?
    private var appearanceObservation: NSKeyValueObservation?
    private var defaultsObserver: NSObjectProtocol?

    @AppStorage("iconStyle") private var iconStyleRaw: String = IconStyle.dualHorizontal.rawValue

    /// Tracks the last rendered style to avoid redundant re-renders.
    private var lastRenderedStyle: String = ""

    private var isMenuBarDark: Bool {
        guard let button = statusItem.button else { return true }
        return button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The primary icon color: white on dark menu bars, black on light menu bars.
    private var iconColor: NSColor {
        isMenuBarDark ? .white : .black
    }

    init(accountStore: AccountStore, authManager: AuthManager, usageService: UsageService, updateChecker: UpdateChecker) {
        self.accountStore = accountStore
        self.authManager = authManager
        self.usageService = usageService
        self.updateChecker = updateChecker

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
                authManager: authManager,
                usageService: usageService,
                updateChecker: updateChecker,
                onSignIn: { [weak self] in self?.authManager.presentLogin() }
            )
        )
    }

    private func setupObservers() {
        usageService.$latestUsage
            .combineLatest(usageService.$consecutiveFailures, accountStore.$activeAccountId)
            .combineLatest(usageService.$authFailed)
            .receive(on: RunLoop.main)
            .sink { [weak self] combined, authFailed in
                let (usage, _, activeId) = combined
                self?.updateIcon(usage, isAuthenticated: activeId != nil, authFailed: authFailed)
            }
            .store(in: &cancellables)

        // Re-render when icon style preference changes in Settings
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentStyle = UserDefaults.standard.string(forKey: "iconStyle") ?? IconStyle.dualHorizontal.rawValue
                guard currentStyle != self.lastRenderedStyle else { return }
                self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated, authFailed: self.usageService.authFailed)
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
                self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated, authFailed: self.usageService.authFailed)
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

    private func updateIcon(_ usage: UsageData?, isAuthenticated: Bool, authFailed: Bool = false) {
        let style = IconStyle(rawValue: iconStyleRaw) ?? .dualHorizontal
        let renderer = style.renderer
        let color = iconColor
        let image: NSImage

        if !isAuthenticated {
            image = renderer.makeUnauthenticatedIcon(color: color)
        } else if authFailed {
            image = renderer.makeStatusIcon(text: "!", color: color, alpha: 0.5)
        } else if let usage = usage {
            image = renderer.makeBatteryIcon(usage: usage, color: color)
        } else if usageService.consecutiveFailures >= 10 {
            image = renderer.makeStatusIcon(text: "!", color: color, alpha: 0.5)
        } else if usageService.isStale && usageService.consecutiveFailures >= 3 {
            image = renderer.makeStatusIcon(text: "...", color: color, alpha: 0.5)
        } else {
            image = renderer.makeStatusIcon(text: "...", color: color, alpha: 1.0)
        }

        lastRenderedStyle = iconStyleRaw
        statusItem.button?.image = image
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
