# Change Log

### v1.49

**Sign-In Reliability & Opt-In Diagnostics**
- Getting signed in is more reliable for accounts the embedded window could not finish on its own. A clear "use an email code" prompt steers you to the path that works in-app, the "Finishing sign-in" screen now recovers with "Try again" or "Sign in manually" instead of leaving a blank window, and a manual cookie-paste fallback covers Google-federated and passkey-only accounts (issues #7, #17, #25).
- New opt-in Diagnostics section in Settings: turn on logging, reproduce a sign-in problem, then export a redacted log archive to attach to a GitHub issue. No passwords, tokens, or emails are ever saved - the export ships only controlled, redacted logs, and the producer stays completely off until you opt in.
- Hardened the redaction and export internals so a future logging change cannot leak a secret: airtight handling of values nested under credential keys, per-launch log files with retention, and an end-to-end no-secrets gate in the test suite.
- 297 automated tests (up from 173).

### v1.48

**Unified Usage Bars, USD Currency Fix, Claude Design Preview**
- Extra Usage and Prepaid rows now render as battery-direction bars: green when remaining is high, transitioning to red as it depletes. Right-side text reads "$X remaining of $Y" so the meaningful number is the one in front of you.
- Prepaid gets a real denominator: each successful poll records the observed balance into a per-account 100-day rolling high-water-mark, so the bar fills against your maximum-observed balance instead of a guess.
- Added a "Claude Design" placeholder row between Prepaid and the Resets card. It currently shows "Coming soon" and an empty track; the row will display Claude Design usage once Anthropic exposes the data via the claude.ai usage API. Until then it is a deliberate stub.
- Fixed currency display for users on non-USD locales (thanks to @AllDmeat for issue and patch). Anthropic charges in USD; the popover now pins the currency code to USD so ru_RU and similar users see "$" instead of their local currency code. Number separators stay locale-aware.
- 173 automated tests (up from 155).

### v1.47

**Sign-In Hardening, Bug Fixes & Prepaid Balance**
- Fixed "Can't get signed in" (issue #7): Google OAuth popups now work correctly, full cookie header capture for Cloudflare compatibility, debug network logging for diagnosis
- Fixed invisible menu bar icon after upgrade (issue #10): polling now restarts after re-authentication to the same org, icon shows "!" on auth failure, auto-login on first launch
- Fixed 99.5% CPU usage with external monitors (issue #11): appearance KVO guard uses bestMatch to collapse sub-variants, IconSignature dedup prevents redundant renders, diagnostic counters for remote debugging
- Fixed update checker false positive when comparing "1.45" vs "1.45.0"
- Added prepaid credit balance display in the popover
- Hardened cookie capture with dashboard URL detection for SPA navigation
- 155 automated tests (up from 92)

### v1.45

**Multi-Org Support & Login Fixes**
- Added organization picker for users with multiple plans (e.g., Team + Free) on the same email
- Fixed 100%/100% false usage display when the wrong org was auto-selected
- Fixed Google OAuth "error logging you in" by replacing the User-Agent append with a full override
- Fixed immediate "Session expired" after email/code login by removing unreliable cookie expiration trust
- Re-authentication now auto-selects the previously used org when it's still available
- Added 92 automated tests covering all services and models

### v1.44

**Sign-In Timeout Fix**
- Fixed login window closing on its own while checking email for the verification code
- Login timeout now resets on each page navigation instead of counting from when the window first opens
- Extended idle timeout from 5 minutes to 10 minutes

### v1.42

**Sign-In Reliability**
- Fixed login window closing before account was actually saved, causing "Session expired" after sign-in
- All sign-in errors now show clear messages instead of failing silently
- Added "Signing in..." spinner so you know the app is working
- Fixed a bug that could permanently lock out sign-in until app restart

### v1.41

**New Icon Styles**
- Claude Battery has new, even more minimalists styles
- Still maintains the battery concept (100% to zero)
- Also added Homebrew install option!

### v1.4

**Update Notifications**
- Claude Battery now checks for new versions once per day via the GitHub Releases API
- When an update is available, the popover footer shows a "v1.x available -- Download" link
- Clicking the link opens the GitHub release page in your browser
- Non-intrusive -- only visible in the popover footer, disappears after updating

### v1.3

**Extra Usage Spend Tracking**
- New horizontal spend bar in the popover shows your extra usage spend against your monthly limit
- Automatically appears when Extra Usage is enabled on your claude.ai account, hidden otherwise
- Displays amounts in your local currency (e.g., A$ for AUD, $ for USD)
- Colour-coded progress: cyan when low, orange approaching limit, red near limit

### v1.2

**Security & Stability Hardening**
- Fixed Keychain password prompt loop caused by URLSession credential storage -- switched to ephemeral sessions
- Hardened auth flow: fixed race conditions in cookie capture, secured domain validation, added session expiration tracking
- Code-signed DMG for smoother installation

### v1.1.1

**Bug Fixes**
- Fixed indefinite "Fetching usage..." spinner caused by silent failure paths in the polling state machine

### v1.1

**Multi-Account Sign-In**
- Sign into up to 5 separate Claude.ai accounts
- Switch between accounts instantly from the popover
- Click the pencil icon on any account to set a custom nickname

### v1.0

**Initial Release**
- Dual battery icons in the menu bar (Session and Weekly)
- Popover with arc gauges, model breakdown, and reset timers
- Low usage notifications with configurable threshold
- Launch at login option
