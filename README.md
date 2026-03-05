
# <img src="https://iili.io/qdnWVN1.png" width="80" height="72"> Claude Battery

Your Claude usage at a glance. A macOS menu bar widget that shows your Claude session and weekly limits... as a battery. [Download here](https://github.com/Reebz/claude-battery/releases/download/v1.41/claude-battery_v1.41.dmg).

<img src ="https://iili.io/qdnW1SV.png" width="180" height="80">

## Why a battery?

A battery is something everyone already understands. Full means you're good. Half means pace yourself. No documentation required.

Tokens just don't *feel* like anything to me. However once Opus 4.6 landed, I was quickly aware I needed to keep an eye on usage.

I have watched (probably) millions of them tick over in Claude Cowork or Claude Code, but unless you've memorized your plan's limits, the numbers are noise (and then change your plan and the goalposts move again). More and more of my colleagues who are marketers, designers, writers or creatives use Claude daily. They just don't think in tokens or try to optimize for chasing the bleeding edge of token min/maxing, but they did find themselves constantly having to go into Claude > Settings > Usage and double check they weren't setting their quota on fire -- that's why I built this. That said, if you're an engineer who wants usage monitoring that stays out of the way... you're exactly who this is for too.

There are other good usage widgets out there... great ones in fact. Claude Battery takes a different approach: **what can we remove** instead of what can we add - or ["Simplify, and add lightness"](https://www.classicdriver.com/en/article/genius-colin-chapman-simplify-then-add-lightness%E2%80%9D) in the words of Chapman. The result is something lightweight enough to forget it's running, and clear enough to understand at a glance.

And lastly, ["Invert, always invert".](https://www.stripe.press/poor-charlies-almanack/talk-four?progress=14.36%#:~:text=The%20third%20helpful,an%20irrational%20number.)

## Installation

[Download here](https://github.com/Reebz/claude-battery/releases/download/v1.41/claude-battery_v1.41.dmg), or manually find the latest `.dmg` file from the downloads folder, open it, and drag Claude Battery to your Applications folder.

## How To Use

1. Launch Claude Battery from Applications
   > Apple may give a warning about opening a downloaded app. To launch, right-click and open.
2. Left-click the battery icon in the menu bar to sign in
3. Sign in with your claude.ai account (you may be asked to use a 6-digit code)
4. That's it -- usage updates automatically in the background. Left-click the battery icon for more details.

Right-click the menu bar icon for Settings, Notification customization, and to Quit.

## Features

**Menu Bar**
- Two battery icons with fill level and percentage -- Session (5-hour) and Weekly (7-day)
- Battery icon turns red below 20% so you won't get caught off guard
- 5 selectable icon styles: Dual Horizontal (default), Minimal, Dual Arc Gauge, Text Only, Stacked Bars

**Popover (left-click)**
- Session and Weekly usage arc gauges with colour-coded fill
- Extra Usage spend tracking bar -- see how much you've spent against your monthly limit (only shows when Extra Usage is enabled on your account)
- Per-model breakdown (Opus and Sonnet) with horizontal progress bars
- Session and Weekly reset countdown timers
- Account switcher with inline nickname editing (multi-account)

**Notifications**
- Low usage alert when your weekly quota drops below a configurable threshold
- Notification threshold adjustable from 5% to 50% in Settings (right-click)

**Multi-Account**
- Sign into up to 5 separate Claude.ai accounts (work, personal, side projects)
- Switch between accounts instantly from the popover
- Custom nicknames per account

**General**
- Lightweight and fast -- checks usage every 2 minutes
- Update notifications -- checks for new versions daily and shows a download link in the popover
- Launch at login option in Settings
- Browser-based sign-in (no Keychain prompts)
- Privacy-first -- no analytics, no tracking, no data collection

<img src="https://iili.io/qdwFrAJ.md.png">

## What's New

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

## Support

If you find Claude Battery useful, consider [buying me a coffee](https://buymeacoffee.com/reebz).<br>
<a href="https://www.buymeacoffee.com/reebz" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

## Credits

- Extra usage spend in local currency: thank you to [@theleoborges](https://github.com/theleoborges) for the feature idea.
- Multi-account support: thank you to [@joeymnguyen](https://github.com/joeymnguyen) for the feature idea.
- Popover UI: After deciding on the design direction, I found [Watts](https://apps.apple.com/us/app/watts/id422559334?mt=12) that served as inspiration

## Privacy Policy

Claude Battery does not collect, store, or transmit personal data.

The app:
- Does not include analytics
- Does not include tracking
- Does not share data with third parties
- Does not store user data on external servers

Claude Battery only retrieves usage information associated with the user's Claude account. All communication occurs between the user's device and claude.ai.

No data is retained by the developer.

## License

[MIT](LICENSE)
