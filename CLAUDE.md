# Claude Battery

macOS menu bar widget (Swift/SwiftUI) showing Claude.ai usage as a battery icon.

## Build & Release

```bash
# Full release (build, sign, notarize, DMG, deploy)
./scripts/release.sh
```

For alpha/test builds, archive manually:
```bash
xcodebuild -project ClaudeBattery/ClaudeBattery.xcodeproj \
  -scheme ClaudeBattery -configuration Release \
  -derivedDataPath /tmp/ClaudeBattery-build/derived \
  -archivePath /tmp/ClaudeBattery-build/ClaudeBattery.xcarchive archive
```

- Xcode project: `ClaudeBattery/ClaudeBattery.xcodeproj`
- Scheme: `ClaudeBattery`
- Build output: `/tmp/ClaudeBattery-build/` (NOT iCloud — avoids provenance xattrs)
- Signing: `Developer ID Application: [REDACTED]`
- Notarization keychain profile: `ClaudeBattery`

## Architecture

- Deployment target: macOS 13.5+
- Bundle ID: `com.reebz.claudebattery`
- LSUIElement app (menu bar only, no Dock icon)
- `Services/AuthManager.swift` — Login flow, WKWebView cookie capture, org discovery
- `Services/UsageService.swift` — Background polling with exponential backoff
- `Services/AccountStore.swift` — Multi-account state (max 5)
- `Services/ClaudeAPI.swift` — Shared ephemeral URLSession, request headers
- `Views/UsagePopoverView.swift` — Main UI state machine
- `Views/MenuBarController.swift` — Menu bar icon rendering

## Gotchas

- WKWebView uses non-persistent data store — cookie observer is unreliable, triple-redundant capture required
- Auth has had 8 rounds of hardening — check docs/solutions/ before modifying
- Build directory MUST be outside iCloud/Dropbox to avoid com.apple.provenance xattrs
- Version must be bumped in TWO places in project.pbxproj (Debug + Release)

## Distribution

### Release checklist
1. Bump `MARKETING_VERSION` in project.pbxproj (both Debug + Release configs)
2. Update CHANGELOG.md
3. Run `./scripts/release.sh` (builds, signs, notarizes, copies DMG, updates Homebrew cask)
4. Update download links in: README.md, site/index.html (hero button + install card)
5. Push to main (triggers GitHub Pages deploy for site/ changes)
6. Create GitHub release: `gh release create v{X} /tmp/ClaudeBattery-build/claude-battery_v{X}.dmg --title "v{X}"`

- DMG: `downloads/` folder + GitHub Releases
- Homebrew: `reebz/claude-battery` tap (auto-updated by release.sh)
- Website: `site/` folder → GitHub Pages (auto-deploys on push to main when site/ changes)
- Download links exist in: README.md, site/index.html (both hero + install section)
