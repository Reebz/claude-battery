---
title: "Keychain Credential Storage Loop & Auth System Hardening"
date: 2026-02-25
category: security-issues
tags:
  - keychain
  - authentication
  - urlsession
  - oauth
  - race-condition
  - security
  - wkwebview
  - polling
  - concurrency
severity:
  - CRITICAL
  - P1
  - P2
  - P3
component:
  - ClaudeAPI
  - AuthManager
  - UsageService
  - StorageService
symptoms:
  - "Infinite Keychain password dialog: 'ClaudeBattery wants to use confidential information stored in com.claudebattery.app in your keychain'"
  - "Polling restart after wake/account-switch silently dropped by isPolling guard"
  - "WKWebView login session cookies persisted to disk"
  - "Domain allowlist vulnerable to subdomain spoofing on OAuth providers"
  - "Timer-spawned polls not cancellable by stopPolling()"
technology:
  - Swift
  - SwiftUI
  - AppKit
  - URLSession
  - WKWebView
  - macOS
root_cause: "URLSessionConfiguration.default stores HTTP credentials in the system Keychain. When claude.ai returns 401/403, URLSession attempts automatic credential lookup, triggering the Keychain dialog in an infinite loop."
---

# Keychain Credential Storage Loop & Auth System Hardening

## Problem

After deploying v1.2, users encountered an infinite macOS Keychain dialog: *"ClaudeBattery wants to use confidential information stored in com.claudebattery.app in your keychain"*. The app became unusable as the dialog reappeared immediately after dismissal.

This was the most visible of 11 issues identified through a deep code review of the auth and usage polling system.

## Investigation

1. Searched codebase for `SecItem`, `kSecClass`, Keychain API calls -- **none found**
2. The app uses `UserDefaults` for storage (no direct Keychain usage)
3. Identified `URLSessionConfiguration.default` in `ClaudeAPI.swift` as the source
4. `.default` configuration includes system `urlCredentialStorage` backed by the Keychain
5. When claude.ai API returns 401/403 (expired session), `URLSession` automatically queries the Keychain for stored credentials, triggering the system dialog

## Root Cause

`URLSessionConfiguration.default` automatically integrates with the macOS Keychain through its `urlCredentialStorage` property. The app manually sets `Cookie` headers but never disabled the credential storage, so `URLSession` was:

1. Receiving 401/403 from expired sessions
2. Querying Keychain for stored credentials for `claude.ai`
3. Triggering the system password dialog
4. Finding no valid credentials, retrying the request
5. Repeating infinitely

## Solution

### CRITICAL: Ephemeral URLSession (prevents Keychain access entirely)

**`ClaudeAPI.swift`**

```swift
// BEFORE
static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = false
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    return URLSession(configuration: config)
}()

// AFTER
static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    return URLSession(configuration: config)
}()
```

Three layers of defense:
- **`.ephemeral`** -- no persistent storage of any kind
- **`httpCookieStorage = nil`** -- no cookie jar (cookies set manually via header)
- **`urlCredentialStorage = nil`** -- no Keychain credential lookups

### P1: Race Condition in Polling Restart

**`UsageService.swift`** -- Both `switchAccount()` and `handleWake()` called `startPolling()` directly, which was silently dropped by the `isPolling` guard when a poll was in-flight.

```swift
// BEFORE
@objc private func handleWake() {
    guard accountStore.activeAccount != nil, !authFailed else { return }
    startPolling()  // silently dropped if isPolling == true
}

// AFTER
@objc private func handleWake() {
    guard accountStore.activeAccount != nil, !authFailed else { return }
    restartPolling()
}

/// Chains a new poll after the previous task completes its `defer { isPolling = false }`,
/// preventing the race where a new poll is silently dropped by the isPolling guard.
private func restartPolling() {
    let previousTask = currentPollTask
    stopPolling()
    currentPollTask = Task {
        _ = await previousTask?.value  // wait for in-flight poll to exit
        guard !Task.isCancelled else { return }
        await pollUsage()
    }
    scheduleNextPoll()
}
```

### P1: Persistent WKWebView Data Store

**`AuthManager.swift`** -- Login WebView used `.default()` which persists cookies to disk.

```swift
// BEFORE
let config = WKWebViewConfiguration()
// defaults to WKWebsiteDataStore.default() -- persistent

// AFTER
let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()
```

### P1: Domain Allowlist Tightening

**`AuthManager.swift`** -- OAuth providers now use exact match, not `hasSuffix`.

```swift
private func isAllowedDomain(_ host: String) -> Bool {
    host == "claude.ai" ||
    host.hasSuffix(".claude.ai") ||
    host.hasSuffix(".anthropic.com") ||
    host == "accounts.google.com" ||           // exact match
    host.hasSuffix(".accounts.google.com") ||   // subdomains with leading dot
    host == "appleid.apple.com" ||              // exact match
    host.hasSuffix(".appleid.apple.com") ||
    host.hasSuffix(".icloud.com") ||
    host.hasSuffix(".challenges.cloudflare.com") ||
    host == "cf-chl-widget.cloudflare.com"
}
```

