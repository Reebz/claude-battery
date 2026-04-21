import AppKit
import SwiftUI
import Combine
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app",
    category: "MenuBar"
)

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
    private var iconStyleObservation: NSKeyValueObservation?
    private var stalenessTimer: Timer?
    private var counterFlushTimer: Timer?

    @AppStorage("iconStyle") private var iconStyleRaw: String = IconStyle.dualHorizontal.rawValue

    /// Tracks the last rendered style to avoid redundant re-renders.
    private var lastRenderedStyle: String = ""

    // Per-minute diagnostic counters. Incremented inside updateIcon (Unit 3) and
    // flushed to os_log .notice by counterFlushTimer so affected users in
    // extended desktop mode can paste Console.app output into issue #11.
    private var updateIconRendered: Int = 0
    private var updateIconSuppressedBySignature: Int = 0

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
        // Combine pipeline with deduplication and throttle to prevent unnecessary icon re-renders.
        // Without these, every @Published write (even identical values) triggers updateIcon().
        usageService.$latestUsage
            .combineLatest(usageService.$consecutiveFailures, accountStore.$activeAccountId)
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .removeDuplicates { prev, next in
                prev.0 == next.0 && prev.1 == next.1 && prev.2 == next.2
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] usage, _, activeId in
                self?.updateIcon(usage, isAuthenticated: activeId != nil)
            }
            .store(in: &cancellables)

        // Targeted KVO on the iconStyle key only — replaces the global
        // UserDefaults.didChangeNotification which fired for EVERY defaults write
        // across the entire process (including SwiftUI @AppStorage), causing high CPU.
        iconStyleObservation = UserDefaults.standard.observe(\.iconStyle, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentStyle = UserDefaults.standard.string(forKey: "iconStyle") ?? IconStyle.dualHorizontal.rawValue
                guard currentStyle != self.lastRenderedStyle else { return }
                self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated)
            }
        }

        // KVO on the button's effectiveAppearance — fires when wallpaper changes
        // the menu bar from dark to light (or vice versa), unlike DistributedNotificationCenter.
        appearanceObservation = statusItem.button?.observe(
            \.effectiveAppearance, options: [.new, .old]
        ) { [weak self] _, change in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Dedupe sub-variant NSAppearance instances that share dark/light brightness.
                // Extended-desktop mode produces these via per-screen context changes —
                // .name comparison leaks fires because AccessibilityHighContrast variants
                // have different names but resolve to the same bestMatch value (see issue #11).
                let oldDark = change.oldValue?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let newDark = change.newValue?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                // Treat nil oldValue as an implicit change (first fire during init).
                if change.oldValue != nil, oldDark == newDark { return }
                self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated)
            }
        }

        // 60-second staleness timer — isStale is a time-dependent computed property
        // not in the Combine pipeline. Without this timer, the icon won't transition
        // to the faded "stale" state when polling stalls during active use.
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated)
            }
        }

        // Per-minute counter flush. Emits rendered + suppressed counts via os_log .notice
        // so the values survive in the persistent log store and can be retrieved from
        // affected users via `log show` or Console.app filtered by subsystem + category.
        counterFlushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flushCounters()
            }
        }
    }

    private func flushCounters() {
        logger.notice("counter=updateIconRendered value=\(self.updateIconRendered)")
        logger.notice("counter=updateIconSuppressedBySignature value=\(self.updateIconSuppressedBySignature)")
        updateIconRendered = 0
        updateIconSuppressedBySignature = 0
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
        let style = IconStyle(rawValue: iconStyleRaw) ?? .dualHorizontal
        let renderer = style.renderer
        let color = iconColor
        let image: NSImage

        if !isAuthenticated {
            image = renderer.makeUnauthenticatedIcon(color: color)
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

// MARK: - UserDefaults KVO Support

extension UserDefaults {
    @objc dynamic var iconStyle: String? {
        string(forKey: "iconStyle")
    }
}

// MARK: - Render State & Signature

/// The rendered-output branch selected by updateIcon. The signature short-circuit
/// depends on this rather than raw inputs so that state changes which do not affect
/// the rendered NSImage (e.g. failure count churn while usage data is present)
/// do not trigger spurious re-renders.
enum RenderState: Equatable {
    case unauthenticated
    case battery(UsageData)
    case statusError       // "!" at alpha 0.5
    case statusStale       // "..." at alpha 0.5
    case statusLoading     // "..." at alpha 1.0
}

struct IconSignature: Equatable {
    let style: IconStyle
    let isMenuBarDark: Bool
    let render: RenderState
}

extension MenuBarController {
    /// Pure mapping from updateIcon inputs to the render branch that will be drawn.
    /// Mirrors updateIcon's if-chain exactly so the signature composed from this
    /// output is a faithful representation of what appears on screen.
    nonisolated static func renderState(
        isAuthenticated: Bool,
        usage: UsageData?,
        consecutiveFailures: Int,
        isStale: Bool
    ) -> RenderState {
        if !isAuthenticated { return .unauthenticated }
        if let usage { return .battery(usage) }
        if consecutiveFailures >= 10 { return .statusError }
        if consecutiveFailures >= 3 && isStale { return .statusStale }
        return .statusLoading
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
