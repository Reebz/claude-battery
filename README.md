# Claude Battery

A macOS menu bar widget that displays your Claude Pro/Max usage as a battery icon.

## Features

- Battery icon showing weekly quota remaining with fill level and percentage
- Session usage bar with percentage and reset countdown
- Per-model breakdown (Opus, Sonnet) in the popover
- Low usage warnings (icon turns red below 20%)
- Adaptive polling intervals based on usage level
- Launch at login support
- Optional low-usage notifications

## Installation

Download the latest `.dmg` from the [downloads](./downloads) folder, open it, and drag Claude Battery to your Applications folder.

## Usage

1. Launch Claude Battery from Applications
2. Click the battery icon in the menu bar to sign in
3. Authenticate with your claude.ai account
4. Usage updates automatically in the background

Right-click the menu bar icon for Settings and Quit options.

## Building from Source

Requires Xcode 15+ and macOS 14+.

```bash
git clone https://github.com/Reebz/claude-battery.git
cd claude-battery
open ClaudeBattery/ClaudeBattery.xcodeproj
```

Build and run with Cmd+R.

## License

[MIT](LICENSE)
