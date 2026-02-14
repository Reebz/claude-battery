# Claude Battery - Brainstorm

**Date:** 2026-02-14
**Status:** Ready for planning

## What We're Building

A native macOS menu bar app called **Claude Battery** that displays Claude Pro/Max subscription usage as a draining battery. Two metrics are shown:

1. **Session battery** (0-100%): Current 5-hour rolling window usage. Resets every ~5 hours.
2. **Weekly battery** (0-100%): 7-day rolling window usage across all models. Resets weekly (e.g., Tuesday morning).

The battery metaphor inverts the typical "usage" framing: 100% = full charge (nothing used), drains toward 0% as you consume your quota. Inspired by the Claude desktop app's "Plan usage limits" screen.

**Target audience:** Non-technical users (marketers) who use Claude Pro/Max and want a glanceable indicator of remaining quota.

## Why This Approach

### Authentication: Native OAuth PKCE Flow

- Implement Claude Code's OAuth PKCE flow directly in Swift
- User clicks "Sign in" -> browser opens claude.ai login -> they authenticate normally -> token returned to app
- Token stored in macOS Keychain
- No DevTools, no terminal, no session key copying
- **Risk accepted:** Anthropic has no official third-party OAuth. This uses Claude Code's known client ID. The Jan 2026 crackdown targeted inference abuse, not read-only usage checks. Worst case: endpoint stops working, no ban risk for read-only usage queries.

### Data Source: OAuth Usage Endpoint

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer sk-ant-oat01-...
```

Returns:
```json
{
  "five_hour": { "utilization": 8.0, "resets_at": "2026-02-14T..." },
  "seven_day": { "utilization": 66.0, "resets_at": "2026-02-18T..." },
  "seven_day_opus": { "utilization": 0.0, "resets_at": null }
}
```

- `utilization` is already 0-100 percentage
- `resets_at` is ISO 8601 timestamp
- Battery value = `100 - utilization` (invert for battery metaphor)

### Build Approach: Fork Usage4Claude

Fork [Usage4Claude](https://github.com/f-is-h/Usage4Claude) (MIT license) and strip down dramatically:

**Keep:** Core API integration, Keychain storage, NSStatusItem/NSPopover setup, Cloudflare bypass headers
**Remove:** 5-language localization, multi-account support, diagnostics system, complex icon rendering, debug mode, 32KB welcome wizard, session-key-only auth

Replace session key auth with OAuth PKCE flow.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Framework | SwiftUI (macOS 13+) | Native, lightweight, MenuBarExtra support |
| Auth method | OAuth PKCE flow | Best UX for non-technical users, no DevTools required |
| Data source | `/api/oauth/usage` endpoint | Returns exact percentages needed, includes reset times |
| Build approach | Fork Usage4Claude | Proven API code, strip 80% complexity |
| Metaphor | Battery (100% full, drains down) | More intuitive than "usage going up" |
| Refresh rate | Every 60 seconds | Good balance of freshness and API courtesy |
| Low battery behavior | Color change + macOS notification | Yellow at 30%, red at 10%, notification at threshold |
| Menu bar display | TBD - design phase pending | Multiple approaches explored, decision deferred |

## Open Questions

1. **Menu bar visual design**: Deferred to design phase. Options explored: side-by-side batteries, stacked bars, split battery, concentric arcs, single battery + both numbers.
2. **Token refresh handling**: OAuth access tokens expire after ~8 hours. Need refresh token flow. Usage4Claude's Keychain code may help here.
3. **Click-to-expand popover**: What detail to show in the dropdown panel? Full-size bars, exact percentages, reset countdown timers, per-model breakdown?
4. **Settings scope**: Keep minimal. Notification threshold? Launch at login toggle? What else (if anything)?
5. **Distribution**: Direct download (.dmg) vs Mac App Store? WKWebView-based approaches face App Review scrutiny, but OAuth PKCE with external browser should be fine.
6. **Opus-specific tracking**: The API returns `seven_day_opus` separately. Worth showing as a third battery or keep it simple with just session + weekly?
