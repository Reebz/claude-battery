# Claude Battery - macOS Menu Bar Widget

**Date**: 2026-02-15
**Status**: Brainstorm complete

## What We're Building

A macOS menu bar widget called **Claude Battery** that displays Claude Pro/Max usage as a battery that drains from 100% to 0%. Designed for non-technical users (marketers) who need a simple, glanceable way to see how much Claude quota they have left.

### Menu Bar Layout

```
[█████░░░ 58% 3d | ▮ 92% 4h]
 ─────────────────  ──────────
 Weekly quota        Session
```

Left to right:
1. **Battery capsule** — horizontal battery icon (rounded rectangle + nub) with fill level representing weekly quota remaining
   - Number inside: remaining % (e.g., `58%`)
   - After a thin vertical divider inside the battery: days until reset (e.g., `3d`), switches to hours when <24h (e.g., `18h`)
2. **Thin vertical divider** — separates battery from session indicator
3. **Session indicator** — small vertical progress bar showing session usage remaining
   - Number to the right: remaining % (e.g., `92%`)
   - Reset time: hours (e.g., `4h`), switches to minutes when <1h (e.g., `45m`)

### Color Scheme

- **Monochrome** (macOS template image style) when usage remaining is >=20%
- **Red** when remaining drops below 20% — signals urgency

### Percentage Direction

Battery metaphor: shows **remaining** quota (inverted from Claude's "used" metric).
- API returns `utilization: 42` (42% used) -> we display `58%` (58% remaining)
- Battery fill level matches: 58% full

### Click Behavior

- **Left-click**: Opens a popover with detailed usage breakdown
  - Weekly quota: progress bar + exact % + reset date/time
  - Session usage: progress bar + exact % + reset time
- **Right-click**: Native dropdown menu
  - Settings
  - Quit Claude Battery

### Settings (Minimal)

- Launch at login toggle
- Low-usage notification: alert when quota drops below configurable threshold (default 20%)
- Sign out

## Why This Approach

### Authentication: Embedded WKWebView Login

Using a `WKWebView` to present claude.ai's login page in a native macOS sheet. The user clicks "Sign In", sees claude.ai's familiar login page, enters their credentials, and the app captures the `sessionKey` cookie automatically via `WKHTTPCookieStore` observation.

**Why WKWebView and not ASWebAuthenticationSession:**
`ASWebAuthenticationSession` is designed for OAuth redirect flows with callback URLs. claude.ai's login is a standard web login with no redirect to a custom scheme — so `ASWebAuthenticationSession` cannot intercept the result. `WKWebView` with cookie monitoring achieves the same seamless UX while actually working with claude.ai's login flow.

**Why not other approaches:**
- Session key extraction (Usage4Claude's approach): requires DevTools — too complex for marketers
- Claude Code OAuth: requires Claude Code installed — target users won't have it
- Own OAuth client registration: Anthropic doesn't support third-party OAuth clients

**Trade-offs:**
- Session cookies expire periodically (weeks to months) — app will detect expiry (401/403 response) and prompt re-auth
- Relies on undocumented API — Anthropic could change it

### Build From Scratch (Not Fork)

Evaluated both existing macOS Claude usage apps:
- **Usage4Claude** (40 files, 460KB) — session key only, Chinese comments, overengineered icons
- **Claude-Usage-Tracker** (83 files, 747KB) — even more complex, 3-tier auth, 8 languages

Both are 10-15x more code than needed. Claude Battery needs ~6 files, ~500-800 lines. We'll reference their API endpoint knowledge and Cloudflare bypass headers.

### Data Source

Undocumented endpoint: `GET https://claude.ai/api/organizations/{orgId}/usage`

Returns:
```json
{
  "five_hour": { "utilization": 42.0, "resets_at": "2026-02-15T10:00:00Z" },
  "seven_day": { "utilization": 35.0, "resets_at": "2026-02-18T04:00:00Z" },
  "seven_day_opus": { "utilization": 0.0, "resets_at": null },
  "seven_day_sonnet": { "utilization": 12.0, "resets_at": "2026-02-18T04:00:00Z" }
}
```

Required headers (Cloudflare bypass):
- `Cookie: sessionKey=sk-ant-sid01-...`
- `anthropic-client-platform: web_claude_ai`
- `anthropic-client-version: 1.0.0`
- Browser-like User-Agent and `sec-fetch-*` headers

Also fetches org ID via: `GET https://claude.ai/api/organizations`

## Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Build vs. fork | Build from scratch | Existing apps are 10-15x over-scoped |
| Auth method | WKWebView + cookie capture | Zero-friction for non-technical users |
| % display | Remaining (battery metaphor) | Intuitive: full battery = lots of quota left |
| Color scheme | Monochrome + red at <20% | Matches native macOS aesthetic, red signals urgency |
| Click behavior | Left=popover, Right=menu | Standard macOS menu bar pattern |
| Settings scope | Login + notifications only | Keep it simple for marketers |
| Tech stack | Swift/SwiftUI, zero dependencies | Native performance, no dependency management |

## Architecture

```
ClaudeBattery/
  App/
    ClaudeBatteryApp.swift       # @main, AppDelegate, activation policy
  Services/
    AuthManager.swift            # WKWebView login + Keychain cookie storage
    UsageService.swift           # async/await API calls, polling
  Views/
    MenuBarController.swift      # NSStatusItem, battery icon rendering
    UsagePopover.swift           # SwiftUI popover with detailed stats
    SettingsView.swift           # Minimal settings window
  Models/
    UsageModels.swift            # Codable API response structs
```

## Open Questions

1. **App Store distribution** — Undocumented API usage may violate App Store guidelines. May need to distribute via DMG/Homebrew instead.
2. **Anthropic's stance** — They've been cracking down on third-party tools using Claude tokens for inference. A read-only usage monitor is different, but the risk exists.
3. **WKWebView sandboxing** — Verify that `WKHTTPCookieStore` can observe cookies set by claude.ai's login flow in a sandboxed macOS app. May need a non-sandboxed build for development.

## Resolved Questions

- **Auth approach**: WKWebView with cookie capture (not ASWebAuthenticationSession — wrong tool for non-OAuth login flows)
- **Session expiry**: Detect via 401/403 API response, prompt re-auth automatically
- **Polling interval**: Fixed 2-minute interval. Simplest approach, no adaptive complexity.
