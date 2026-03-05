---
title: Extra Usage Spend Bar — API Cents-to-Dollars Conversion & Field Discovery
date: 2026-03-05
category: integration-issues
severity: MEDIUM
module: UsageService, UsagePopoverView
tags:
  - extra-usage
  - api-response-format
  - currency-conversion
  - cents-to-dollars
  - undocumented-api
  - swiftui-layout
symptoms:
  - Extra usage bar displays $7,750 instead of $77.50
  - Monthly limit and used credits appear 100x larger than actual amounts
root_cause: API endpoint returns monetary values (monthly_limit, used_credits) in cents, not dollars. ExtraUsageData init did not perform unit conversion.
---

# Extra Usage Spend Bar — API Cents-to-Dollars Conversion & Field Discovery

## Problem

Adding a spend tracking bar to the Claude Battery popover required consuming extra usage data from the claude.ai API. Two issues arose:

1. **Undocumented API fields:** The existing `/api/organizations/{orgId}/usage` endpoint returns an `extra_usage` object that wasn't being decoded. No new endpoint was needed.
2. **Cents vs dollars:** The `monthly_limit` and `used_credits` fields are returned in **cents** (e.g., `7750` = $77.50), but were displayed as raw dollar values ($7,750).

## Root Cause

The `/api/organizations/{orgId}/usage` response includes:

```json
{
  "five_hour": { "utilization": 7.0, "resets_at": "..." },
  "seven_day": { "utilization": 29.0, "resets_at": "..." },
  "extra_usage": {
    "is_enabled": true,
    "monthly_limit": 7750,
    "used_credits": 0,
    "utilization": 0
  }
}
```

The `monthly_limit` and `used_credits` values are in **cents**, not dollars. This was not documented anywhere. The initial implementation passed these values directly to `NumberFormatter.currency`, which treated 7750 cents as $7,750.00.

## Solution

### 1. Extend Existing UsageResponse (no new API call)

Added `ExtraUsageTier` to the existing response model with lenient decoding:

```swift
// UsageService.swift
struct UsageResponse: Codable {
    let fiveHour: UsageTier?
    let sevenDay: UsageTier?
    let sevenDayOpus: UsageTier?
    let sevenDaySonnet: UsageTier?
    let extraUsage: ExtraUsageTier?    // NEW — already in API response
}

struct ExtraUsageTier: Codable {
    let isEnabled: Bool?
    let monthlyLimit: Double?      // API value: CENTS
    let usedCredits: Double?       // API value: CENTS
    let utilization: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try? container.decode(Bool.self, forKey: .isEnabled)
        monthlyLimit = try? container.decode(Double.self, forKey: .monthlyLimit)
        usedCredits = try? container.decode(Double.self, forKey: .usedCredits)
        utilization = try? container.decode(Double.self, forKey: .utilization)
    }
}
```

### 2. Convert cents to dollars in the view model

```swift
struct ExtraUsageData {
    let spent: Double       // dollars (converted from API cents)
    let limit: Double       // dollars (converted from API cents)
    let percentage: Double  // 0-100, clamped

    init?(from tier: ExtraUsageTier?) {
        guard let tier, tier.isEnabled == true,
              let spentCents = tier.usedCredits,    // API: cents
              let limitCents = tier.monthlyLimit,    // API: cents
              limitCents > 0 else { return nil }

        self.spent = spentCents / 100.0    // cents -> dollars
        self.limit = limitCents / 100.0    // cents -> dollars
        self.percentage = min(100, max(0, spentCents / limitCents * 100))
    }
}
```

### 3. Embed in UsageData (not separate @Published)

Since extra usage comes from the same API response, it's embedded in `UsageData`:

```swift
struct UsageData {
    // ... existing fields ...
    let extraUsage: ExtraUsageData?

    init(from response: UsageResponse) {
        // ... existing init ...
        extraUsage = ExtraUsageData(from: response.extraUsage)
    }
}
```

### 4. UI: Split grid and add spend bar

Split the single `LazyVGrid` into two to insert a full-width bar between rows:

```swift
// Row 1: Session + Weekly
LazyVGrid(columns: columns, spacing: 8) {
    sessionCard(usage: usage)
    weeklyCard(usage: usage)
}

// Extra usage bar (only when enabled)
if let extraUsage = usage.extraUsage {
    extraUsageBar(extraUsage: extraUsage)
}

// Row 2: Resets + Models
LazyVGrid(columns: columns, spacing: 8) {
    resetsCard(usage: usage)
    modelsCard(usage: usage)
}
```

Currency formatting uses a static `NumberFormatter` with device locale (auto-shows A$ for AUD, $ for USD, etc.).

## Investigation: Keychain Popup Not a Regression

The user reported a macOS Keychain password dialog during testing. Investigation confirmed this was **not caused by these changes**:

```bash
$ git diff main..feat/extra-usage-spend-bar --stat
 Services/UsageService.swift      | 39 +++++++++++++
 Views/UsagePopoverView.swift     | 68 ++++++++++++++++++++--
 2 files changed, 103 insertions(+), 4 deletions(-)
```

Zero changes to `ClaudeAPI.swift`, `AuthManager.swift`, `AccountStore.swift`, or `StorageService.swift`. The keychain popup is an unrelated macOS-level behavior.

## Prevention Strategies

### Cents vs Dollars Convention

- Add inline comments specifying units: `// API value: CENTS`
- Name intermediate variables with units: `spentCents`, `limitCents`
- Convert at the boundary (Codable init), not at display time
- When an API returns numbers without units, test with known values to determine the unit

### API Response Discovery

- The existing DEBUG logging at `UsageService.swift:164` logs raw response bodies — check this first when adding new fields
- Make all API response fields optional (`let field: Type?`) with `try?` decoding
- The `/api/organizations/{orgId}/usage` endpoint may return additional undocumented fields in the future

### Regression Verification Pattern

When a user reports a potential regression:

1. Identify the subsystem files (e.g., auth = `ClaudeAPI.swift`, `AuthManager.swift`)
2. Run `git diff <original-fix>..HEAD -- <subsystem-files>`
3. If no output, the subsystem is unchanged — regression is external
4. Only investigate code after confirming the subsystem was modified

## Related Documentation

- [Keychain Credential Storage & Auth Hardening](../security-issues/keychain-credential-storage-and-auth-hardening.md) — URLSession ephemeral config, Keychain avoidance
- [Auth Failure Polling State Machine Hang](../logic-errors/auth-failure-polling-state-machine-hang.md) — Polling lifecycle, failure counter patterns
- [Critical Patterns](../patterns/critical-patterns.md) — Force-unwrap guards, domain validation, DEBUG logging
- [Claude Battery Multi-Bug Fix Session](../macos-app-bugs/claude-battery-multi-bug-fix-session.md) — Popover state machine, LSUIElement patterns

## Files Modified

| File | Changes |
|------|---------|
| `UsageService.swift` | Added `ExtraUsageTier`, `ExtraUsageData` models. Extended `UsageResponse` and `UsageData`. |
| `UsagePopoverView.swift` | Split `LazyVGrid`, added `extraUsageBar()`, `spendColor()`, static `currencyFormatter`. |
