---
status: complete
priority: p1
issue_id: "009"
tags: [code-review, performance, energy, macos]
dependencies: []
---

# beginActivity(options: []) Prevents System Idle Sleep

## Problem Statement

`ProcessInfo.beginActivity(options: [])` in `UsageService.swift` passes an empty option set, which in Apple's API means **all flags are set** — including `.idleSystemSleepDisabled`. This prevents the entire Mac from sleeping while the app is running, draining battery unnecessarily.

Found by: Performance Oracle (CRITICAL-1), Code Simplicity Reviewer

## Findings

- **Location:** `UsageService.swift` — `startPolling()` method
- **Evidence:** Empty `OptionSet` in Swift initializes with all bits set. Apple docs confirm `ProcessInfo.ActivityOptions` follows this pattern.
- **Impact:** Users' Macs will never idle-sleep while ClaudeBattery is running, causing significant battery drain on laptops.
- **Simplicity note:** The Code Simplicity Reviewer additionally flagged that App Nap prevention may be unnecessary entirely — a 2-minute polling interval is coarse enough that App Nap delays won't meaningfully affect the user experience.

## Proposed Solutions

### Solution A: Use correct options (Recommended)
- Use `.idleDisplaySleepDisabled` only if needed, or more likely just `.userInitiated` reason string
- **Pros:** Fixes the bug, minimal change
- **Cons:** Still prevents some power saving
- **Effort:** Small
- **Risk:** Low

### Solution B: Remove beginActivity entirely
- Remove App Nap prevention. Let macOS manage the app normally.
- Timer fires will still work (just slightly delayed by App Nap).
- **Pros:** Simplest, most energy-efficient, no side effects
- **Cons:** Poll may be delayed by seconds when app is in background
- **Effort:** Small
- **Risk:** Low — polling delay is acceptable for a status display

### Solution C: Use .latencyCritical only
- `ProcessInfo.beginActivity(options: [.latencyCritical], reason: "Polling usage API")`
- **Pros:** Prevents App Nap without preventing system sleep
- **Cons:** Slightly more energy than Solution B
- **Effort:** Small
- **Risk:** Low

## Recommended Action

Solution B — remove `beginActivity` entirely. A menu bar usage display does not need sub-second timer accuracy.

## Technical Details

- **Affected files:** `ClaudeBattery/ClaudeBattery/Services/UsageService.swift`
- **Components:** Energy management, polling timer

## Acceptance Criteria

- [ ] `ProcessInfo.beginActivity` with empty options is removed
- [ ] Mac can idle-sleep normally with ClaudeBattery running
- [ ] Polling still works (possibly with slight App Nap delay)

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |

## Resources

- [Apple ProcessInfo.ActivityOptions docs](https://developer.apple.com/documentation/foundation/processinfo/activityoptions)
