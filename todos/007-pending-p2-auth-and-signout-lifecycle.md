---
status: pending
priority: p2
issue_id: "007"
tags: [code-review, security, authentication, lifecycle]
dependencies: []
---

# Specify Authentication Edge Cases and Sign-Out Lifecycle

## Problem Statement

Multiple security and lifecycle gaps in the authentication flow and sign-out process.

## Findings

- **Cookie attribute validation missing (Security P1-1):** No validation of captured cookie's domain, secure flag, or path attributes. A malicious page in the WKWebView could set a cookie named "sessionKey" from any domain.

- **Sign-out doesn't stop polling (Spec Flow P2-06, Pattern P2-7):** Plan says sign out "clears Keychain + WKWebView data store" but never mentions stopping the polling timer, ending the App Nap activity, or invalidating the URLSession.

- **WKWebsiteDataStore race (Security P1-3, Performance P2-2):** `removeData` is async. If user signs out and immediately clicks "Sign In", old cookies may still be present, causing the login page to show the previous session.

- **URLSession not invalidated (Performance P2-1):** URLSession holds network resources (connection pool, NWPathMonitor). On sign-out, a new URLSession could be created on next sign-in while the old one lives on.

- **Empty orgs response (Spec Flow P1-02):** `/api/organizations` could return an empty array (free-tier account). No error handling specified.

- **Concurrent login windows (Spec Flow P2-05):** No guard against opening multiple login windows if user clicks "Sign In" twice.

## Proposed Solutions

### Option 1: Comprehensive auth lifecycle specification

**Approach:** Add explicit specifications for:
1. Cookie validation: check domain is `.claude.ai`, secure flag is true
2. Sign-out teardown sequence: `stopPolling()` → `invalidateSession()` → `clearKeychain()` → `await removeWebsiteData()` → `setUnauthenticated()`
3. Sign-in guard: `guard loginWindowController == nil else { bring to front; return }`
4. Empty orgs: Show "No Claude Pro or Max subscription found" message

**Effort:** 30 minutes (plan update)

**Risk:** Low

## Recommended Action

*To be filled during triage.*

## Technical Details

**Affected plan sections:**
- Lines 119-149 (Authentication Flow)
- Settings/sign-out section
- Lines 280-288 (Error Handling)

**Agents that flagged this:**
- Security Sentinel (P1-1, P1-3)
- Performance Oracle (P2-1, P2-2)
- Spec Flow Analyzer (P1-02, P2-05, P2-06)
- Pattern Recognition Specialist (P2-7)

## Acceptance Criteria

- [ ] Cookie domain validation documented (`.claude.ai` only)
- [ ] Sign-out sequence includes: stop timer, end activity, invalidate URLSession, clear keychain, await data store removal
- [ ] Login window is a singleton (bring to front if already open)
- [ ] Empty orgs response shows user-facing error message
- [ ] Sign-in button disabled while login window is open

## Work Log

### 2026-02-15 - Initial Discovery

**By:** Claude Code (Technical Review)

**Actions:**
- 4 of 6 agents flagged auth/sign-out lifecycle issues
- Security Sentinel rated cookie validation as P1 — without domain check, any page in WKWebView could inject a fake sessionKey
