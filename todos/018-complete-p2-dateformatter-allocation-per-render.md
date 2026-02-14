---
status: complete
priority: p2
issue_id: "018"
tags: [code-review, performance, swiftui]
dependencies: []
---

# DateFormatter Allocated on Every Popover Render

## Problem Statement

`UsagePopoverView.formatResetDate()` creates a new `DateFormatter` instance on every call. `DateFormatter` allocation is expensive (~5ms per init) and this method is called multiple times during each SwiftUI view render.

Found by: Performance Oracle (OPT-1), Pattern Recognition Specialist (LOW)

## Findings

- **Location:** `UsagePopoverView.swift` — `formatResetDate()` method
- **Evidence:** `let formatter = DateFormatter()` inside the method body
- **Impact:** Measurable view render latency on each popover open and during state updates

## Proposed Solutions

### Solution A: Static DateFormatter (Recommended)
- Move DateFormatter to a `static let` property
- **Pros:** Zero allocation on each call, standard Swift pattern
- **Cons:** None
- **Effort:** Small
- **Risk:** Low

## Technical Details

- **Affected files:** `UsagePopoverView.swift`

## Acceptance Criteria

- [ ] DateFormatter is allocated once (static or cached)
- [ ] Formatting still works correctly

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
