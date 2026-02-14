---
status: pending
priority: p2
issue_id: "008"
tags: [code-review, api, data-handling, specification]
dependencies: []
---

# Specify API Response Handling, Clamping, and Display Mapping

## Problem Statement

The plan lacks explicit specification for how API response fields map to UI elements, how edge case values are handled, and what the popover actually displays.

## Findings

- **null resets_at unspecified (Spec Flow P1-06):** API returns `"resets_at": null` for `seven_day_opus`. The plan's Phase 6 says "Handle null reset times" but never specifies what the icon displays instead of a countdown (e.g., `3d`). Would crash on nil date computation.

- **No field-to-display mapping (Spec Flow P1-07):** API returns 4 fields (`five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`). The plan never explicitly maps which field goes to the battery capsule vs. session indicator. Are opus/sonnet fields displayed anywhere?

- **No clamping (Spec Flow P2-04):** `remaining = 100 - utilization` could produce negative or >100 values if API returns unexpected data. Battery fill rendering would break.

- **0%/100% boundary (Spec Flow P2-03):** At exactly 20%, is the icon red or monochrome? At 0%, what does the empty battery look like? At 100%, does fill overlap text?

- **Popover content unspecified (Spec Flow P2-01):** No wireframe, field list, or layout for the popover. How many progress bars? Which fields? What labels? What size?

- **Threshold conflation (Spec Flow P2-02):** Red icon at <20% and notification at default 20% are the same value but conceptually different. If user changes notification threshold to 30%, does icon turn red at 30% or still at 20%?

- **No exponential backoff (Performance P2-3):** After 3+ consecutive failures, app retries every 2 minutes indefinitely. During extended outages, this wastes 30 requests/hour for nothing.

## Proposed Solutions

### Option 1: Add mapping table, clamping, and popover wireframe

**Approach:**

**Field mapping:**
| API Field | UI Element | Notes |
|-----------|-----------|-------|
| `seven_day.utilization` | Battery capsule (100 - value) | Primary weekly display |
| `seven_day.resets_at` | Countdown inside battery (`3d`, `18h`) | Show `--` if null |
| `five_hour.utilization` | Session indicator bar (100 - value) | Primary session display |
| `five_hour.resets_at` | Session countdown (`4h`, `45m`) | Show `--` if null |
| `seven_day_opus` | Popover detail only | Optional breakdown |
| `seven_day_sonnet` | Popover detail only | Optional breakdown |

**Clamping:** `remaining = max(0, min(100, 100 - utilization))`

**Boundaries:** `<20%` = red (exclusive, so exactly 20% is monochrome)

**Backoff:**
```
failures < 3:  120s (normal)
failures < 6:  300s (5 min)
failures < 10: 600s (10 min)
failures >= 10: 1800s (30 min)
```

**Effort:** 45 minutes (plan update)

**Risk:** Low

## Recommended Action

*To be filled during triage.*

## Technical Details

**Affected plan sections:**
- Lines 37-50 (Data Source)
- Lines 61-76 (Menu Bar Layout)
- Lines 280-288 (Error Handling)
- UsagePopoverView section

**Agents that flagged this:**
- Spec Flow Analyzer (P1-06, P1-07, P2-01, P2-02, P2-03, P2-04)
- Performance Oracle (P2-3)

## Acceptance Criteria

- [ ] Explicit API field-to-UI mapping table in plan
- [ ] Clamping: `max(0, min(100, 100 - utilization))`
- [ ] null `resets_at` renders as `--` (not crash)
- [ ] Boundary: exactly 20% is monochrome, <20% is red
- [ ] Popover wireframe or detailed field list
- [ ] Icon color threshold and notification threshold documented as independent or linked
- [ ] Exponential backoff after 3+ failures

## Work Log

### 2026-02-15 - Initial Discovery

**By:** Claude Code (Technical Review)

**Actions:**
- Spec Flow Analyzer identified these as the highest-volume category of gaps (7 findings)
- Performance Oracle independently flagged the backoff issue
- The null resets_at crash would occur for any user with an unused model tier
