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
    private var showSessionCountdownObservation: NSKeyValueObservation?
    private var wakeObserver: NSObjectProtocol?
    private var stalenessTimer: Timer?
    private var counterFlushTimer: Timer?

    /// Dedicated per-minute timer that re-renders the menu-bar icon so the composed countdown
    /// cell ticks down. Kept separate from `stalenessTimer` so its interval is independent.
    /// Started only while the countdown toggle is on. Its `updateIcon` re-render is gated to one
    /// render per countdown-string change by the IconSignature `countdown` field (issue #11 safe).
    private var countdownTimer: Timer?

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

        // Targeted KVO on the countdown toggle key only (mirrors iconStyle, never a global
        // observer - the v1.46 CPU anti-pattern, KTD4). On change: start/stop the dedicated
        // timer and re-render the icon so the cell appears/disappears immediately.
        showSessionCountdownObservation = UserDefaults.standard.observe(\.showSessionCountdown, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncCountdownTimer()
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
                // The countdown cell is composed into button.image, so a normal updateIcon
                // re-render (different isMenuBarDark -> different signature) repaints the cell in
                // the new color too. No separate title-color refresh needed.
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

        // Initialize the countdown timer to the current toggle state. The icon itself is
        // rendered by the init updateIcon call (and subsequent re-renders carry the cell).
        syncCountdownTimer()
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
        countdownTimer?.invalidate()
        appearanceObservation?.invalidate()
        iconStyleObservation?.invalidate()
        showSessionCountdownObservation?.invalidate()
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
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
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

    /// Open (or focus) the Settings window. Internal + `@objc` so it serves BOTH the menu-item
    /// selector and the manual-sign-in hook that routes a stuck user from the login error overlay
    /// to the paste section (U5) — no thin passthrough wrapper.
    @objc func showSettings() {
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
        // "" when the toggle is off or there is no session reset window. Folding it into the
        // signature is what makes the per-minute timer re-render exactly once per string change
        // (e.g. "32m" -> "31m") and never in a loop - same-string fires short-circuit below.
        let countdown = Self.countdownTitle(
            usage: usage,
            enabled: UserDefaults.standard.bool(forKey: MenuBarDefaults.showSessionCountdownKey)
        )
        let signature = IconSignature(style: style, isMenuBarDark: isMenuBarDark, render: render, countdown: countdown)

        guard signature != lastRenderedSignature else {
            updateIconSuppressedBySignature += 1
            return
        }

        let color: NSColor = isMenuBarDark ? .white : .black
        let base = makeImage(for: render, style: style, color: color)
        // The countdown cell only rides the battery render; status/auth glyphs stay bare.
        if case .battery = render, !countdown.isEmpty {
            button.image = Self.imageWithCountdownCell(countdown: countdown, batteryImage: base, color: color)
        } else {
            button.image = base
        }
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

    // MARK: - Countdown Cell (composed into button.image; reverses the U7 title path)

    /// Pure mapping from usage + toggle to the compact countdown string. Returns the 3-char
    /// `compactCountdown` for the session reset when enabled and a positive countdown exists,
    /// else "" (the off/none state). `nonisolated static` so it is reachable from tests and
    /// free of controller state, mirroring `renderState`.
    ///
    /// The cell ALWAYS clocks the 5h session, including while the weekly limit binds. Accepted
    /// consequence, decided deliberately: in that state the pill beside the cell shows
    /// `sessionDisplayRemaining`, i.e. the weekly quota, so the clock reaches zero and the number
    /// next to it does not move. Suppressing the cell there was tried and reverted - it removed
    /// the reset time in the state where users most want it. The popover still hides the dial's
    /// inner time arc for that same pairing (`suppressTimeArc:` in `UsagePopoverView.sessionCard`),
    /// so the two surfaces differ here on purpose; do not "restore parity" without re-deciding this.
    nonisolated static func countdownTitle(usage: UsageData?, enabled: Bool, now: Date = Date()) -> String {
        guard enabled, let resetDate = usage?.sessionResetDate else { return "" }
        return CountdownFormat.compactCountdown(until: resetDate, now: now) ?? ""
    }

    /// Compose a leading rounded "tag cell" carrying the countdown onto the front of the
    /// battery image, matching the battery visual language: `[ 3h+ ] [75] [43]`. This renders
    /// INSIDE the icon image rather than as a floating `button.attributedTitle`, so the timer
    /// reads as part of the icon, adapts to light/dark with the rest of the render, and the
    /// IconSignature dedup (which now includes the countdown string) drives a single re-render
    /// per minute. The cell font is one weight lighter / a touch smaller than the heavy battery
    /// digits so the timer reads as secondary while staying in the same monospaced family.
    nonisolated static func imageWithCountdownCell(countdown: String, batteryImage: NSImage, color: NSColor) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        // Canvas height derives from the battery image so a taller renderer (the 20x20
        // DualArcGaugeRenderer) is not clipped or pushed to a negative y in an 18-tall canvas.
        // Every cell/battery offset below already centers against iconHeight, so this one
        // constant keeps both aligned across all icon styles.
        let iconHeight = max(18, batteryImage.size.height)
        let cellHeight: CGFloat = 14
        let cornerRadius: CGFloat = 3
        let gap: CGFloat = 4
        let hPadding: CGFloat = 4

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = countdown as NSString
        let textSize = text.size(withAttributes: attrs)
        let cellWidth = ceil(textSize.width) + hPadding * 2

        let batterySize = batteryImage.size
        let totalWidth = cellWidth + gap + batterySize.width

        let image = NSImage(size: NSSize(width: totalWidth, height: iconHeight), flipped: false) { _ in
            // Cell: rounded-rect outline matching the batteries (1.0pt stroke, cornerRadius 3,
            // height 14, vertically centered in the 18-tall canvas).
            let cellY = (iconHeight - cellHeight) / 2
            color.setStroke()
            let outline = NSBezierPath(
                roundedRect: NSRect(x: 0.5, y: cellY, width: cellWidth - 1, height: cellHeight),
                xRadius: cornerRadius,
                yRadius: cornerRadius
            )
            outline.lineWidth = 1.0
            outline.stroke()

            // Countdown text centered inside the cell.
            text.draw(
                at: NSPoint(x: (cellWidth - textSize.width) / 2, y: (iconHeight - textSize.height) / 2),
                withAttributes: attrs
            )

            // Battery image: [cell][gap][battery], full size, vertically aligned.
            batteryImage.draw(
                in: NSRect(x: cellWidth + gap, y: (iconHeight - batterySize.height) / 2,
                           width: batterySize.width, height: batterySize.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Start the dedicated countdown timer when the toggle is on, invalidate it when off.
    /// Interval 60 with 30s tolerance (matching `stalenessTimer`) so the OS can coalesce
    /// wakes; added to `.common` mode so it fires while menus/tracking are active. The closure
    /// re-renders via `updateIcon` with a fresh countdown string. Issue #11 safety: the
    /// reassignment re-fires the effectiveAppearance KVO, but `shouldReactToAppearanceChange`
    /// drops same-brightness-bucket fires, and the IconSignature `countdown` field gates the
    /// render to exactly once per string change - so there is NO cascade, only ~1 render/min.
    private func syncCountdownTimer() {
        let enabled = UserDefaults.standard.bool(forKey: MenuBarDefaults.showSessionCountdownKey)
        if enabled {
            guard countdownTimer == nil else { return }
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateIcon(self.usageService.latestUsage, isAuthenticated: self.accountStore.isAuthenticated, authFailed: self.usageService.authFailed)
                }
            }
            timer.tolerance = 30
            countdownTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }
}

// MARK: - Shared defaults keys

/// Single source of truth for menu-bar defaults keys, so the SwiftUI `@AppStorage` binding
/// (SettingsView) and the targeted-KVO `@objc dynamic` accessor below cannot drift.
enum MenuBarDefaults {
    static let showSessionCountdownKey = "showSessionCountdown"
}

// MARK: - UserDefaults KVO Support

extension UserDefaults {
    @objc dynamic var iconStyle: String? {
        string(forKey: "iconStyle")
    }

    @objc dynamic var showSessionCountdown: Bool {
        bool(forKey: MenuBarDefaults.showSessionCountdownKey)
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
    /// The composed countdown-cell string ("" when off/none). Part of the signature so a
    /// per-minute countdown change re-renders the image exactly once - the dedup must observe
    /// the string change, otherwise the new countdown would never paint.
    let countdown: String
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
