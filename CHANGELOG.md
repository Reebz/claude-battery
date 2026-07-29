# Change Log

### v1.70

**Session Dial**
- When your weekly limit is nearly gone, the Session dial now converts what is left of the week into session terms instead of showing the weekly percentage on a gauge that measures sessions. With 6% of a week left on Max 5x it reads 76%, because that is roughly how much of a 5-hour window you can still use. It previously read 6%, which made a full session look empty.
- The app reads your plan from your account to do that conversion. On a plan it does not recognise, it shows the true session number rather than guessing.
- Each account also works out its own conversion from your real usage over time, and once that is reliable it is used in place of the published figures.
- An exhausted week now reads 0% and says so, even before the app knows your plan.

**Sign-In**
- One sign-in repairs every organization stored under that account. Previously an expired session came back one organization at a time, so you signed in, switched organizations in Settings, and pasted the same credentials again (issue #41).
- Fixed a bug where cancelling a sign-in could leave a different account you were already using unable to refresh, showing as expired until you switched accounts or restarted.
- Pasting only a session key no longer reports success and then fails on the next check.
- The manual paste box stays available when you have reached the account limit, which is when Google and passkey accounts need it most.
- Accounts now show your email address instead of "Account 1".

**Accounts**
- You can now store up to 10 accounts, up from 5. Each organization counts as one, and only the active one is polled, so the extra entries cost nothing.

**Popover**
- The update notice moved to the top of the popover, where it is easier to see, and the last-updated line no longer disappears when an update is waiting.
- Removed the Claude Design row.

**Diagnostics**
- Diagnostics can now record which plan your account is on, so limits can be confirmed on plans we cannot see directly. It records no email address, organization name, or account identifier.

**Documentation**
- The README explains what the Models card shows: your weekly quota per model, how much is left rather than how much is used, and why the models listed depend on your plan (issue #42).

### v1.60

**Concentric Usage Arcs**
- Each Session and Weekly dial is now a two-ring gauge: an outer ring for how much usage is left and an inner ring for how much of the window's time is left. When the inner ring runs longer than the outer one, you are using the quota faster than the clock (issue #31).
- A short pace label sits under each dial - On Track, Caution, or Danger - colored green, amber, or red by how far usage is running ahead of the time left.

**Sign-In**
- You can now add a second organization from the same account through manual sign-in. Reusing the saved account cookie no longer stops at the first organization it finds (issue #32).

### v1.50

**Sign-In Reliability & Opt-In Diagnostics**
- Getting signed in is more reliable for accounts the embedded window could not finish on its own. A clear "use an email code" prompt steers you to the path that works in-app, the "Finishing sign-in" screen now recovers with "Try again" or "Sign in manually" instead of leaving a blank window, and a manual cookie-paste fallback covers Google-federated and passkey-only accounts (issues #7, #17, #25).
- New opt-in Diagnostics section in Settings: turn on logging, reproduce a sign-in problem, then export a redacted log archive to attach to a GitHub issue. No passwords, tokens, or emails are ever saved - the export ships only controlled, redacted logs, and the producer stays completely off until you opt in.
- Hardened the redaction and export internals so a future logging change cannot leak a secret: airtight handling of values nested under credential keys, per-launch log files with retention, and an end-to-end no-secrets gate in the test suite. A follow-up adversarial fuzz pass closed every remaining redaction edge case (unusually shaped or padded credential keys, delimiter remnants, decomposed-Unicode emails, and non-Bearer auth schemes), and the diagnostic export now writes over an existing file atomically so a failed save can never destroy it.
- Sign-in recovery is cleaner: an org-discovery failure now shows a single recoverable error card with "Try again" / "Sign in manually" instead of a redundant alert sheet that blocked those buttons, cancelling the organization picker no longer silently retries on the next cookie poll, and the no-organizations message now notes that a Pro or Max plan may be required.
- Continuing with Google now works in non-US regions. The sign-in window was blocking Google's country-specific account hosts (e.g. `accounts.google.com.tr`) that the OAuth flow redirects through after login, leaving a blank screen. Those localized Google hosts are now allowed, matched exactly per the OAuth-domain hardening rule (issues #17, #25; fix contributed by @MidnightCoke in #24).
- The Session and Weekly reset countdowns no longer render blank for accounts whose usage API returns `resets_at` as a UNIX epoch or a fractional-second timestamp. The value is now parsed tolerantly, and a plan with no reset window shows "Reset times unavailable" instead of empty placeholders (issue #23).

**Usage Panel Overhaul**
- Per-model usage now comes straight from the usage API and is labeled with the model name the API reports (for example "Sonnet"). A model with no data for your account hides its bar instead of showing a frozen, full one, so the Opus bar that used to read 100% on accounts without Opus data is gone.
- The Session and Weekly gauges now carry evenly-spaced tick marks, so you can read roughly how much of each window is left at a glance.
- The credits section was rebuilt around the usage API's current shape. It shows whether spend-based usage is enabled, paused, or just a balance, reads the currency from each value (an Australian account now sees A$ instead of $), and shows the true percentage when you are over your limit (for example 103%) instead of capping the label at 100%. The rolling balance guess from v1.48 is gone.
- Usage bars turn orange below 45% remaining and red below 20%, a little earlier than before, so a low window stands out sooner.
- The "Claude Design" row now reads "Shares standard usage limits" instead of "Coming soon", since Claude Design draws from the same shared usage pool rather than a separate meter.

**Popover & Menu-Bar Polish**
- The Session and Weekly cards now show a time-remaining bar beneath each gauge, colored by your pace - green when you are on or under pace, red when you are burning through the window faster than the clock. A small clock icon and a percent label mark the bar as time, so the reading does not depend on color alone.
- The Models card now leads with an All Models bar (your combined weekly usage) above the per-model bars, so the total is the first thing you see.
- Usage Credits and Prepaid Balance now share a single line. The balance is pinned to the right and never truncates, while the status text flexes to fit.
- A new opt-in setting puts a compact session countdown (for example 4h+, then 32m) as a small tag left of the menu-bar icon, drawn in the same visual language as the battery digits. It refreshes about once a minute and rides the issue #11 CPU-fix path, so it does not spin the CPU.
- 383 automated tests (up from 173).

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
