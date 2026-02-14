---
status: pending
priority: p1
issue_id: "005"
tags: [code-review, compatibility, swift, swiftui]
dependencies: []
---

# Fix macOS 13 Compatibility: onChange Syntax

## Problem Statement

The plan uses `onChange(of:) { _, newValue in }` two-parameter syntax which requires macOS 14 (SwiftUI 5). The plan targets macOS 13+, so this code won't compile on macOS 13.

## Findings

- **Compile error on macOS 13 (Pattern P3-7):** Lines 157-164 use `.onChange(of: launchAtLogin) { _, newValue in`. On macOS 13, only the single-parameter form `.onChange(of:) { newValue in }` is available.

## Proposed Solutions

### Option 1: Use macOS 13-compatible single-parameter form (Recommended)

**Approach:** Use `.onChange(of: launchAtLogin) { newValue in`.

**Effort:** 5 minutes (plan update)

**Risk:** Low

## Recommended Action

*To be filled during triage.*

## Technical Details

**Affected plan sections:**
- Lines 157-164 (SettingsView onChange)

## Acceptance Criteria

- [ ] All `onChange(of:)` calls use single-parameter closure syntax
- [ ] Plan compiles on macOS 13+

## Work Log

### 2026-02-15 - Initial Discovery

**By:** Claude Code (Technical Review)

**Actions:**
- Pattern Recognition flagged this as a compile-time error on the target platform
