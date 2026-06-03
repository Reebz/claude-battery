import AppKit
import SwiftUI
import Combine
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app",
    category: "MenuBar"
)

/// Appearance names the menu-bar icon distinguishes between. Sub-variants
/// (e.g. `NSAppearanceNameAccessibilityHighContrastDarkAqua`) collapse onto
/// these via `bestMatch(from:)`.
private let menuBarAppearanceBuckets: [NSAppearance.Name] = [.darkAqua, .aqua]

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
    private var wakeObserver: NSObjectProtocol?
    private var stalenessTimer: Timer?
    private var counterFlushTimer: Timer?

    @AppStorage("iconStyle") private var iconStyleRaw: String = IconStyle.dualHorizontal.rawValue

    /// Signature of the last successful render. Used by updateIcon to short-circuit
    /// when all inputs that determine the rendered output are unchanged.
    private var lastRenderedSignature: IconSignature?

    // Per-minute diagnostic counters. Flushed to os_log .notice by counterFlushTimer
    // so affected users in extended desktop mode can paste Console.app output into
    // issue #11. Three counters triangulate which path is driving CPU:
    //   - appearanceKVODispatched: bestMatch guard passed, Task dispatched.
    //     Low count + high CPU + high suppressed = loop driver is NOT the appearance
    //     KVO, so the guard+signature fix is masking the wrong path.
    //   - updateIconRendered: button.image was actually reassigned.
    //   - updateIconSuppressedBySignature: signature matched cached value, no render.
    private var appearanceKVODispatched: Int = 0
    private var updateIconRendered: Int = 0
    private var updateIconSuppressedBySignature: Int = 0

    private var isMenuBarDark: Bool {
        guard let button = statusItem.button else { return true }
        return button.effectiveAppearance.bestMatch(from: menuBarAppearanceBuckets) == .darkAqua
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
            .combineLatest(usageService.$authFailed)
            .removeDuplicates { prev, next in
                prev.0.0 == next.0.0 && prev.0.1 == next.0.1 && prev.0.2 == next.0.2 && prev.1 == next.1
            }
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .receive(on: RunLoop.main)
            .sink { [weak self] combined, authFailed in
                let (usage, _, activeId) = combined
                self?.updateIcon(usage, isAuthenticated: activeId != nil, authFailed: authFailed)
            }
            .store(in: &cancellables)

        // Targeted KVO on the iconStyle key only — replaces the global
        // UserDefaults.didChangeNotification which fired for EVERY defaults write
        // across the entire process (including SwiftUI @AppStorage), causing high CPU.
        // Dedup is handled inside updateIcon by the signature short-circuit.
        iconStyleObservation = UserDefaults.standard.observe(\.iconStyle, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated, authFailed: self.usageService.authFailed)
            }
        }

        // KVO on the button's effectiveAppearance. The bestMatch dedup runs synchronously
        // on whatever thread AppKit fires the observation on (bestMatch on an immutable
        // NSAppearance is thread-safe per Apple docs), so suppressed fires never allocate
        // a @MainActor Task. Only real dark/light transitions reach the main actor.
        // See issue #11 — .name comparison leaks AccessibilityHighContrast sub-variants
        // whose names differ but whose brightness bucket is identical.
        appearanceObservation = statusItem.button?.observe(
            \.effectiveAppearance, options: [.new, .old]
        ) { [weak self] _, change in
            guard Self.shouldReactToAppearanceChange(old: change.oldValue, new: change.newValue) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.appearanceKVODispatched += 1
                self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated, authFailed: self.usageService.authFailed)
            }
        }

        // Invalidate the render-signature cache on wake. The button may have been
        // reset during sleep/wake display reconfiguration, so a matching signature
        // must not suppress the first post-wake render.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastRenderedSignature = nil
                self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated, authFailed: self.usageService.authFailed)
            }
        }

        // 60-second staleness timer — isStale is a time-dependent computed property
        // not in the Combine pipeline. Without this timer, the icon won't transition
        // to the faded "stale" state when polling stalls during active use.
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated, authFailed: self.usageService.authFailed)
            }
        }
        stalenessTimer?.tolerance = 30

        // Per-minute counter flush, offset by 30 seconds from the staleness timer so
        // counter windows capture the staleness timer's work mid-window rather than
        // resetting at the same moment. Emits counts via os_log .notice so the values
        // survive in the persistent log store and can be retrieved from affected
        // users via `log show` or Console.app filtered by subsystem + category.
        counterFlushTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flushCounters()
            }
        }
        counterFlushTimer?.tolerance = 30
        counterFlushTimer?.fireDate = Date(timeIntervalSinceNow: 30)
        if let counterFlushTimer { RunLoop.main.add(counterFlushTimer, forMode: .common) }
    }

    private func flushCounters() {
        logger.notice("counter=appearanceKVODispatched value=\(self.appearanceKVODispatched)")
        logger.notice("counter=updateIconRendered value=\(self.updateIconRendered)")
        logger.notice("counter=updateIconSuppressedBySignature value=\(self.updateIconSuppressedBySignature)")
        appearanceKVODispatched = 0
        updateIconRendered = 0
        updateIconSuppressedBySignature = 0
    }

    deinit {
        stalenessTimer?.invalidate()
        counterFlushTimer?.invalidate()
        appearanceObservation?.invalidate()
        iconStyleObservation?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
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

    /// Open (or focus) the Settings window. Exposed so the manual-sign-in hook can route a
    /// stuck user from the login error overlay straight to the paste section (U5).
    func showSettings() {
        openSettings()
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
        // If the button has disappeared, invalidate the cache so a returning button
        // starts from a clean state rather than inheriting a suppressed signature.
        guard let button = statusItem.button else {
            lastRenderedSignature = nil
            return
        }

        let isMenuBarDark = button.effectiveAppearance.bestMatch(from: menuBarAppearanceBuckets) == .darkAqua
        let style = IconStyle(rawValue: iconStyleRaw) ?? .dualHorizontal
        let render = Self.renderState(
            isAuthenticated: isAuthenticated,
            authFailed: authFailed,
            usage: usage,
            consecutiveFailures: usageService.consecutiveFailures,
            isStale: usageService.isStale
        )
        let signature = IconSignature(style: style, isMenuBarDark: isMenuBarDark, render: render)

        guard signature != lastRenderedSignature else {
            updateIconSuppressedBySignature += 1
            return
        }

        let color: NSColor = isMenuBarDark ? .white : .black
        button.image = makeImage(for: render, style: style, color: color)
        lastRenderedSignature = signature
        updateIconRendered += 1
    }

    private func makeImage(for render: RenderState, style: IconStyle, color: NSColor) -> NSImage {
        let renderer = style.renderer
        switch render {
        case .unauthenticated:
            return renderer.makeUnauthenticatedIcon(color: color)
        case .authFailed:
            return renderer.makeStatusIcon(text: "!", color: color, alpha: 0.5)
        case .battery(let usage):
            return renderer.makeBatteryIcon(usage: usage, color: color)
        case .statusError:
            return renderer.makeStatusIcon(text: "!", color: color, alpha: 0.5)
        case .statusStale:
            return renderer.makeStatusIcon(text: "...", color: color, alpha: 0.5)
        case .statusLoading:
            return renderer.makeStatusIcon(text: "...", color: color, alpha: 1.0)
        }
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
    case authFailed        // "!" at alpha 0.5 — session expired
    case battery(UsageData)
    case statusError       // "!" at alpha 0.5
    case statusStale       // "..." at alpha 0.5
    case statusLoading     // "..." at alpha 1.0
}

/// Full cache key for the rendered menu-bar icon: render branch plus the two
/// rendering-context inputs (`style`, `isMenuBarDark`) that also determine the
/// visible output. When two `IconSignature` values compare equal, the produced
/// NSImage would be byte-identical and a re-render is wasted work.
struct IconSignature: Equatable {
    let style: IconStyle
    let isMenuBarDark: Bool
    let render: RenderState
}

extension MenuBarController {
    /// Pure mapping from updateIcon inputs to the render branch that will be drawn.
    /// Intentionally checks error (>=10 failures) before stale — 10+ failures is an
    /// error state regardless of staleness. This differs from the pre-refactor ordering
    /// where stale was checked first, but error-first is more correct semantically.
    nonisolated static func renderState(
        isAuthenticated: Bool,
        authFailed: Bool,
        usage: UsageData?,
        consecutiveFailures: Int,
        isStale: Bool
    ) -> RenderState {
        if !isAuthenticated { return .unauthenticated }
        if authFailed { return .authFailed }
        if let usage { return .battery(usage) }
        if consecutiveFailures >= 10 { return .statusError }
        if consecutiveFailures >= 3 && isStale { return .statusStale }
        return .statusLoading
    }

    /// Decide whether an `effectiveAppearance` KVO fire represents a real light/dark
    /// transition worth re-rendering for. Collapses sub-variant `NSAppearance`
    /// instances (accessibility/high-contrast etc.) onto the two brightness
    /// buckets the icon cares about, and treats a nil `old` as an implicit change
    /// (the first fire during init has no prior value to compare against).
    /// Returns `false` when the fire should be dropped, `true` when the caller
    /// should proceed to render. Pure — safe to call from any thread, which is
    /// required because KVO observation closures on AppKit properties are not
    /// guaranteed to run on the main thread.
    nonisolated static func shouldReactToAppearanceChange(
        old: NSAppearance?,
        new: NSAppearance?
    ) -> Bool {
        guard let new else { return false }
        guard let old else { return true }
        let oldDark = old.bestMatch(from: menuBarAppearanceBuckets) == .darkAqua
        let newDark = new.bestMatch(from: menuBarAppearanceBuckets) == .darkAqua
        return oldDark != newDark
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
