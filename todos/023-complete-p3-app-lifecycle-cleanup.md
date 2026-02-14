---
status: complete
priority: p3
issue_id: "023"
tags: [code-review, simplicity, cleanup]
dependencies: []
---

# App Lifecycle Cleanup — Unnecessary Patterns

## Problem Statement

Several patterns in the app lifecycle are over-engineered or no-ops:
1. `applicationWillTerminate` wraps `stopPolling()` in a `Task { @MainActor }` — the process is terminating, this task may never execute
2. `signOut()` uses `async/await` wrapping `withCheckedContinuation` for `WKWebsiteDataStore.removeData` — this could just be fire-and-forget
3. Login timeout (660 seconds) with a cancellation task is over-engineered for a simple UX guard

Found by: Code Simplicity Reviewer, Performance Oracle (OPT-7)

## Findings

- **applicationWillTerminate:** `Task { @MainActor in usageService?.stopPolling() }` — the process exits before the task runs. Timer invalidation is unnecessary since the process is dying.
- **signOut:** Wraps callback-based API in `withCheckedContinuation` just to `await` it. The caller doesn't need to wait for cookie deletion to complete.
- **Login timeout:** Task.sleep + cancellation tracking for something that could be a simple DispatchQueue.main.asyncAfter.

## Proposed Solutions

### Solution A: Simplify all three (Recommended)
- Remove `applicationWillTerminate` body (process cleanup is automatic)
- Make `signOut()` synchronous — call `removeData` fire-and-forget
- Simplify login timeout to a single dispatch or remove if unnecessary
- **Pros:** Less code, clearer intent
- **Effort:** Small
- **Risk:** Low

## Technical Details

- **Affected files:** `ClaudeBatteryApp.swift`, `AuthManager.swift`

## Acceptance Criteria

- [ ] applicationWillTerminate is simplified or removed
- [ ] signOut doesn't use unnecessary async/await
- [ ] Login timeout is simpler or removed

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
