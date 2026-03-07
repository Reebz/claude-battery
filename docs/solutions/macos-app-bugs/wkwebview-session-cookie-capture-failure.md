---
title: "Fixed login flow failing to capture sessionKey cookie from WKWebView"
date: 2026-03-08
status: resolved
severity: critical
component: AuthManager (login flow)
technology:
  - Swift
  - WKWebView
  - WKHTTPCookieStore
  - WKHTTPCookieStoreObserver
  - JavaScript interop
root_cause: "WKHTTPCookieStoreObserver unreliable with non-persistent data stores; didFinish doesn't fire for SPA navigations"
files_modified:
  - ClaudeBattery/ClaudeBattery/Services/AuthManager.swift
tags:
  - auth
  - cookies
  - wkwebview
  - login
  - session-capture
---

# Fixed: Login Flow Fails to Capture Session Cookie

## Symptom

After signing out, clicking "Sign In Again", entering email, and completing the 6-digit verification code, the login window showed the claude.ai dashboard but the app never captured the session. The login window stayed open indefinitely and no account was activated.

## Root Cause

Two independent WebKit limitations combined to break cookie detection:

1. **`WKHTTPCookieStoreObserver.cookiesDidChange` is unreliable with `.nonPersistent()` data stores.** This is a known WebKit behavior — the observer callback may not fire when cookies are set via XHR/fetch `Set-Cookie` headers (which is how claude.ai's email code verification works).

2. **`didFinish` navigation delegate doesn't fire for SPA navigations.** After the 6-digit code verification, claude.ai does the auth check via a JavaScript fetch call, then performs a client-side React Router navigation to the dashboard. This is not a full page load, so `webView(_:didFinish:)` never fires.

The original code relied exclusively on these two mechanisms. When both failed, the `sessionKey` cookie existed in the WebView but was never detected by the app.

## Solution

Added three redundant cookie detection mechanisms layered on top of the existing observer:

### 1. Cookie Polling Timer (0.5s interval)
```swift
cookiePollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
    // Calls checkCookiesFromAllSources()
}
```
Most reliable fallback. Runs every 500ms while the login window is open, querying both `WKHTTPCookieStore.allCookies()` and JavaScript `document.cookie`.

### 2. JavaScript `document.cookie` Evaluation
```swift
webView.evaluateJavaScript("document.cookie") { result, error in
    // Parse "sessionKey=value; ..." format
}
```
Catches cookies that `WKHTTPCookieStore` misses — specifically cookies set via JavaScript `document.cookie` assignment, which non-persistent stores may not surface through the native API.

### 3. KVO URL Observation
```swift
urlObservation = webView.observe(\.url, options: [.new]) { webView, _ in
    // Check cookies when URL changes (SPA navigation)
}
```
Detects SPA navigations (React Router pushState) that don't trigger `didFinish`, and immediately checks cookies when the URL changes from `/login` to the dashboard.

### Cleanup Consolidation
All login window teardown was consolidated into `stopLoginWindow()` to prevent resource leaks (timer, KVO observation, cookie observer, WebView, window controller).

## Key Insight

**Never rely solely on `WKHTTPCookieStoreObserver` with non-persistent data stores.** The observer is designed primarily for the default (persistent) store. For ephemeral/non-persistent stores, always add a polling fallback. JavaScript `document.cookie` evaluation is the most reliable cross-cutting detection method since it reads cookies regardless of how they were set (HTTP header vs JavaScript).

## Prevention

- When working with WKWebView cookie capture, always implement multiple detection paths
- Test auth flows with email+code, not just Google OAuth — they use different server-side mechanisms
- SPA-heavy sites (React, Next.js) will increasingly use client-side navigation after auth — `didFinish` alone is insufficient

## Related

- [Auth failure polling state machine hang](../logic-errors/auth-failure-polling-state-machine-hang.md) — earlier auth recovery bug
- [Keychain credential storage and auth hardening](../security-issues/keychain-credential-storage-and-auth-hardening.md) — security debt tracking
