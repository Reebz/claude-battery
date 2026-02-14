---
status: complete
priority: p2
issue_id: "019"
tags: [code-review, performance, drawing]
dependencies: []
---

# Redundant Text Measurement in makeBatteryIcon

## Problem Statement

`makeBatteryIcon()` in `MenuBarController.swift` measures text strings twice — once in `computeIconWidth()` to calculate the total width, then again in the drawing handler when positioning text. This results in 8 `NSString.size(withAttributes:)` calls when 4 would suffice.

Found by: Performance Oracle (CRITICAL-2)

## Findings

- **Location:** `MenuBarController.swift` — `makeBatteryIcon()` and `computeIconWidth()`
- **Evidence:** `computeIconWidth()` measures all 4 text strings, then the drawing handler re-measures them for positioning
- **Impact:** Each text measurement involves font metric calculations. Doubled work on every icon update.

## Proposed Solutions

### Solution A: Compute sizes once and pass to drawing handler (Recommended)
- Calculate all text sizes upfront, pass them into the drawing handler
- Use the same sizes for both width computation and positioning
- **Pros:** Eliminates 4 redundant measurements
- **Cons:** Slightly different code structure
- **Effort:** Small
- **Risk:** Low

## Technical Details

- **Affected files:** `MenuBarController.swift`

## Acceptance Criteria

- [ ] Each text string measured only once per icon render
- [ ] Icon still renders correctly at all percentage values

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
