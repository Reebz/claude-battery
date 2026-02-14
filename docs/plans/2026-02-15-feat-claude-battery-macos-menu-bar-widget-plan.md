---
title: "feat: Claude Battery macOS Menu Bar Widget"
type: feat
date: 2026-02-15
deepened: 2026-02-15
---

# feat: Claude Battery macOS Menu Bar Widget

## Enhancement Summary

**Deepened on:** 2026-02-15
**Research agents used:** Security Sentinel, Performance Oracle, Architecture Strategist, Code Simplicity Reviewer, Best Practices Researcher, Framework Docs Researcher

### Key Improvements
1. **Simplified state management** — Flattened 5-state machine to `isAuthenticated: Bool` + `lastSuccessfulFetch: Date?`. No separate `AppState` class — `UsageService` is the `ObservableObject` directly.
2. **Critical performance fixes** — Deallocate WKWebView after login (saves 100-200MB), set timer tolerance for energy efficiency, prevent App Nap throttling
3. **Security hardening** — Display URL in login window title bar, use `kSecAttrAccessibleWhenUnlocked`, whitelist navigation domains, cookie domain validation, credential redaction in logs
4. **Platform-specific patterns** — NSPopover focus fix (`NSApp.activate` + `makeKey`), SMAppService status re-read pattern, UNUserNotificationCenter delegate setup before launch
5. **Reduced file count** — Merged NotificationService into UsageService, merged UsageModels into UsageService, extracted KeychainService (net: 7 files from 8)
6. **Simplified error handling** — Collapsed to 2 categories: auth failure (401/403) vs everything else (retry with exponential backoff)

### New Considerations Discovered
- App Nap will throttle the 2-minute timer unless prevented with `ProcessInfo.beginActivity`
- `activate(ignoringOtherApps: true)` is required for NSPopover to receive focus in menu bar apps
- WKWebView retains 100-200MB in a separate WebContent process even when idle — must nil out after login
- SMAppService status can be changed by the user in System Settings at any time — always re-read, never cache

---

## Overview

Build a macOS menu bar widget called **Claude Battery** that displays Claude Pro/Max usage as a battery icon draining from 100% to 0%. Targets non-technical users (marketers) who need a glanceable view of their remaining Claude quota.

The app polls an undocumented Anthropic API endpoint every 2 minutes, renders usage data as a battery icon with session indicator, and authenticates via an embedded WKWebView that captures the user's session cookie automatically.

## Problem Statement / Motivation

Claude Pro and Max users have no persistent, glanceable way to monitor their usage quota outside of the Claude web app. The built-in usage display requires navigating to Settings > Usage. Existing third-party tools (Usage4Claude, Claude-Usage-Tracker) require manually extracting session keys from browser DevTools — a dealbreaker for non-technical users.

Claude Battery solves this with a native macOS menu bar widget that authenticates via a "Sign In" button (no DevTools required) and continuously shows remaining quota as a battery metaphor.

## Proposed Solution

### Menu Bar Layout

```
[█████░░░ 58% 3d | ▮ 92% 4h]
 ─────────────────  ──────────
 Weekly quota        Session
```

**Left: Battery capsule** (weekly quota)
- Rounded rectangle + nub, fill level = remaining weekly %
- Text inside: `58%` (remaining), thin divider, `3d` (days until reset)
- Switches to hours when <24h (`18h`), minutes when <1h (`45m`)

**Center: Thin vertical divider**

**Right: Session indicator**
- Small vertical progress bar = remaining session %
- Text: `92%` (remaining), `4h` (hours until session reset)
- Switches to minutes when <1h (`45m`)

### Color Scheme
- **Monochrome** (`isTemplate = true`) when remaining >= 20%
- **Red** (`isTemplate = false`) when remaining < 20% — the next poll re-renders the icon with correct appearance, no need to observe `effectiveAppearanceDidChangeNotification` separately

### Percentage Direction
Battery metaphor: `remaining = 100 - utilization`. API returns utilization (% used), we display remaining (% left).

### Click Behavior
- **Left-click**: NSPopover with detailed usage (progress bars, exact %, reset countdown)
- **Right-click**: Native NSMenu (Settings, Quit)
- Implementation: `button.sendAction(on: [.leftMouseUp, .rightMouseUp])`, discriminate via `NSApp.currentEvent?.type`, temporary `statusItem.menu` assignment for right-click

#### Research Insights: NSPopover Focus Fix

NSPopover in menu bar apps has a persistent focus issue across macOS versions — the popover window does not automatically become key, breaking keyboard input and `.transient` dismissal. The fix:

```swift
func showPopover() {
    guard let button = statusItem.button else { return }
    NSApplication.shared.activate(ignoringOtherApps: true)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
}
```

For the right-click context menu, use the temporary menu assignment pattern:

```swift
func showContextMenu() {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil  // Remove so left click returns to popover
}
```

