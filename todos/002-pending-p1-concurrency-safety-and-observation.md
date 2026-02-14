---
status: pending
priority: p1
issue_id: "002"
tags: [code-review, concurrency, swift, mainactor]
dependencies: ["001"]
---

# Add @MainActor Isolation and Combine Observation

## Problem Statement

The plan mutates `@Published` properties from background Tasks without main-thread isolation, and the primary UI component (MenuBarController) has no defined mechanism to observe state changes.

## Findings

- **@Published mutations from background Tasks (Architecture P2-3, Pattern P1-2):** `pollUsage()` runs via `Task { await self?.pollUsage() }` on the cooperative thread pool, then presumably updates `@Published` properties. `@Published` triggers `objectWillChange` which must fire on the main thread. No `@MainActor` annotation exists anywhere in the plan.

- **MenuBarController has no observation mechanism (Pattern P1-3):** The dependency graph says MenuBarController "receives data via published properties" but `MenuBarController` is an AppKit class (not a SwiftUI view). AppKit classes don't natively observe `@Published`. The plan never mentions Combine's `sink` or any subscription mechanism.

- **Overlapping polls race condition (Performance P1-3, Pattern P3-5):** The wake handler starts a new `Task { await pollUsage() }` and immediately calls `scheduleNextPoll()`. If a poll is already in-flight, two polls can run concurrently, both mutating state.

- **Swift 6 Sendable (Pattern P3-2):** No `@Sendable` or `@MainActor` planning for Swift 6 strict concurrency.

## Proposed Solutions

### Option 1: @MainActor on state holder + Combine subscription + poll guard

**Approach:**
1. Annotate the state-owning class (AppState or UsageService) with `@MainActor`
2. Add Combine subscription in MenuBarController
3. Add `isPolling` guard to prevent concurrent polls

```swift
// 1. Main actor isolation
@MainActor
class UsageService: ObservableObject { ... }

// 2. Combine subscription in MenuBarController
appState.$latestUsage
    .receive(on: RunLoop.main)
    .sink { [weak self] usage in self?.updateIcon(usage) }
    .store(in: &cancellables)

// 3. Poll guard
private var isPolling = false
func pollUsage() async {
    guard !isPolling else { return }
    isPolling = true
    defer { isPolling = false }
    // ... actual poll logic
}
```

**Pros:**
- Prevents undefined behavior from cross-thread @Published mutations
- Gives MenuBarController a concrete update path
- Prevents overlapping polls

**Cons:**
- Requires `import Combine` in MenuBarController

**Effort:** 30 minutes (plan update)

**Risk:** Low

## Recommended Action

*To be filled during triage.*

## Technical Details

**Affected plan sections:**
- Lines 438-440 (polling timer)
- Lines 447-453 (wake handler)
- Lines 508-519 (AppState)
- Lines 206-213 (dependency graph)

**Agents that flagged this:**
- Architecture Strategist (P2-3)
- Performance Oracle (P1-3)
- Pattern Recognition Specialist (P1-2, P1-3, P3-2, P3-5)

## Acceptance Criteria

- [ ] State-owning class annotated with `@MainActor`
- [ ] MenuBarController shows explicit Combine subscription to state changes
- [ ] Poll guard prevents concurrent pollUsage() calls
- [ ] Wake handler restructured to await poll before rescheduling

## Work Log

### 2026-02-15 - Initial Discovery

**By:** Claude Code (Technical Review)

**Actions:**
- 3 agents independently flagged @MainActor omission
- Performance Oracle identified the wake handler race as most likely to manifest in production (laptop lid close/open)
- Pattern Recognition confirmed MenuBarController has no observation path at all
