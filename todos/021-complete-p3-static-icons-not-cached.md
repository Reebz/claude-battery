---
status: complete
priority: p3
issue_id: "021"
tags: [code-review, performance, caching]
dependencies: []
---

# Static Icons Recreated on Every Call

## Problem Statement

`makeUnauthenticatedIcon()`, `makeLoadingIcon()`, and `makeErrorIcon()` create new `NSImage` instances every time they're called, even though their output never changes. These could be cached as static properties.

Found by: Performance Oracle (OPT-2)

## Findings

- **Location:** `MenuBarController.swift` — `makeUnauthenticatedIcon()`, `makeLoadingIcon()`, `makeErrorIcon()`
- **Impact:** Minor — these are called infrequently (only on state transitions). But caching is trivial.

## Proposed Solutions

### Solution A: Lazy static properties (Recommended)
- Create icons once as `lazy var` properties on MenuBarController
- **Pros:** Zero-cost after first call
- **Effort:** Small
- **Risk:** Low

## Technical Details

- **Affected files:** `MenuBarController.swift`

## Acceptance Criteria

- [ ] Static icons created once and reused

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
