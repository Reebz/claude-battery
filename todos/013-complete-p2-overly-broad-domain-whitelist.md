---
status: complete
priority: p2
issue_id: "013"
tags: [code-review, security, authentication]
dependencies: []
---

# Overly Broad Domain Whitelist in AuthManager

## Problem Statement

`AuthManager.isAllowedDomain()` whitelists `.google.com`, `.apple.com`, `.cloudflare.com` in addition to `.claude.ai` and `.anthropic.com`. These broad domains allow the embedded WKWebView to navigate to any subdomain of Google, Apple, and Cloudflare — increasing the attack surface for potential phishing or redirect attacks within the login flow.

Found by: Security Sentinel (MEDIUM)

## Findings

- **Location:** `AuthManager.swift` — `isAllowedDomain()` method
- **Evidence:** Domain suffixes like `.google.com` match any subdomain (e.g., `evil.google.com` if such a subdomain were compromised)
- **Context:** These domains are needed for OAuth flows (Google SSO) and Cloudflare challenges. The broad matching is a trade-off for functionality.
- **Impact:** Medium — the WKWebView is only shown during login, and the user is already interacting with it. Risk is limited to the login window context.

## Proposed Solutions

### Solution A: Tighten to specific subdomains (Recommended)
- Replace `.google.com` with `accounts.google.com`, `oauth2.google.com`
- Replace `.cloudflare.com` with `challenges.cloudflare.com`
- Keep `.claude.ai` and `.anthropic.com` as-is
- **Pros:** Reduced attack surface
- **Cons:** May break if OAuth provider changes subdomains
- **Effort:** Small
- **Risk:** Medium — could break login if subdomains change

### Solution B: Keep current approach with documentation
- Add comments explaining why broad domains are needed
- **Pros:** No risk of breaking login
- **Cons:** Broader attack surface remains
- **Effort:** Minimal
- **Risk:** Low

## Technical Details

- **Affected files:** `AuthManager.swift`

## Acceptance Criteria

- [ ] Domain whitelist is as narrow as possible while still supporting OAuth flows
- [ ] Login flow works with Google SSO and Cloudflare challenges
- [ ] Domains are documented with rationale

## Work Log

| Date | Action | Notes |
|------|--------|-------|
| 2026-02-15 | Created | From code review finding |
