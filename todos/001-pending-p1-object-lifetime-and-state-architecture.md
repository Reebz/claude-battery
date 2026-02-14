---
status: pending
priority: p1
issue_id: "001"
tags: [code-review, architecture, correctness, swift]
dependencies: []
---

# Fix Object Lifetime, Wiring, and State Architecture

## Problem Statement

Multiple critical issues with the plan's object lifecycle and state management that would prevent the app from running at all or cause immediate deallocation of all services.

## Findings

- **Local variables deallocated by ARC (Pattern P1-4, Architecture P1-2):** `applicationDidFinishLaunching` creates all services as local `let` bindings. When the method returns, ARC deallocates everything — NSStatusItem, polling timer, the entire app goes blank.
  - Location: Plan lines 525-531

- **AppState overlapping ownership (Architecture P1-1, Simplicity P1-1, Pattern P1-1):** State is defined in two places — lines 254-266 say "in UsageService or a shared state holder" and lines 508-519 define a separate `AppState: ObservableObject`. This creates ambiguity about who owns the state.

- **AppState premature abstraction (Simplicity P1-1):** Simplicity reviewer argues AppState should not exist as a separate class — UsageService itself should be the ObservableObject since it's the sole data producer.

- **@NSApplicationDelegateAdaptor missing (Pattern P2-3):** Plan says "SwiftUI lifecycle" but uses `AppDelegate.applicationDidFinishLaunching` without showing how the AppDelegate integrates with the SwiftUI `App` struct.

## Proposed Solutions

### Option 1: Store as AppDelegate instance properties + show @NSApplicationDelegateAdaptor

**Approach:** Make all services instance properties of AppDelegate. Show the full SwiftUI App struct with `@NSApplicationDelegateAdaptor`. Collapse AppState into UsageService as the ObservableObject.

```swift
@main
struct ClaudeBatteryApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    var body: some Scene {
        Settings { SettingsView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var keychain: KeychainService!
    private var authManager: AuthManager!
    private var usageService: UsageService!  // IS the ObservableObject
    private var menuBarController: MenuBarController!
}
```

**Pros:**
- Fixes the immediate ARC deallocation crash
- Removes the AppState abstraction (simpler)
- Shows the complete wiring pattern

**Cons:**
- UsageService becomes both data fetcher and state holder (SRP trade-off, but acceptable at this scale)

**Effort:** 30 minutes (plan update)

**Risk:** Low

## Recommended Action

*To be filled during triage.*

## Technical Details

**Affected plan sections:**
- Lines 254-266 (App State)
- Lines 508-519 (State Management Pattern)
- Lines 525-531 (applicationDidFinishLaunching)
- Lines 538 (Phase 1)

**Agents that flagged this:**
- Architecture Strategist (P1-1, P1-2)
- Code Simplicity Reviewer (P1-1, P1-2)
- Pattern Recognition Specialist (P1-1, P1-4, P2-3)

## Acceptance Criteria

- [ ] All services stored as AppDelegate instance properties (not local variables)
- [ ] `@NSApplicationDelegateAdaptor` shown in App struct
- [ ] Single owner for all published state (either AppState or UsageService, not both)
- [ ] No ambiguous "or" language about state ownership

## Work Log

### 2026-02-15 - Initial Discovery

**By:** Claude Code (Technical Review)

**Actions:**
- 3 of 6 review agents independently flagged these issues
- The ARC deallocation bug (P1-4) would cause a blank/crashing app immediately on launch
- Cross-agent consensus: AppState as separate class adds complexity without benefit at this scale
