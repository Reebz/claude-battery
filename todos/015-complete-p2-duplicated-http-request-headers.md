---
status: complete
priority: p2
issue_id: "015"
tags: [code-review, architecture, duplication]
dependencies: []
---

# Duplicated HTTP Request Headers Between Services

## Problem Statement

Both `AuthManager` and `UsageService` independently construct the same Cloudflare bypass and browser-mimicking HTTP headers. This duplication means header changes must be applied in two places, risking drift.

Found by: Pattern Recognition Specialist (HIGH), Architecture Strategist (LOW), Code Simplicity Reviewer

## Findings

- **Location 1:** `AuthManager.swift` — `fetchOrganization()` sets User-Agent, Accept, Referer, Cookie headers
- **Location 2:** `UsageService.swift` — `pollUsage()` sets the same headers
- **Impact:** Maintenance burden — if Claude.ai changes required headers, both files must be updated. Easy to miss one.

## Proposed Solutions

### Solution A: Extract shared request builder (Recommended)
- Add a static method or free function: `makeAuthenticatedRequest(url: URL, sessionKey: String) -> URLRequest`
- Both services call this shared function
- **Pros:** Single source of truth, DRY
- **Cons:** Adds a shared dependency
- **Effort:** Small
- **Risk:** Low

### Solution B: Move to URLSession configuration
- Set common headers on the URLSession configuration's `httpAdditionalHeaders`
- **Pros:** Automatic for all requests
- **Cons:** Session-level headers may not be appropriate for all requests
- **Effort:** Small
- **Risk:** Low

## Technical Details

- **Affected files:** `AuthManager.swift`, `UsageService.swift`, potentially a new shared helper

## Acceptance Criteria

- [ ] HTTP headers defined in one place
- [ ] Both AuthManager and UsageService use the shared definition
- [ ] No header drift between the two

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
