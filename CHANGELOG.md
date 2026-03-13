# Change Log

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
