---
status: complete
priority: p1
issue_id: "010"
tags: [code-review, bug, ui, drawing]
dependencies: []
---

# makeStaleIcon() Drawing Bug — No-Op Fill

## Problem Statement

`makeStaleIcon()` in `MenuBarController.swift` calls `lockFocus()`, `setFill()`, then `unlockFocus()` without actually drawing a fill path. The stale icon is visually identical to the loading icon, meaning users get no visual feedback when data is stale.

Found by: Pattern Recognition Specialist (HIGH), Performance Oracle (OPT-3), Code Simplicity Reviewer

## Findings

- **Location:** `MenuBarController.swift:306-312`
- **Evidence:** `icon.lockFocus(); NSColor.black.withAlphaComponent(0.5).setFill(); icon.unlockFocus()` — `setFill()` only sets the current fill color but doesn't draw anything. A `NSBezierPath.fill()` or `NSRectFill()` call is needed.
- **Additional:** `lockFocus/unlockFocus` is deprecated in macOS 12+ in favor of `NSImage(size:flipped:drawingHandler:)`.
- **Impact:** Stale state is invisible to users. They see the same "..." loading icon whether the app is loading or has stale data.

## Proposed Solutions

### Solution A: Remove makeStaleIcon, use loading icon with alpha (Recommended)
- Apply alpha to the loading icon image itself to show staleness
- Or add a small indicator (e.g., "?" instead of "...") to differentiate
- **Pros:** Simple, removes dead code
- **Cons:** Need to decide on visual differentiation
- **Effort:** Small
- **Risk:** Low

### Solution B: Fix the drawing code
- Replace lockFocus/unlockFocus with proper overlay drawing in a new NSImage drawingHandler
- **Pros:** Preserves intended design
- **Cons:** More code, uses pattern that was already buggy
- **Effort:** Small
- **Risk:** Low

## Recommended Action

Solution A — the simplest fix. The stale icon should look visually distinct from loading. Consider drawing the loading icon at reduced alpha or using a "?" character instead of "...".

## Technical Details

- **Affected files:** `ClaudeBattery/ClaudeBattery/Views/MenuBarController.swift`

## Acceptance Criteria

- [ ] Stale state is visually distinguishable from loading state
- [ ] No deprecated lockFocus/unlockFocus usage
- [ ] updateIcon correctly routes to stale visual when appropriate

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