References:
- [NSPopover focus fix (dagronf)](https://dagronf.wordpress.com/2020/03/04/why-does-my-nspopover-not-dismiss-which-clicking-outside-it/)
- [Using NSPopover with NSStatusItem (Shaheen Gandhi)](https://shaheengandhi.com/using-nspopover-with-nsstatusitem/)

### Authentication Flow
1. User clicks "Sign In" in the popover
2. A window presents a `WKWebView` loading `https://claude.ai/login`
3. **Display the current URL in the window title bar** so users can verify they are on the correct domain
4. User logs in (email/password, Google SSO, Apple SSO — all work as standard web redirects)
5. `WKHTTPCookieStoreObserver` + `webView(_:didFinish:)` fallback detect the `sessionKey` cookie
6. App stores cookie value in macOS Keychain
7. **Deallocate the WKWebView immediately** (nil out webView, configuration, and window controller — saves 100-200MB)
8. App calls `GET /api/organizations` to discover the user's org ID
9. If zero orgs returned: show "No Claude Pro or Max subscription found. Claude Battery requires an active Pro or Max plan." with a sign-out button
10. If multiple orgs returned, use the first one (v1 simplification)
11. App begins polling `GET /api/organizations/{orgId}/usage`

#### Research Insights: WKWebView Security

**Domain whitelisting**: Implement `WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)` to strictly whitelist navigation to `claude.ai`, `accounts.google.com`, and `appleid.apple.com`. Block all other domains.

**No JavaScript injection**: Do not add `WKUserScript` objects or call `evaluateJavaScript` on pages containing credential forms.

**Use `.default()` data store**: Use `WKWebsiteDataStore.default()` (not `.nonPersistent()`) for the login WKWebView. OAuth/SSO flows often use `localStorage` during redirect chains — `.nonPersistent()` would lose this data on refresh and break the flow. Clear data explicitly on sign-out instead.

**Memory management**: WKWebView runs rendering in a separate `com.apple.WebKit.WebContent` process that consumes 100-200MB even when idle. After cookie capture:

```swift
func onSessionKeyCaptured(_ cookie: HTTPCookie) {
    // Validate cookie attributes before trusting
    guard cookie.domain.hasSuffix("claude.ai"),
          cookie.isSecure,
          cookie.path == "/" else { return }

    keychainService.save(cookie.value, forKey: "sessionKey")
    loginWebView?.stopLoading()
    loginWebView?.configuration.websiteDataStore.httpCookieStore.removeObserver(self)

    // Clear data store immediately — don't leave cookie on disk until sign-out
    WKWebsiteDataStore.default().removeData(
        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
        modifiedSince: .distantPast
    ) { }

    loginWebView = nil
    loginWindowController?.close()
    loginWindowController = nil
}
```

**Login window is a singleton** — if already open, bring to front instead of creating a new one:
```swift
func presentLogin() {
    guard loginWindowController == nil else {
        loginWindowController?.window?.makeKeyAndOrderFront(nil)
        return
    }
    // ... create WKWebView and window ...
}
```

References:
- [WKWebView Memory Retention (Apple Forums)](https://developer.apple.com/forums/thread/22795)
- [WKWebsiteDataStore (Apple Docs)](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)

### Settings (Minimal)
- Launch at login toggle (via `SMAppService`, macOS 13+)
- Low-usage notification threshold (default 20%), uses `UNUserNotificationCenter`
- Sign out (full teardown sequence: `stopPolling()` → `clearKeychain()` → `await removeWebsiteData()` → set `isAuthenticated = false`)

#### Research Insights: SMAppService

Always read status from `SMAppService.mainApp.status` rather than caching — the user can change login items in System Settings at any time. Re-read on toggle view appearance:

```swift
Toggle("Launch at login", isOn: $launchAtLogin)
    .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    .onChange(of: launchAtLogin) { newValue in  // Single-param form for macOS 13 compat
        do {
            if newValue { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled // Revert on failure
        }
    }
```

For development debugging, if registration starts failing: run `sfltool resetbtm` followed by a restart.

References:
- [SMAppService deep-dive (theevilbit)](https://theevilbit.github.io/posts/smappservice/)
- [Launch at login setting (Nil Coalescing)](https://nilcoalescing.com/blog/LaunchAtLoginSetting/)

## Technical Approach

### Architecture

```
ClaudeBattery/
  ClaudeBattery.xcodeproj
  ClaudeBattery/
    App/
      ClaudeBatteryApp.swift         # @main, AppDelegate, .accessory activation
    Services/
      AuthManager.swift              # WKWebView login, cookie capture, login window
      KeychainService.swift          # Keychain CRUD for sessionKey + orgId
      UsageService.swift             # async/await API client, polling timer, notifications
    Views/
      MenuBarController.swift        # NSStatusItem, icon rendering, click handling
      UsagePopoverView.swift         # SwiftUI popover content
      SettingsView.swift             # SwiftUI settings window
    Resources/
      ClaudeBattery.entitlements     # com.apple.security.network.client
      Info.plist                     # LSUIElement = YES
      Assets.xcassets/               # App icon
```

~7 source files, estimated 700-1000 lines total.

**Changes from original plan:**
- **Extracted `KeychainService`** from `AuthManager` — both `AuthManager` and `UsageService` need Keychain access. Without extraction, `UsageService` would depend on `AuthManager`, coupling the API layer to the auth UI layer.
- **Merged `NotificationService` into `UsageService`** — notification logic is ~20 lines tightly coupled to poll results. A separate file adds overhead for what amounts to a single `checkAndNotify()` method.
- **Merged `LoginWindowController` into `AuthManager`** — the login window is part of the auth flow. Splitting them requires a delegate/callback protocol with no benefit.
- **Merged `UsageModels` into `UsageService`** — the Codable structs are ~15 lines used only by `UsageService`.

**Dependency graph** (acyclic):
```
AppDelegate → AuthManager, UsageService, MenuBarController
AuthManager → KeychainService  (ObservableObject, publishes isAuthenticated)
UsageService → KeychainService  (ObservableObject, publishes latestUsage)
MenuBarController → AuthManager, UsageService  (observes via Combine sink)
UsagePopoverView → UsageService  (via @ObservedObject)
SettingsView → signOut closure  (passed at init, no direct AuthManager dependency)
```

### Data Source

**Primary endpoint**: `GET https://claude.ai/api/organizations/{orgId}/usage`

Response:
```json
{
  "five_hour": { "utilization": 42.0, "resets_at": "2026-02-15T10:00:00Z" },
  "seven_day": { "utilization": 35.0, "resets_at": "2026-02-18T04:00:00Z" },
  "seven_day_opus": { "utilization": 0.0, "resets_at": null },
  "seven_day_sonnet": { "utilization": 12.0, "resets_at": "2026-02-18T04:00:00Z" }
}
```

**Org discovery**: `GET https://claude.ai/api/organizations`

**Required headers** (Cloudflare bypass):
```
Cookie: sessionKey=sk-ant-sid01-...
anthropic-client-platform: web_claude_ai
anthropic-client-version: 1.0.0
User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ...
sec-fetch-dest: empty
sec-fetch-mode: cors
sec-fetch-site: same-origin
origin: https://claude.ai
referer: https://claude.ai/settings/usage
```

#### Research Insights: Header Spoofing Risk

These headers misrepresent the client identity. Anthropic/Cloudflare can detect non-browser clients via TLS fingerprint (JA3/JA4), HTTP/2 settings, and header ordering. The hardcoded `anthropic-client-version: 1.0.0` will drift from the actual web client version over time.

**Mitigation**: Document the ToS risk for users. The app should note it uses an undocumented API. Consider a remote configuration mechanism to update headers without shipping a new version (v2).

### App State

The app has two persistent states, not five. `LoggingIn` and `FetchingOrg` are transient async operations, not durable states. `Stale` is a display concern derived from `lastSuccessfulFetch`.

State lives directly on `UsageService` (which is the `@MainActor ObservableObject`) and `AuthManager` (which owns `isAuthenticated`). No separate `AppState` class — at this scale, a coordinator object adds indirection without benefit.

```swift
// On UsageService (ObservableObject, @MainActor):
@Published var latestUsage: UsageData?
@Published var lastSuccessfulFetch: Date?
@Published var consecutiveFailures: Int = 0

var isStale: Bool {
    guard let last = lastSuccessfulFetch else { return true }  // No data = stale
    return Date().timeIntervalSince(last) > 660  // 11 minutes (> 4x poll+tolerance)
}

// On AuthManager (ObservableObject, @MainActor):
@Published var isAuthenticated: Bool = false
```

**Login flow** is sequential async code, not a state machine:
```
present login window → capture cookie → clear data store → fetch org ID → start polling
```

**On launch with cached credentials**: Read Keychain → if sessionKey + orgId exist, set `isAuthenticated = true`, start polling immediately (no re-auth).

**On 401/403**: Clear Keychain, set `isAuthenticated = false`, stop polling, show re-auth prompt in popover.

**On 3+ consecutive non-auth failures**: Gray out the battery icon (distinct from template monochrome — use 50% alpha). Show last known data with "Last updated X min ago" in popover. Back off polling interval exponentially.

### UI States

Every visual state must be defined for the non-technical target audience:

| State | Menu Bar Icon | Popover Content |
|-------|--------------|-----------------|
| **Unauthenticated (first launch)** | Empty battery outline (template) | "Sign in to see your Claude usage" + Sign In button |
| **Authenticating** | Same as above | Login window open (popover shows same sign-in prompt) |
| **Loading (first fetch)** | Empty battery outline (template) | "Fetching usage..." with spinner |
| **Normal** | Filled battery + `58% 3d \| ▮ 92% 4h` | Progress bars, exact %, reset times, per-model breakdown |
| **Stale (>11 min)** | Battery at 50% alpha + last known data | Last data + "Last updated X min ago" warning |
| **Session expired** | Empty battery + `!` | "Session expired. Sign in again." + last data preserved below |
| **Error (10+ failures)** | Gray battery | "Unable to reach Claude. The app may need an update." + GitHub link |

**Re-authentication flow**: On 401/403, polling stops. The menu bar icon shows an empty battery with `!`. The popover shows the session-expired message with a "Sign In" button and preserves last-known data below it. No auto-presentation of login window — the user must click "Sign In" to re-authenticate.

**Cookie capture cancellation**: If the user closes the login window without completing login, treat as cancellation — return to unauthenticated state silently. If cookie capture does not fire within 5 minutes of navigation completion, show "Login timed out. Please try again." and close the window.

### API Field-to-Display Mapping

| API Field | UI Element | Display |
|-----------|-----------|---------|
| `seven_day.utilization` | Battery capsule fill + `%` text | `remaining = max(0, min(100, 100 - utilization))` |
| `seven_day.resets_at` | Countdown inside battery (`3d`, `18h`) | Show `--` if null |
| `five_hour.utilization` | Session indicator bar + `%` text | Same clamping formula |
| `five_hour.resets_at` | Session countdown (`4h`, `45m`) | Show `--` if null |
| `seven_day_opus` | Popover detail only | Optional per-model breakdown |
| `seven_day_sonnet` | Popover detail only | Optional per-model breakdown |

**Clamping**: Always clamp: `remaining = max(0, min(100, 100 - utilization))`. If utilization exceeds 100, display 0% remaining with red icon.

**Boundary conditions**: `< 20%` is red (exclusive — exactly 20% is monochrome). At 0%, battery is empty outline with `0%` text. At 100%, battery is fully filled.

**Icon color threshold is fixed at 20%** — independent of the configurable notification threshold. The notification threshold (default 20%) controls when alerts fire; the icon color is always `< 20%` = red.

### Popover Content

**Authenticated popover layout** (320x300 pt):
1. **Weekly Quota** — full-width progress bar, `58% remaining`, `Resets Feb 18 at 4:00 AM`
2. **Session** — full-width progress bar, `92% remaining`, `Resets in 4h 12m`
3. **Per-model breakdown** (if data exists) — smaller bars for Opus and Sonnet
4. **Last updated** — `Updated just now` / `Updated 3 min ago` / `Updated 12 min ago` (yellow warning if stale)
5. Footer — app version number

**Unauthenticated popover**: "Sign in to see your Claude usage" + Sign In button.

### Error Handling

Two categories, not six:

| Category | HTTP Status | Behavior |
|---|---|---|
| **Auth failure** | 401, 403 | Stop polling, clear session, show re-auth prompt in popover |
| **Everything else** | 429, 5xx, timeout, network error, HTML response | Increment `consecutiveFailures`, back off polling interval. After 3+, gray out icon (50% alpha). After 10+, show "app may need update" in popover. |

**Keychain locked errors**: Catch `errSecInteractionNotAllowed` (screen locked) — skip the poll without incrementing `consecutiveFailures`.

Cloudflare HTML detection is unnecessary — `JSONDecoder` will throw `DecodingError` on HTML, which routes into the "everything else" path naturally.

### Notification Logic

Merged into `UsageService`. Notify once when weekly remaining crosses below threshold:

```swift
private var didNotifyBelowThreshold = false

private func checkAndNotify(remaining: Double, threshold: Double) {
    if remaining < threshold && !didNotifyBelowThreshold {
        didNotifyBelowThreshold = true
        scheduleNotification(remaining: remaining)
    } else if remaining >= threshold {
        didNotifyBelowThreshold = false  // Reset when recovered
    }
}
```

Request notification permission on first toggle of the notification setting, not at launch.

#### Research Insights: UNUserNotificationCenter on macOS

- Set the delegate in `applicationDidFinishLaunching` or earlier — not lazily
- Implement `willPresent` delegate method to display notifications while the app is in foreground (menu bar apps are always "foreground")
- `.badge` authorization has no effect for `LSUIElement` apps (no dock icon to badge)
- Use `.banner` and `.sound` presentation options

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .sound])
}
```

### App Lifecycle
- **Wake from sleep**: Subscribe to `NSWorkspace.didWakeNotification`, poll immediately on wake, **reschedule the timer from now** (don't just add an extra poll — prevents double-firing)
- **Network loss**: No active monitoring — `URLSession.waitsForConnectivity = true` handles this
- **Launch at login**: `SMAppService.mainApp.register()` / `.unregister()`
- **Dock icon**: Set `LSUIElement = YES` in Info.plist statically. No dock icon, no app in Cmd-Tab.

#### Research Insights: App Nap Prevention

Menu bar apps (`LSUIElement`) have no visible windows, making them candidates for App Nap. Under App Nap, macOS applies timer throttling, reducing the 2-minute poll frequency. Prevent this:

```swift
private var activity: NSObjectProtocol?

func startPolling() {
    // Empty options prevents App Nap without claiming elevated priority.
    // This lets the 30-second timer tolerance work as intended for energy coalescing.
    activity = ProcessInfo.processInfo.beginActivity(
        options: [],
        reason: "Menu bar usage polling"
    )
    // ... start timer ...
}

func stopPolling() {
    timer?.invalidate()
    timer = nil
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
}
```

Retain the returned `NSObjectProtocol` reference for the duration of polling. An empty option set is sufficient — the activity assertion alone opts out of App Nap without requesting elevated scheduling priority that would defeat timer coalescing.

**`stopPolling()` must be called on sign-out** (when `isAuthenticated` transitions to `false`) and on `applicationWillTerminate` to release the activity and invalidate the timer.

References:
- [Apple: App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)
- [alt-tab-macos App Nap pattern](https://github.com/lwouis/alt-tab-macos/blob/master/src/ui/App.swift)

### WKWebView Cookie Capture (Critical Path)

This is the highest-risk technical component. Implementation details:

1. Register `WKHTTPCookieStoreObserver` **before** creating the WKWebView
2. Use `WKWebsiteDataStore.default()` (not `.nonPersistent()`) for SSO compatibility
3. "Prime" the cookie store with a dummy `getAllCookies` call before navigation
4. Inside `cookiesDidChange(in:)`, dispatch to main queue, call `getAllCookies`, filter for `sessionKey`
5. **Fallback**: Also check cookies in `webView(_:didFinish:)` for every navigation
6. Hold a strong reference to the observer (WebKit uses weak internally)
7. On successful capture: store cookie value in Keychain, **nil out the WKWebView** and window controller, begin org fetch

**Domain whitelisting** in `WKNavigationDelegate` — use strict suffix matching:
- Allow: `host == "claude.ai" || host.hasSuffix(".claude.ai")`
- Allow: `host.hasSuffix(".google.com")` (covers `accounts.google.com`, `consent.google.com`)
- Allow: `host.hasSuffix(".apple.com")` (covers `appleid.apple.com`, `gsa.apple.com`)
- Allow: `host.hasSuffix(".cloudflare.com")` (covers `challenges.cloudflare.com`)
- Block: everything else (log blocked host for debugging, not the full URL)

**SSO compatibility**: WKWebView handles Google SSO and Apple SSO as standard web redirects. No special handling needed beyond not blocking cross-domain navigation to the whitelisted SSO domains.

### Keychain Storage

```swift
// Service: Bundle.main.bundleIdentifier ?? "com.claudebattery"
// Account: "sessionKey" / "organizationId"
// Accessibility: kSecAttrAccessibleWhenUnlocked (only when device is actively unlocked)
// No iCloud Keychain sync
```

Store: `sessionKey` value and `organizationId` as two separate Keychain items.

#### Research Insights: Keychain Security

- Use `kSecAttrAccessibleWhenUnlocked` (not `kSecAttrAccessibleAfterFirstUnlock`) — the app is a menu bar widget only useful when the user is at their Mac. The stricter level prevents access when the screen is locked.
- Use the app's bundle identifier as the Keychain service, not a hardcoded string — prevents conflicts with other apps.
- Never log the cookie value. Use `Data` instead of `String` for in-memory handling where possible.
- Disable URLSession's default cookie handling: `config.httpShouldSetCookies = false` — set cookies manually via headers to prevent accidental leaking through URLSession logging.

### Icon Rendering

- Use `NSImage(size:flipped:drawingHandler:)` — Retina-safe, auto re-renders
- Icon height: 18 points (menu bar standard)
- `NSStatusItem.variableLength` for dynamic width
- `NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)` for stable digit rendering
- Template mode for monochrome, non-template for red low-battery

#### Research Insights: Drawing Handler

**Avoid retain cycles**: The drawing handler closure is retained by `NSImage`. Capture only value types (percentage, font, attributes) — never `self`. Assigning a new `NSImage` to `statusItem.button?.image` releases the previous one.

**Dark mode text color**: When `isTemplate = true` (normal), AppKit recolors everything — text color is irrelevant. When `isTemplate = false` (red battery at <20%), `NSColor.black` text is invisible against a dark menu bar. Use dynamic color:

```swift
private let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

func makeIcon(percentage: Int, resetText: String, isLowBattery: Bool) -> NSImage {
    // Capture values, NOT self — prevents retain cycle
    let fgColor: NSColor = isLowBattery ? .white : .black
    let attrs: [NSAttributedString.Key: Any] = [
        .font: digitFont,
        .foregroundColor: fgColor
    ]
    let image = NSImage(size: iconSize, flipped: false) { rect in
        let text = "\(percentage)%"
        text.draw(at: textOrigin, withAttributes: attrs)
        // ... draw battery outline, fill, etc.
        return true
    }
    image.isTemplate = !isLowBattery
    return image
}
```

### Polling Timer Configuration

```swift
private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    config.httpShouldSetCookies = false  // Set cookies manually via headers
    return URLSession(configuration: config)
}()

