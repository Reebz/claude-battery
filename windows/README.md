# Claude Battery for Windows

A standalone Windows system-tray app that mirrors the macOS Claude Battery: it shows claude.ai usage
as a battery icon in the tray, with a borderless Fluent flyout, multiple accounts, DPAPI-encrypted
secrets, and Velopack in-app auto-update. C#/.NET 8 + WPF + WebView2. The macOS app under
`../ClaudeBattery/` is a separate codebase and is untouched.

The port shipped as a beta at macOS v1.50 parity and is being brought up to v1.72. See
`../docs/plans/2026-08-05-001-feat-windows-parity-plan.md` for the current plan and
`../docs/plans/2026-09-10-windows-parity-gap-register.md` for per-requirement status.

## Layout

```
windows/
  ClaudeBatteryWin.sln
  src/ClaudeBatteryWin/        # the app (net8.0-windows10.0.19041.0, WPF, tray-only)
    App.xaml(.cs)              # windowless startup, single-instance, DI composition root
    Services/                  # ClaudeApi, UsageService, AccountStore, SecretStore, AuthManager,
                               #   WebView2Runtime, UpdateService, ThemeWatcher, Notifier, ...
    Models/                    # Account, UsageSnapshot, UsageLimit, SpendInfo, Credits, ...
    ViewModels/                # FlyoutViewModel
    Views/                     # FlyoutWindow, LoginWindow, RuntimeMissingWindow, SettingsWindow, OrgPicker
    Icons/                     # DualHorizontalRenderer (the default tray icon)
  tests/ClaudeBatteryWin.Tests/  # xUnit (built-in Assert API; no FluentAssertions)
  build/pack.ps1               # vpk pack + SignPath signing (release-side; Windows only)
  spikes/                      # U2 + U13 spike TODO docs (NOT yet run)
```

## Build and test (Windows)

Requires the .NET 8 SDK (`dotnet --version` >= 8.0) on Windows. The target framework is
`net8.0-windows10.0.19041.0` (the Windows-10-versioned moniker needed for the WinRT toast APIs), so
the build and test run on Windows, not macOS or Linux.

```powershell
# from the windows/ directory
dotnet restore
dotnet build -c Release
dotnet test -c Release --no-build
```

CI mirrors these exact steps. `.github/workflows/windows-ci.yml` (at the repo root) runs on
`windows-latest`, restores, builds `-c Release`, and tests `-c Release --no-build`, in
`working-directory: windows`. It triggers on push to `feat/windows-port` and
`fix/windows-session-restore`, and on every pull request. It does not touch the GitHub Pages deploy
(`pages.yml`) or the macOS app.

CI is the only automated gate: there is no Windows machine in the loop. Two jobs carry the evidence.
`build-test` writes every tray-icon state as a PNG into the `tray-icons` artifact (plus the flyout
dial, when the render spike in `FlyoutSnapshotSpikeTests` passes on the runner). `smoke-launch`
publishes the exe, runs it on the runner's desktop, opens the tray overflow and the flyout, and
uploads desktop screenshots as the `smoke-launch` artifact. Judge a rendering change by opening those
artifacts on the run.

### Run / package a release build

Releases are built on Windows via `build/pack.ps1` (the analog of the Mac `scripts/release.sh`): it
publishes the self-contained single-file app, runs `vpk pack`, and signs via SignPath Foundation
(OV-cert fallback wired in). That script is gated on the U13 spike below.

## Current state

The gap register at `../docs/plans/2026-09-10-windows-parity-gap-register.md` is the tracking
document: it carries every parity requirement with its status, the Windows and Mac evidence behind
it, and the commit that closed it. This section lists only what CI can never settle.

Verified in the field or on CI:

- The app builds, tests, and launches on the runner, and has shipped to a beta tester.
- Cookie replay works. A `SocketsHttpHandler` seeded with WebView2-captured cookies and the matched
  user agent polls `/api/organizations/{org}/usage` without a Cloudflare 403, which was the port's
  biggest open risk. The `IClaudeApi` / `SwappableClaudeApi` seam that would have let polling move
  inside WebView2 stays in place but is not needed.

Field-gated, and written down as unverified rather than assumed fixed:

- **Anything judged by eye on a real Windows screen.** Tray icon legibility in the live notification
  area, flyout layout at non-integer DPI scales, and Fluent theming against a real desktop.
- **A real sign-in against claude.ai.** The login state machine is driven by `ILoginWebView` fakes in
  the tests; provider coverage (email code, Google, Apple, company single sign-on) and the exact
  shape of a live `GET /api/account` response can only be confirmed by signing in.
- **Diagnostics export to an unusual destination.** A reparse point, a mapped drive, or a cloud-sync
  placeholder folder cannot be fabricated on the runner.
- **Toast notification permission.** Whether reading the setting throws on this app's unpackaged
  registration is unknown; the read is wrapped either way.
- **The packaging and signing chain.** `build/pack.ps1` encodes the intended Velopack plus SignPath
  flow but has never round-tripped against a real SignPath project. No signed build exists, so
  SmartScreen reputation has not started. Distribution is out of scope for the parity plan.
