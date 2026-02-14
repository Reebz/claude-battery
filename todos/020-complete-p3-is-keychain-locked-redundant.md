---
status: complete
priority: p3
issue_id: "020"
tags: [code-review, simplicity, cleanup]
dependencies: []
---

# isKeychainLocked Property is Redundant

## Problem Statement

`KeychainService.isKeychainLocked` performs a Keychain query with `kSecReturnData` just to check if the Keychain is accessible. This is redundant because `read()` already returns `nil` when the Keychain is locked. The check in `UsageService.pollUsage()` can simply use the existing `read()` guard.

Found by: Code Simplicity Reviewer, Performance Oracle (OPT-4/5)

## Findings

- **Location:** `KeychainService.swift` — `isKeychainLocked` property
- **Location:** `UsageService.swift` — `if keychain.isKeychainLocked { return }` before `guard let sessionKey = keychain.read(...)`
- **Impact:** Performs an unnecessary full Keychain data retrieval just to check status, immediately followed by the actual reads that would fail naturally if locked.

## Proposed Solutions

### Solution A: Remove isKeychainLocked (Recommended)
- Delete the `isKeychainLocked` property
- Remove the guard in `pollUsage()` — the subsequent `guard let sessionKey` handles it
- **Pros:** Less code, one fewer Keychain round-trip per poll
- **Effort:** Small
- **Risk:** Low

## Technical Details

- **Affected files:** `KeychainService.swift`, `UsageService.swift`

## Acceptance Criteria

- [ ] `isKeychainLocked` property removed
- [ ] Polling still gracefully handles locked Keychain via read() returning nil

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
