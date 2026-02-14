---
status: complete
priority: p3
issue_id: "022"
tags: [code-review, quality, maintainability]
dependencies: []
---

# Hardcoded Keychain Keys and Magic Numbers

## Problem Statement

Keychain key strings (`"sessionKey"`, `"organizationId"`) are hardcoded as string literals at each call site. Polling intervals (`120`, `300`, `600`, `1800`) and thresholds (`10`, `3`, `20`) are magic numbers without named constants.

Found by: Pattern Recognition Specialist (MEDIUM)

## Findings

- **Keychain keys:** `"sessionKey"` used in AuthManager + UsageService, `"organizationId"` used in AuthManager + UsageService — any typo causes silent failure
- **Magic numbers:** `660` (login timeout), `120/300/600/1800` (polling intervals), `10` (error threshold), `3` (stale threshold), `20` (notification threshold default)

## Proposed Solutions

### Solution A: Named constants (Recommended)
- Add an enum or extension with static let constants for Keychain keys
- Add named constants for polling intervals and thresholds
- **Pros:** Compile-time safety for keys, self-documenting code
- **Effort:** Small
- **Risk:** Low

## Technical Details

- **Affected files:** `KeychainService.swift` (or new constants), `AuthManager.swift`, `UsageService.swift`, `MenuBarController.swift`

## Acceptance Criteria

- [ ] Keychain keys defined as constants (no string literals at call sites)
- [ ] Polling intervals and thresholds have named constants

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