// Exponential backoff on failures
var pollInterval: TimeInterval {
    if consecutiveFailures < 3 { return 120 }   // 2 minutes (normal)
    if consecutiveFailures < 6 { return 300 }   // 5 minutes
    if consecutiveFailures < 10 { return 600 }  // 10 minutes
    return 1800                                   // 30 minutes max
}
```

Create exactly one `URLSession` instance and reuse it across sign-in/sign-out cycles (the session cookie is set per-request via headers, not on the session). `waitsForConnectivity = true` eliminates the need for manual reachability checking. Invalidate with `session.invalidateAndCancel()` only on app termination.

**Poll guard** — prevent concurrent polls (wake + timer overlap):
```swift
private var isPolling = false

func pollUsage() async {
    guard !isPolling else { return }
    isPolling = true
    defer { isPolling = false }
    // ... actual poll logic (URLSession, decode, update @Published) ...
}
```

**Wake-from-sleep handler** — await poll before rescheduling:
```swift
@objc func handleWake() {
    timer?.invalidate()
    Task {
        await pollUsage()
        scheduleNextPoll()  // Reset 2-minute timer from poll completion
    }
}

func scheduleNextPoll() {
    timer?.invalidate()  // Always invalidate before creating new timer
    timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
        Task { await self?.pollUsage() }
    }
    timer?.tolerance = 30
}
```

References:
- [Apple: Timer Coalescing](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
- [URLSessionConfiguration (SwiftLee)](https://www.avanderlee.com/swift/urlsessionconfiguration/)

### Dependencies

**Zero external dependencies.** All Apple frameworks:
- SwiftUI, AppKit (UI)
- WebKit (WKWebView login)
- Security (Keychain)
- ServiceManagement (launch at login)
- UserNotifications (alerts)
- Foundation (URLSession, JSONDecoder)

### Build & Distribution

- **Xcode project** (not Swift Package — need entitlements, Info.plist, asset catalog)
- **macOS 13+ (Ventura)** minimum deployment target
- **Not App Store** — undocumented API usage would violate review guidelines
- **Distribution**: Signed + notarized DMG via GitHub Releases (v1), Homebrew cask (future)
- **Code signing**: Developer ID Application certificate + hardened runtime (`--options runtime`)
- **Notarization**: Required for Gatekeeper. Submit DMG via `xcrun notarytool submit`, then staple with `xcrun stapler staple`

#### Research Insights: Distribution Pipeline

```bash
# 1. Code sign with hardened runtime (required for notarization)
codesign --force --verify --verbose \
  --sign "Developer ID Application: Your Name (TEAM_ID)" \
  --options runtime \
  --entitlements ClaudeBattery/ClaudeBattery.entitlements \
  ClaudeBattery.app

