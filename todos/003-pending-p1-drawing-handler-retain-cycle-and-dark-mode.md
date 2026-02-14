---
status: pending
priority: p1
issue_id: "003"
tags: [code-review, memory, rendering, dark-mode]
dependencies: []
---

# Fix Drawing Handler Retain Cycle and Dark Mode Text Color

## Problem Statement

The NSImage drawing handler captures `self` strongly (retain cycle in a long-running app), and the hardcoded `NSColor.black` text color is invisible in dark mode when the battery icon switches to non-template mode at <20%.

## Findings

- **Retain cycle (Performance P1-1, Architecture P3-6, Pattern P2-6):** `self.textAttributes` inside the drawing handler closure creates: `MenuBarController` -> `NSStatusItem` -> `NSImage` -> drawing handler -> `self`. In a long-running menu bar app, even small leaks compound over days/weeks.
  - Location: Plan lines 413-419

- **Dark mode invisibility (Performance P2-5, Pattern P3-1):** When `isTemplate = false` (red battery at <20%), `NSColor.black` renders literally as black text — invisible against a dark mode menu bar. The `lazy var` means text attributes are computed once and never updated.
  - Location: Plan lines 407-409

- **Performance P1-1 additional note:** Old NSImage objects and their closures are not explicitly released. The plan should note that `statusItem.button?.image = newImage` releases the prior image.

## Proposed Solutions

### Option 1: Capture values, not self; dynamic text color

**Approach:** Capture `textAttributes` as a local variable. Use dynamic color based on template mode.

```swift
func makeIcon(percentage: Int, resetText: String, isLowBattery: Bool) -> NSImage {
    let fgColor: NSColor = isLowBattery ? .white : .black
    let attrs: [NSAttributedString.Key: Any] = [
        .font: digitFont,
        .foregroundColor: fgColor
    ]
    return NSImage(size: iconSize, flipped: false) { rect in
        let text = "\(percentage)%"
        text.draw(at: textOrigin, withAttributes: attrs)
        return true
    }
}
```

**Pros:**
- Eliminates retain cycle (attrs is a value-type dictionary captured by copy)
- Text visible in both light and dark mode
- Font can still be cached as instance property

**Cons:**
- Dictionary created per-render (negligible cost vs font lookup)

**Effort:** 15 minutes (plan update)

**Risk:** Low

## Recommended Action

*To be filled during triage.*

## Technical Details

**Affected plan sections:**
- Lines 395-421 (Drawing Handler)
- Lines 407-409 (textAttributes lazy var)

**Agents that flagged this:**
- Performance Oracle (P1-1, P2-5)
- Architecture Strategist (P3-6)
- Pattern Recognition Specialist (P2-6, P3-1)

## Acceptance Criteria

- [ ] Drawing handler closure does not capture `self`
- [ ] Text color adapts based on isTemplate mode
- [ ] `lazy var textAttributes` removed or restructured
- [ ] Plan notes that assigning new NSImage releases the old one

## Work Log

### 2026-02-15 - Initial Discovery

**By:** Claude Code (Technical Review)

**Actions:**
- 3 agents independently flagged the retain cycle
- Performance Oracle provided the most detailed analysis of the memory implications
- The dark mode issue would make the "urgent" red battery state completely unreadable
