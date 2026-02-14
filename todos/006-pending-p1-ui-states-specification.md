---
status: pending
priority: p1
issue_id: "006"
tags: [code-review, ux, specification, ui-states]
dependencies: []
---

# Specify All UI States: First Launch, Re-Auth, Loading, Stale, Error

## Problem Statement

The plan leaves several critical UI states completely unspecified. Non-technical marketers (the target audience) will encounter all of these states and have no guidance on what to do.

## Findings

- **First launch unspecified (Spec Flow P1-01):** No description of what users see when they first open the app. What icon is displayed? What does the popover show before authentication? How do users discover "Sign In"?

- **Re-auth UX undefined (Spec Flow P1-04):** Plan says "show re-auth prompt" but this is never defined. Does it auto-present? Does the icon change? Is last-known data still shown? What if user ignores it?

- **Nil usage popover (Spec Flow P1-03):** `latestUsage: UsageData?` is optional but the plan never says what `UsagePopoverView` renders when nil. This occurs immediately after sign-in, before first poll, or after failed polls.

- **Stale data appearance (Spec Flow P2-09):** Plan defines `isStale` (10 min) and "gray out icon after 3+ failures" but: Is "gray" different from normal template mode? Are stale percentages still shown? Is there a "Last updated" indicator?

- **Cookie capture failure (Spec Flow P1-05):** No specification for what happens when the user closes the login window without completing login, or when cookie capture fails/times out.

## Proposed Solutions

### Option 1: Add a "UI States" section to the plan

**Approach:** Create a comprehensive state table documenting every visual state:

| State | Menu Bar Icon | Popover Content | Trigger |
|-------|--------------|-----------------|---------|
| Unauthenticated (first launch) | Empty battery outline | "Sign In to see your Claude usage" + Sign In button | App launch with no keychain |
| Authenticating | Same as above | Login window open | User clicks Sign In |
| Loading (first fetch) | Empty battery + spinner | "Fetching usage..." | After successful auth |
| Normal | Filled battery + % + countdown | Progress bars, exact %, reset times | Successful poll |
| Stale (>10 min) | Battery + "?" or dimmed | Last data + "Last updated X min ago" | 3+ consecutive failures |
| Session expired | Battery outline + "!" | "Session expired. Sign in again." + last data | 401/403 response |
| Error (persistent) | Gray battery | "Unable to reach Claude. App may need update." | 10+ consecutive failures |

**Pros:**
- Implementer has zero ambiguity about any state
- UX tested against target audience expectations
- Every nil/error case handled

**Cons:**
- Adds 20-30 lines to the plan

**Effort:** 45 minutes (plan update)

**Risk:** Low

## Recommended Action

*To be filled during triage.*

## Technical Details

**Affected plan sections:**
- Lines 254-266 (App State)
- Lines 61-76 (Menu Bar Layout)
- Click Behavior section
- Error Handling section

**Agents that flagged this:**
- Spec Flow Analyzer (P1-01, P1-03, P1-04, P1-05, P2-09)

## Acceptance Criteria

- [ ] Every UI state has a defined menu bar icon appearance
- [ ] Every UI state has a defined popover content
- [ ] First launch shows sign-in guidance
- [ ] Re-auth state preserves last-known data + shows re-auth CTA
- [ ] Loading/nil state shows spinner or placeholder
- [ ] Stale data has visible "last updated" indicator
- [ ] Cookie capture cancellation/timeout specified

## Work Log

### 2026-02-15 - Initial Discovery

**By:** Claude Code (Technical Review)

**Actions:**
- Spec Flow Analyzer identified 7 P1 and 10 P2 gaps, most related to undefined UI states
- The first launch experience is the most impactful gap for the non-technical target audience
