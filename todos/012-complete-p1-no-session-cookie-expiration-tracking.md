---
status: complete
priority: p1
issue_id: "012"
tags: [code-review, security, authentication]
dependencies: []
---

# No Session Cookie Expiration Tracking

## Problem Statement

The app captures the `sessionKey` cookie value and stores it in Keychain, but never stores or checks the cookie's `expiresDate`. If the cookie expires, the app continues sending invalid credentials until the server returns 401/403, which triggers the auth failure callback. There is no proactive expiration check.

Found by: Security Sentinel (HIGH)

## Findings

- **Location:** `AuthManager.swift` — `onSessionKeyCaptured()` saves only `cookie.value`, discards `cookie.expiresDate`
- **Impact:** After cookie expiration, the app makes failed API calls for multiple poll intervals before `consecutiveFailures` triggers the error state. User sees stale data or loading state instead of a clear "session expired" message.
- **Current mitigation:** The `onAuthFailure` callback in UsageService handles 401/403 by stopping polling and calling `handleAuthFailure()`. This is reactive rather than proactive.

## Proposed Solutions

### Solution A: Store and check expiration date (Recommended)
- Save `cookie.expiresDate` to Keychain or UserDefaults alongside the session key
- Before each poll, check if the cookie has expired
- If expired, proactively trigger re-auth flow
- **Pros:** Better UX, avoids unnecessary failed requests
- **Cons:** Slight additional complexity
- **Effort:** Small
- **Risk:** Low

### Solution B: Accept current reactive approach
- The 401/403 handling already works
- Just ensure the error state clearly tells the user to re-authenticate
- **Pros:** No code change needed
- **Cons:** User sees stale/error state for a poll cycle before re-auth prompt
- **Effort:** None
- **Risk:** Low — current behavior is functional, just not optimal

## Recommended Action

Solution A — store expiration and check proactively. This provides cleaner UX.

## Technical Details

- **Affected files:** `AuthManager.swift`, `UsageService.swift`, possibly `KeychainService.swift`

## Acceptance Criteria

- [ ] Cookie expiration date is stored alongside session key
- [ ] Polling checks expiration before making API calls
- [ ] Expired session triggers re-auth prompt proactively

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
