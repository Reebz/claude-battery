---
status: complete
priority: p1
issue_id: "011"
tags: [code-review, performance, combine, ui]
dependencies: []
---

# combineLatest of 4 Publishers Causes Redundant Icon Redraws

## Problem Statement

`MenuBarController.setupObservers()` uses `combineLatest` with 4 publishers (`latestUsage`, `consecutiveFailures`, `lastSuccessfulFetch`, `isAuthenticated`). After each poll, up to 3 of these publishers fire sequentially, causing 3 redundant `updateIcon()` calls and 3 redundant `NSImage` allocations per poll cycle.

Found by: Performance Oracle (CRITICAL-3), Code Simplicity Reviewer

## Findings

- **Location:** `MenuBarController.swift:50-62`
- **Evidence:** `combineLatest` fires the sink for every individual publisher change. A single poll updates `latestUsage`, `consecutiveFailures`, and `lastSuccessfulFetch` — that's 3 sink invocations.
- **Impact:** 3x unnecessary NSImage creation per poll (every 2 minutes). Each image involves text measurement and drawing.
- **Simplicity note:** `updateIcon()` only reads `usage` and `isAuthenticated`. The other two values (`consecutiveFailures`, `lastSuccessfulFetch`) are accessed directly from `usageService` inside `updateIcon()` anyway.

## Proposed Solutions

### Solution A: Observe only 2 publishers (Recommended)
- Use `combineLatest` with only `$latestUsage` and `$isAuthenticated`
- Access `consecutiveFailures` and `lastSuccessfulFetch` directly from `usageService` inside `updateIcon()`
- **Pros:** Eliminates 2 of 3 redundant redraws, simplifies code
- **Cons:** None — the values are already read from the service
- **Effort:** Small
- **Risk:** Low

### Solution B: Add throttle/debounce
- Add `.debounce(for: .milliseconds(100))` to the pipeline
- **Pros:** Coalesces all publisher changes into one redraw
- **Cons:** Adds latency, more complex, still subscribes to unused publishers
- **Effort:** Small
- **Risk:** Low

## Recommended Action

Solution A — observe only the 2 publishers that actually need to trigger redraws.

## Technical Details

- **Affected files:** `ClaudeBattery/ClaudeBattery/Views/MenuBarController.swift`

## Acceptance Criteria

- [ ] `setupObservers()` uses `combineLatest` with only 2 publishers
- [ ] Icon still updates correctly for all state changes
- [ ] No redundant redraws per poll cycle

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
