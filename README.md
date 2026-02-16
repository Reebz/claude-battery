# 🔋 Claude Battery

Your Claude usage, at a glance. A macOS menu bar widget that shows how much of your weekly quota remains — as a battery.

## Why a battery?

Tokens don't mean much to most people. They tick over in Claude Cowork or Claude Code, but unless you've memorized your plan's limits, the numbers are just noise. Change your plan and the goalposts move again.

A battery is something everyone already understands. Full means you're good. Half means pace yourself. Red means slow down. No documentation required.

There are other usage widgets out there — good ones. Claude Battery takes a different approach: **what can we remove** instead of what can we add. The result is something lightweight enough to forget it's running, and clear enough to understand at a glance.

This is built for the marketers, designers, writers, and anyone else who uses Claude daily but doesn't think in tokens. That said, if you're an engineer who wants usage monitoring that stays out of the way, you're exactly who this is for too.

## Features

- Battery icon in your menu bar with fill level and percentage — exactly what you'd expect
- Session usage bar with reset countdown so you know when your quota refreshes
- Per-model breakdown (Opus, Sonnet) in the popover for when you want the detail
- Icon turns red below 20% so you won't get caught off guard
- Adaptive polling — checks more frequently when usage is high, backs off when it's not
- Launch at login so it's always there
- Optional notifications when usage gets low

## Installation

Download the latest `.dmg` from the [downloads](./downloads) folder, open it, and drag Claude Battery to your Applications folder.

## Usage

1. Launch Claude Battery from Applications
2. Click the battery icon in the menu bar to sign in
3. Authenticate with your claude.ai account
4. That's it — usage updates automatically in the background

Right-click the menu bar icon for Settings and Quit options.

## Building from Source

Requires Xcode 15+ and macOS 14+.

```bash
git clone https://github.com/Reebz/claude-battery.git
cd claude-battery
open ClaudeBattery/ClaudeBattery.xcodeproj
```

Build and run with Cmd+R.

---

## Support

If you find Claude Battery useful, consider buying me a coffee.

[![Buy Me A Coffee](https://private-user-images.githubusercontent.com/1386738/550422844-14c36bed-46d3-40a1-ad34-00cdbbac3955.gif?jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbSIsImtleSI6ImtleTUiLCJleHAiOjE3NzEyNDIzOTQsIm5iZiI6MTc3MTI0MjA5NCwicGF0aCI6Ii8xMzg2NzM4LzU1MDQyMjg0NC0xNGMzNmJlZC00NmQzLTQwYTEtYWQzNC0wMGNkYmJhYzM5NTUuZ2lmP1gtQW16LUFsZ29yaXRobT1BV1M0LUhNQUMtU0hBMjU2JlgtQW16LUNyZWRlbnRpYWw9QUtJQVZDT0RZTFNBNTNQUUs0WkElMkYyMDI2MDIxNiUyRnVzLWVhc3QtMSUyRnMzJTJGYXdzNF9yZXF1ZXN0JlgtQW16LURhdGU9MjAyNjAyMTZUMTE0MTM0WiZYLUFtei1FeHBpcmVzPTMwMCZYLUFtei1TaWduYXR1cmU9OTYzOTJkMWQyNDg5ZDI2OTMzY2VjMTU3YWNlYjI4ZWEwMGFmOGMzMjBmYzM1MDk2NDA5MGNjYWIwMWJlZmU0YiZYLUFtei1TaWduZWRIZWFkZXJzPWhvc3QifQ.oKHIp7WY4y-11I2acQ8fatUk2MQQoinf4Hsy6W6mgo4)](https://buymeacoffee.com/reebz)

## License

[MIT](LICENSE)