# 2. Create DMG (using create-dmg: npm install -g create-dmg)
create-dmg --overwrite --dmg-title "Claude Battery" ClaudeBattery.app dist/

# 3. Notarize
xcrun notarytool submit dist/ClaudeBattery.dmg --keychain-profile "ClaudeBattery" --wait

# 4. Staple (embeds ticket for offline verification)
xcrun stapler staple dist/ClaudeBattery.dmg
```

On Apple Silicon, unsigned native ARM64 code will not execute at all — Developer ID signing is not optional.

References:
- [Apple: Notarizing macOS Software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [create-dmg (Sindre Sorhus)](https://github.com/sindresorhus/create-dmg)

### State Management Pattern

Since the app targets macOS 13+, use `ObservableObject` (not `@Observable` which requires macOS 14+). No separate `AppState` class — each service is its own `ObservableObject` publishing only the state it owns.

```swift
@MainActor
class UsageService: ObservableObject {
    @Published var latestUsage: UsageData?
    @Published var lastSuccessfulFetch: Date?
    @Published private(set) var consecutiveFailures: Int = 0

    var isStale: Bool {
        guard let last = lastSuccessfulFetch else { return true }
        return Date().timeIntervalSince(last) > 660
    }
}

@MainActor
class AuthManager: ObservableObject {
    @Published var isAuthenticated: Bool = false
}
```

**`@MainActor` is required** — `@Published` triggers `objectWillChange` which must fire on the main thread. All state mutations happen on `@MainActor`; network calls use `await` on the cooperative pool, then dispatch results back via the actor.

**App struct + AppDelegate wiring**:

```swift
@main
struct ClaudeBatteryApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    var body: some Scene {
        Settings { SettingsView(signOut: { [weak appDelegate] in appDelegate?.signOut() }) }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // Stored as instance properties — NOT local variables (ARC would deallocate them)
    private var keychain: KeychainService!
    private var authManager: AuthManager!
    private var usageService: UsageService!
    private var menuBarController: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        keychain = KeychainService()
        authManager = AuthManager(keychain: keychain)
        usageService = UsageService(keychain: keychain)
        menuBarController = MenuBarController(
            authManager: authManager,
            usageService: usageService
        )
        // Set notification delegate early (before any permission requests)
        UNUserNotificationCenter.current().delegate = usageService
    }

    func signOut() {
        usageService.stopPolling()
        Task {
            await authManager.signOut()
        }
    }
}
```

**MenuBarController observes state via Combine** (AppKit cannot use `@ObservedObject`):

```swift
import Combine

