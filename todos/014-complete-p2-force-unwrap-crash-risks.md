---
status: complete
priority: p2
issue_id: "014"
tags: [code-review, security, crash-safety]
dependencies: []
---

# Force-Unwrap Crash Risks in URL Construction

## Problem Statement

Multiple places in the codebase use force-unwrap (`!`) when constructing URLs from strings that include user-supplied or Keychain-stored data. If the data contains invalid URL characters, the app crashes.

Found by: Security Sentinel (MEDIUM), Pattern Recognition Specialist (LOW)

## Findings

- **Location 1:** `UsageService.swift` — `URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!`
  - `orgId` comes from Keychain. If corrupted or tampered, URL construction crashes.
- **Location 2:** `AuthManager.swift` — `URL(string: "https://claude.ai/api/organizations")!`
  - This one is a literal string so it's safe, but the pattern is fragile.
- **Impact:** App crash if orgId contains spaces, special characters, or is empty.

## Proposed Solutions

### Solution A: Guard with optional binding (Recommended)
- Replace `URL(string:)!` with `guard let url = URL(string:) else { return }` or log an error
- **Pros:** Prevents crashes, graceful degradation
- **Cons:** Slightly more verbose
- **Effort:** Small
- **Risk:** Low

## Technical Details

- **Affected files:** `UsageService.swift`, `AuthManager.swift`

## Acceptance Criteria

- [ ] No force-unwraps on URL construction with dynamic data
- [ ] Invalid URLs handled gracefully (log + early return)

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