### P2: Timer-Spawned Polls Not Tracked

**`UsageService.swift`** -- Timer callback now assigns to `currentPollTask` so `stopPolling()` can cancel it.

```swift
private func scheduleNextPoll() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: false) { [weak self] _ in
        Task { @MainActor in
            guard let self else { return }
            self.currentPollTask = Task {     // tracked for cancellation
                await self.pollUsage()
            }
            _ = await self.currentPollTask?.value
            self.scheduleNextPoll()
        }
    }
    timer?.tolerance = 30
}
```

### P2: Extracted Cookie Detection Helper

**`AuthManager.swift`** -- Consolidated 3 duplicate checks into one static helper.

```swift
private static func isSessionCookie(_ cookie: HTTPCookie) -> Bool {
    cookie.name == "sessionKey" &&
    (cookie.domain == "claude.ai" || cookie.domain == ".claude.ai")
}

// Used as: cookies.first(where: Self.isSessionCookie)
```

### P2: Log Levels & Naming

- Cookie/navigation logging changed from `.info` to `.debug` (not persisted in release builds)
- `KeychainService` renamed to `StorageService` (class uses UserDefaults, not Keychain)

### P3: Code Organization

- `ClaudeAPI` enum extracted from KeychainService.swift into its own `ClaudeAPI.swift`
- Shortened over-explained comment in `isAllowedDomain`
- Added early-exit guard in `cookiesDidChange` before async `allCookies()` call

## Prevention Rules

### Never Use `.default` URLSession for Authenticated Requests

Always use `.ephemeral` with explicit nil storage when the app manages its own auth headers:

```swift
let config = URLSessionConfiguration.ephemeral
config.httpCookieStorage = nil
config.urlCredentialStorage = nil
```

### Always Chain Polling Restarts Through Previous Task

Never call `startPolling()` if a poll might be in-flight. Use a restart helper that awaits the previous task:

```swift
private func restartPolling() {
    let previousTask = currentPollTask
    stopPolling()
    currentPollTask = Task {
        _ = await previousTask?.value
        guard !Task.isCancelled else { return }
        await pollUsage()
    }
    scheduleNextPoll()
}
```

### Always Use Non-Persistent WebView Stores for Auth Flows

```swift
config.websiteDataStore = .nonPersistent()
```

### Use Exact Match for OAuth Provider Domains

`hasSuffix` is acceptable for first-party domains where false positives are harmless. For third-party OAuth providers, use `==` for the apex and `hasSuffix` with leading `.` for subdomains.

## Code Review Checklist

For any PR touching networking, auth, or WebView:

- [ ] URLSession uses `.ephemeral` (not `.default`) for API requests
- [ ] `urlCredentialStorage` is explicitly nil
- [ ] `httpCookieStorage` is explicitly nil
- [ ] WKWebView uses `.nonPersistent()` data store
- [ ] Domain validation uses exact match for third-party OAuth providers
- [ ] All Timer instances are stored and invalidated on cleanup
- [ ] All spawned Tasks are assigned to tracked properties
- [ ] Polling restart awaits previous in-flight task
- [ ] No auth tokens/cookies logged at `.info` level or above
- [ ] Class names accurately reflect their storage mechanism

## Anti-Patterns to Avoid

| Anti-Pattern | Why It Fails | Correct Approach |
|---|---|---|
| `URLSessionConfiguration.default` for auth requests | Keychain credential storage triggers system dialogs | Use `.ephemeral` with nil storage |
| `startPolling()` while poll in-flight | `isPolling` guard silently drops the new poll | Use `restartPolling()` that chains after previous |
| `WKWebsiteDataStore.default()` for login | Persists session cookies to disk | Use `.nonPersistent()` |
| `host.hasSuffix("accounts.google.com")` | Matches `evilaccounts.google.com` | Use `host == "accounts.google.com"` |
| Timer callback without `currentPollTask` assignment | `stopPolling()` can't cancel in-flight work | Assign Task to tracked property |

## Related Documentation

- [Auth review findings hardening plan](../../plans/2026-02-24-fix-auth-review-findings-hardening-plan.md)
- [Auth login failure plan](../../plans/2026-02-23-fix-auth-login-failure-plan.md)
- [Fetching usage hang bug plan](../../plans/2026-02-19-fix-fetching-usage-hang-bug-plan.md)
- [Auth failure polling state machine hang](../logic-errors/auth-failure-polling-state-machine-hang.md)
- [Critical patterns](../patterns/critical-patterns.md)

## Files Changed

- `ClaudeBattery/Services/ClaudeAPI.swift` -- ephemeral URLSession config
- `ClaudeBattery/Services/AuthManager.swift` -- nonPersistent WebView, domain allowlist, cookie helper, log levels
- `ClaudeBattery/Services/UsageService.swift` -- restartPolling(), timer tracking, handleWake fix
- `ClaudeBattery/Services/StorageService.swift` -- renamed from KeychainService.swift
- `ClaudeBattery/App/ClaudeBatteryApp.swift` -- updated service wiring
