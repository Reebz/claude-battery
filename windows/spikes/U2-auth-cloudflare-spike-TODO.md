# U2 spike (TODO): WebView2 auth + Cloudflare cookie-replay

Status: NOT RUN. This spike needs a real Windows box, a real claude.ai login, and a live network.
It cannot run on macOS, so it was deferred. Everything below is the script to run and the exact
pass/fail signals; until it runs, the units it gates are built on an assumption, not a result.

## Why this gates the whole port

Two auth unknowns sit under every service in Phase B-E. The plan calls this "the single most
load-bearing assumption" (Dependencies / Assumptions). Resolve it before trusting the
`SocketsHttpHandler` polling path in production:

1. **Which login providers complete inside an embedded WebView2** (Google OAuth, Apple, email-code,
   Entra/SSO). Google has historically blocked embedded webviews with `disallowed_useragent`; the Mac
   hit provider-specific breakage across issues #17/#25.
2. **Whether a `SocketsHttpHandler` poll seeded with WebView2-captured cookies clears Cloudflare, or
   gets a 403 because the TLS/JA3 fingerprint does not match.** On the Mac, WKWebView and URLSession
   share Apple's TLS stack, so a hardcoded Safari UA works even though it differs from the WKWebView
   UA. On Windows the two stacks differ (WebView2 = Chromium TLS; `HttpClient` = SChannel/.NET TLS),
   so UA match is necessary but NOT sufficient. `__cf_bm` is bound to a fingerprint bundle (TLS/JA3 +
   HTTP/2 frame order + header order), not the UA string.

## What to run

Build a throwaway WPF app under `windows/spikes/auth-spike/` (do NOT harden it; time-box it):

1. Host a real WebView2 with the same ephemeral InPrivate isolated user-data folder the production
   `LoginWindow` uses (see `src/ClaudeBatteryWin/Views/LoginWindow.xaml.cs`).
2. Drive a real login across the **provider matrix**, recording a per-provider outcome (not one
   go/no-go):
   - Google "Continue with Google" (watch for `disallowed_useragent`; does the `NewWindowRequested`
     popup flow complete; does passkey/FedCM work).
   - Apple sign-in.
   - Email + email-code.
   - An Entra/SSO org if one is reachable.
3. After login, capture cookies via `CoreWebView2.CookieManager.GetCookiesAsync(null)`. Confirm
   `sessionKey` AND `__cf_bm` are returned with `IsHttpOnly == true`.
4. Read the WebView2 session UA from `CoreWebView2.Settings.UserAgent` after the first
   `NavigationCompleted`.
5. **The load-bearing test:** build a `SocketsHttpHandler` with `UseCookies = true` and a
   `CookieContainer` seeded with the captured cookies (use the production
   `AccountStore.PrimeCookies` / `ClaudeApi` header set verbatim from
   `src/ClaudeBatteryWin/Services/ClaudeApi.cs`), set its `User-Agent` to the captured WebView2 UA,
   then fire a real `GET https://claude.ai/api/organizations/{org}/usage` and record the HTTP status.
6. Observe what the InPrivate UDF writes to disk during the session (the crash-residual surface):
   confirm session material lands somewhere under the UDF so the production
   `LoginWindow.SweepStaleLoginProfiles` + `Dispose` deletion are actually covering a real file.
7. Observe runtime-absent behavior (uninstall the Evergreen Runtime, or point at a box without it):
   what does `CoreWebView2Environment.GetAvailableBrowserVersionString(null)` throw / return. Hand
   this to U8.

## Pass / fail signals

- **The poll test (step 5) is the gate:**
  - `200 OK` -> the `SocketsHttpHandler` cookie-replay path clears Cloudflare. The default
    `ClaudeApi` transport (already wired in `App.xaml.cs` via `SwappableClaudeApi`) is correct as-is.
    GO on the current architecture.
  - `403` (or a Cloudflare challenge page) -> the TLS/JA3 fingerprint is gating the poll. Adopt the
    pre-staged deferred alternative: poll INSIDE the authenticated WebView2 (via `WebResourceRequested`
    or an in-page `fetch`). Implement a second `IClaudeApi` and `SwappableClaudeApi.Swap` it in at the
    composition root (`App.BuildObjectGraph` / `App.RebuildApiWithUserAgent`) instead of constructing
    a `ClaudeApi`. No other unit changes, because everything consumes `IClaudeApi`.
- **Per-provider login (step 2):** record completes / blocked / partial for each. Email-code +
  manual-cookie-paste are default-on fallbacks REGARDLESS of outcome; embedded provider login is
  enabled only where the spike proved it completes. A blocked Google embedded flow is acceptable if
  the email-code steering funnel + manual paste cover it.
- **Cookie capture (step 3):** `sessionKey` + `__cf_bm` both present and HttpOnly -> confirms the
  production `LoginWindow.ReadCookiesAsync` (`GetCookiesAsync(null)`) sees what the funnel needs.
  Missing HttpOnly cookies -> capture is broken; fix before U6 ships.
- **UDF residual (step 6):** if real session material lands on disk, the sweep/delete paths are
  load-bearing security, not theatre — keep them. If nothing lands (fully in-memory), the sweep is
  cheap insurance; keep it anyway.

## What the result gates

- **U3 / U4 polling architecture:** the 200-vs-403 verdict chooses `SocketsHttpHandler` vs in-WebView2
  polling. Wired through `SwappableClaudeApi` so the swap is a one-line composition-root change.
- **U6 / U7 login design:** the provider matrix decides which embedded flows to enable vs route to the
  email-code funnel + manual paste.
- **U8 runtime gate:** the runtime-absent observation feeds the `RuntimeMissingWindow` behavior.
- **Go/no-go on porting the email-code steering funnel** from the Mac (issues #7/#17/#25): if embedded
  Google is blocked, the funnel is required, not optional.