class MenuBarController {
    private var cancellables = Set<AnyCancellable>()

    init(authManager: AuthManager, usageService: UsageService) {
        // Observe usage changes to update the icon
        usageService.$latestUsage
            .receive(on: RunLoop.main)
            .sink { [weak self] usage in self?.updateIcon(usage) }
            .store(in: &cancellables)

        // Observe auth state to show/hide sign-in prompt
        authManager.$isAuthenticated
            .receive(on: RunLoop.main)
            .sink { [weak self] isAuth in self?.updateAuthState(isAuth) }
            .store(in: &cancellables)
    }
}
```

## Implementation Phases

### Phase 1: Project Setup + Authentication

- Create Xcode project (macOS App, SwiftUI lifecycle, menu bar only)
- Set `LSUIElement = YES` in Info.plist
- Configure entitlements (`com.apple.security.network.client`)
- Implement `KeychainService` (CRUD for sessionKey + orgId)
- Implement `AuthManager` with WKWebView login + cookie capture
- Display URL in login window title bar
- Implement domain whitelisting in `WKNavigationDelegate`
- **Deallocate WKWebView after cookie capture** (nil out webView + window controller)
- **Validation**: Can sign in to claude.ai, capture sessionKey cookie, verify WKWebView is deallocated

### Phase 2: API Client + Polling

- Define Codable structs for API responses (inside `UsageService.swift`)
- Implement `UsageService` with async/await
- Build Cloudflare bypass headers
- Implement org ID discovery (`/api/organizations`)
- Implement usage polling with 2-minute `Timer` + 30-second tolerance
- Configure `URLSession` with `waitsForConnectivity`, bounded timeouts
- Handle error states: auth failure (401/403) vs everything else (retry)
- Prevent App Nap with `ProcessInfo.beginActivity`
- **Validation**: Successfully fetch and parse usage data from the API

### Phase 3: Menu Bar Icon Rendering

- Implement `MenuBarController` with `NSStatusItem`
- Draw battery capsule with fill level using `NSImage(size:flipped:drawingHandler:)`
- Cache font and text attributes outside drawing handler
- Render percentage text and reset countdown inside battery
- Draw session indicator (vertical bar + text)
- Implement monochrome/red color switching at 20% threshold
- **Validation**: Battery icon renders correctly, updates dynamically with mock data

### Phase 4: Popover + Context Menu

- Implement left-click/right-click discrimination
- Build `UsagePopoverView` in SwiftUI (progress bars, exact %, reset times)
- **Apply NSPopover focus fix**: `NSApp.activate(ignoringOtherApps: true)` + `makeKey()`
- Build right-click context menu (Settings, Quit)
- Handle popover dismissal (`.transient` behavior)
- **Validation**: Left-click shows popover with live data and keyboard focus, right-click shows menu

### Phase 5: Settings + Notifications

- Implement `SettingsView` (launch at login toggle, notification threshold, sign out)
- Implement notification logic in `UsageService` (`checkAndNotify` method)
- Set `UNUserNotificationCenter.delegate` in `applicationDidFinishLaunching`
- Implement `willPresent` delegate for foreground notification display
- Sign out flow: `stopPolling()` → clear Keychain → `await WKWebsiteDataStore.default().removeData(ofTypes:modifiedSince:)` → set `isAuthenticated = false`
- Launch at login via `SMAppService` (always re-read `.status`, never cache)
- **Validation**: Notifications fire once when crossing threshold, settings persist, sign out clears everything

### Phase 6: Polish

- Wake-from-sleep immediate poll + timer reschedule
- Handle `null` reset times in API response
- App icon for dock/About
- On-launch Keychain check (skip auth if credentials exist, start polling immediately)
- **Validation**: App handles sleep/wake and launches correctly with cached credentials

## Acceptance Criteria

### Functional Requirements
- [x] Battery icon in menu bar shows weekly quota remaining (0-100%) with fill level
- [x] Reset countdown shows days/hours/minutes until weekly quota reset
- [x] Session indicator shows 5-hour session usage remaining with reset time
- [x] Left-click opens popover with detailed usage breakdown
- [x] Right-click opens menu with Settings and Quit
- [x] "Sign In" button opens WKWebView with claude.ai login
- [x] Login window displays current URL in title bar
- [x] Session cookie captured automatically after login (no DevTools required)
- [x] WKWebView deallocated after cookie capture
- [x] Usage data refreshes every 2 minutes
- [x] Icon turns red when remaining drops below 20%
- [x] Notification fires when weekly remaining crosses below threshold (once per crossing)
- [x] Settings: launch at login, notification threshold, sign out
- [x] Sign out clears all stored credentials and returns to unauthenticated state

### Non-Functional Requirements
- [x] Zero external dependencies
- [x] macOS 13+ (Ventura) compatibility
- [x] Retina display rendering (crisp at all resolutions)
- [x] Proper dark mode / light mode support
- [x] Immediate poll on wake from sleep (with timer reschedule)
- [x] App Nap prevented during polling
- [x] Timer tolerance set for energy efficiency
- [x] Idle memory < 30 MB (WKWebView deallocated after login)
- [x] Graceful degradation on API errors (show last known data, gray out icon after 3+ failures)
- [ ] Developer ID signed + notarized for distribution

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Anthropic changes/removes the usage API | Medium | High | Monitor for schema changes, version the API client |
| WKWebView cookie capture fails for some login methods | Low | High | Test Google SSO, Apple SSO, email/password during Phase 1 |
| Cloudflare blocks API requests | Medium | Medium | Match headers exactly to browser behavior |
| Session cookies expire frequently | Low | Medium | Detect expiry promptly (401/403), make re-auth frictionless |
| Session cookie grants full account access (over-privileged) | N/A | Medium | Treat as critical secret: `kSecAttrAccessibleWhenUnlocked`, never log, zero in memory after use |
| App Nap throttles polling timer | Medium | Medium | Use `ProcessInfo.beginActivity` |

## Security Considerations

The session cookie is a full-privilege credential for the user's Claude account — not scoped to usage. This is inherent to the WKWebView approach (there is no scoped alternative). Mitigations:

1. **Keychain**: `kSecAttrAccessibleWhenUnlocked`, bundle identifier as service
2. **Cookie validation**: Verify captured cookie has `domain` ending in `claude.ai`, `isSecure == true`, `path == "/"`
3. **Login window**: Display URL in title bar, strict suffix-match domain whitelisting
4. **Data store**: Clear `WKWebsiteDataStore` immediately after cookie capture (don't leave cookie on disk until sign-out)
5. **Memory**: Never log cookie value. Keep cookie only in Keychain — retrieve per-request, don't cache in properties
6. **URLSession**: `httpShouldSetCookies = false`, set cookies manually via headers
7. **Sign out**: Full teardown: `stopPolling()` → clear Keychain → `await removeData(ofTypes:)` → set `isAuthenticated = false`

## References

### Brainstorm Document
- `docs/brainstorms/2026-02-15-claude-battery-brainstorm.md`

### API Reference (Community-Documented)
- [Usage4Claude](https://github.com/f-is-h/Usage4Claude) — API endpoint and header reference
- [Claude-Usage-Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) — Alternative implementation reference

### Apple Documentation
- [WKHTTPCookieStore](https://developer.apple.com/documentation/webkit/wkhttpcookiestore)
- [WKHTTPCookieStoreObserver](https://developer.apple.com/documentation/webkit/wkhttpcookiestoreobserver)
- [WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)
- [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [NSImage init(size:flipped:drawingHandler:)](https://developer.apple.com/documentation/appkit/nsimage/1519860-imagewithsize)
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter)
- [Timer Coalescing (Energy Efficiency Guide)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
- [App Nap (Energy Efficiency Guide)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)
- [Notarizing macOS Software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

### Platform-Specific Patterns
- [NSPopover focus fix (dagronf)](https://dagronf.wordpress.com/2020/03/04/why-does-my-nspopover-not-dismiss-which-clicking-outside-it/)
- [SMAppService deep-dive (theevilbit)](https://theevilbit.github.io/posts/smappservice/)
- [Showing Settings from Menu Bar Items (Peter Steinberger)](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items)
- [Hiding Dock Icon Properly (David Bures)](https://buresdv.substack.com/p/swift-protip-hiding-your-apps-icon)
- [URLSessionConfiguration (SwiftLee)](https://www.avanderlee.com/swift/urlsessionconfiguration/)
- [Network Reachability (SwiftLee)](https://www.avanderlee.com/swift/optimizing-network-reachability/)
- [create-dmg (Sindre Sorhus)](https://github.com/sindresorhus/create-dmg)

### Known Issues
- [WebKit Bug 188995](https://bugs.webkit.org/show_bug.cgi?id=188995) — WKHTTPCookieStoreObserver reliability
- [Apple Forums: WKWebView requires network.client entitlement](https://developer.apple.com/forums/thread/116359)
- [Apple Forums: NSPopover not rendering on Sonoma](https://developer.apple.com/forums/thread/738463)
