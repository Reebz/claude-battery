---
status: complete
priority: p2
issue_id: "016"
tags: [code-review, quality, debugging, logging]
dependencies: []
---

# Silent Error Swallowing — No Logging Throughout

## Problem Statement

Errors from Keychain operations, network requests, JSON decoding, and notification authorization are all silently ignored. This makes debugging production issues nearly impossible — users report "it stopped working" with no diagnostic information available.

Found by: Pattern Recognition Specialist (HIGH)

## Findings

- **KeychainService:** `save()`, `delete()` silently ignore `OSStatus` errors
- **UsageService:** `pollUsage()` catches all errors in a generic `catch { }` with no logging
- **AuthManager:** `fetchOrganization()` catches errors silently
- **SettingsView:** `SMAppService.register()/unregister()` catches silently
- **Impact:** When things go wrong, there's no way to diagnose what failed. Users and developers are blind.

## Proposed Solutions

### Solution A: Add os.Logger (Recommended)
- Use `os.Logger` (macOS 11+) for structured, privacy-aware logging
- Create a shared logger: `Logger(subsystem: Bundle.main.bundleIdentifier!, category: "...")`
- Log errors at `.error` level, state changes at `.info` level
- **Pros:** System-integrated, privacy-aware, viewable in Console.app
- **Cons:** Adds logging code throughout
- **Effort:** Medium
- **Risk:** Low

### Solution B: print() for development
- Add `print()` statements for errors
- **Pros:** Quick, simple
- **Cons:** Not available in production builds, no structured logging
- **Effort:** Small
- **Risk:** Low

## Technical Details

- **Affected files:** All service files

## Acceptance Criteria

- [ ] Keychain errors are logged with OSStatus codes
- [ ] Network errors are logged with error descriptions
- [ ] JSON decoding failures are logged with context
- [ ] Logs are viewable in Console.app

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
