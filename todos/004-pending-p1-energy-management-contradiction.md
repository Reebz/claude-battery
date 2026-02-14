---
status: pending
priority: p1
issue_id: "004"
tags: [code-review, energy, performance, app-nap]
dependencies: []
---

# Fix beginActivity Option Contradicting Timer Tolerance

## Problem Statement

The plan uses `.userInitiatedAllowingIdleSystemSleep` for `ProcessInfo.beginActivity` which is the second-highest activity priority. This directly contradicts the 30-second timer tolerance set on the same timer, since the activity level tells the system "do not defer timers" while the tolerance says "you can defer by 30 seconds."

## Findings

- **Contradiction (Performance P1-2):** `.userInitiatedAllowingIdleSystemSleep` prevents timer coalescing, CPU throttling, and I/O throttling. The 30-second timer tolerance becomes meaningless because the system won't defer the timer anyway.
  - Location: Plan lines 336-351 (beginActivity) and line 441 (timer tolerance)

- The actual goal is to prevent App Nap only. An empty option set to `beginActivity` is sufficient to opt out of App Nap without requesting elevated scheduling priority.

## Proposed Solutions

### Option 1: Empty option set (Recommended)

**Approach:** Pass an empty option set. The activity assertion alone prevents App Nap without claiming user-initiated priority.

```swift
activity = ProcessInfo.processInfo.beginActivity(
    options: [],
    reason: "Menu bar usage polling"
)
```

**Pros:**
- Prevents App Nap (the actual goal)
- Timer tolerance works as intended
- No energy waste from elevated priority

**Cons:**
- None

**Effort:** 5 minutes (plan update)

**Risk:** Low

---

### Option 2: .idleSystemSleepDisabled only

**Approach:** Use `.idleSystemSleepDisabled` if you also want to prevent the system from sleeping during active polling.

**Pros:**
- Prevents both App Nap and system sleep

**Cons:**
- System sleep prevention may not be desired for a passive poller

**Effort:** 5 minutes

**Risk:** Low

## Recommended Action

*To be filled during triage.*

## Technical Details

**Affected plan sections:**
- Lines 336-351 (App Nap prevention)
- Line 441 (timer tolerance)

**Agents that flagged this:**
- Performance Oracle (P1-2) — identified as the most actionable finding in the entire review

## Acceptance Criteria

- [ ] `beginActivity` uses empty options `[]` or `.idleSystemSleepDisabled`
- [ ] Timer tolerance and activity level are consistent
- [ ] Plan documents that App Nap prevention is the goal, not elevated priority

## Work Log

### 2026-02-15 - Initial Discovery

**By:** Claude Code (Technical Review)

**Actions:**
- Performance Oracle identified this as a direct contradiction introduced during the deepening round
- Both the activity level and timer tolerance were added in the same deepening pass but are incompatible
