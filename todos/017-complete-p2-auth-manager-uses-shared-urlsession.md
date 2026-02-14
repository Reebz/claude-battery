---
status: complete
priority: p2
issue_id: "017"
tags: [code-review, security, networking]
dependencies: []
---

# AuthManager Uses URLSession.shared for Sensitive Requests

## Problem Statement

`AuthManager.fetchOrganization()` uses `URLSession.shared` to make authenticated API calls. The shared session has default cookie storage enabled, which means the session cookie could be stored in the default cookie jar and potentially leaked to other requests or read by other code using the shared session.

Found by: Security Sentinel (MEDIUM)

## Findings

- **Location:** `AuthManager.swift` — `fetchOrganization()` uses `URLSession.shared.data(for:)`
- **Contrast:** `UsageService` correctly creates a custom `URLSession` with `httpShouldSetCookies = false`
- **Impact:** The session cookie sent in the Authorization/Cookie header could be stored by the shared session's cookie storage, persisting beyond the intended scope.

## Proposed Solutions

### Solution A: Use custom URLSession with cookie storage disabled (Recommended)
- Create a private `URLSession` in AuthManager with `httpShouldSetCookies = false`
- Or reuse the same configuration pattern as UsageService
- **Pros:** Consistent security posture, no cookie leakage
- **Cons:** Minimal — one more URLSession instance
- **Effort:** Small
- **Risk:** Low

## Technical Details

- **Affected files:** `AuthManager.swift`

## Acceptance Criteria

- [ ] AuthManager does not use URLSession.shared for authenticated requests
- [ ] Cookie storage is disabled on the session used for API calls

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
