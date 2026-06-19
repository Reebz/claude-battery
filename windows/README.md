# Claude Battery for Windows

A standalone Windows system-tray app that mirrors Claude Battery v1.50: it shows claude.ai usage as
a battery icon in the tray, with a borderless Fluent flyout, up to 5 accounts, DPAPI-encrypted
secrets, and Velopack in-app auto-update. C#/.NET 8 + WPF + WebView2. The macOS app under
`../ClaudeBattery/` is a separate codebase and is untouched.

This is a port-in-progress. See `../docs/plans/2026-06-19-001-feat-windows-port-plan.md` for the
plan and `../docs/brainstorms/2026-06-19-windows-port-requirements.md` for requirements.

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
`working-directory: windows`. It triggers on push to `feat/windows-port` and on every pull request.
It does not touch the GitHub Pages deploy (`pages.yml`) or the macOS app.

### Run / package a release build

Releases are built on Windows via `build/pack.ps1` (the analog of the Mac `scripts/release.sh`): it
publishes the self-contained single-file app, runs `vpk pack`, and signs via SignPath Foundation
(OV-cert fallback wired in). That script is gated on the U13 spike below.

## Spike gates (UNPROVEN)

Two spikes must run on a real Windows box before the corresponding assumptions can be trusted in
production. Neither has run (they need a Windows box, a real claude.ai login, and SignPath):

- **U2 — WebView2 auth + Cloudflare cookie-replay.** `spikes/U2-auth-cloudflare-spike-TODO.md`. The
  load-bearing test: fire a real `GET /api/organizations/{org}/usage` from a `SocketsHttpHandler`
  seeded with WebView2-captured cookies + the matched UA and assert **200, not 403**. A 403 means the
  TLS/JA3 fingerprint gates the separate-`HttpClient` poll and polling must move into WebView2.
- **U13 — Velopack + SignPath + single-file packaging.** `spikes/U13-packaging-spike-TODO.md`. Prove
  `vpk pack` + single-file reconciliation + one SignPath submit-and-poll round-trip compose, and that
  WebView2 initializes from the packaged single-file build.

The code is structured so the U2 verdict is a one-line composition-root change: every consumer holds
`IClaudeApi`, and the transport is wrapped in `SwappableClaudeApi`, so switching to an in-WebView2
transport is `Swap`-in only (`App.BuildObjectGraph` / `App.RebuildApiWithUserAgent`).

## What is NOT yet verified

Be explicit about the state of this tree:

- **Nothing here has compiled.** The source was authored on macOS, where the WPF/WebView2/WinRT
  target framework cannot build. First compilation + test run happens on Windows CI
  (`windows-ci.yml`). Expect to fix compile errors there.
- **The "`SocketsHttpHandler` clears Cloudflare" assumption is unproven** (U2). The default transport
  is a `SocketsHttpHandler` + shared `CookieContainer`; if the fingerprint gates it (403), the
  in-WebView2 polling fallback must be implemented and swapped in. This is the single most
  load-bearing assumption in the port.
- **The packaging/signing chain is unproven** (U13). `build/pack.ps1` encodes the intended
  SignPath-async-vs-Velopack-sync workaround, but it has not round-tripped against a real SignPath
  project, and the single-file-vs-Velopack-bundle reconciliation is not decided.
- **Embedded provider login coverage is unknown** (U2 provider matrix). Email-code + manual cookie
  paste are the default-on fallbacks; embedded Google/Apple/SSO is progressive enhancement only where
  the spike proves it completes.
- **SystemEvents in a windowless WPF app** (`PowerModeChanged` for wake-repoll, `UserPreferenceChanged`
  for theme) are assumed to fire; if they do not, the fallback is a hidden message-only window
  (noted in `App.xaml.cs`). The U1 verification step covers this.
- **WebView2 UDF disk residual** is assumed; U2 confirms what actually lands on disk so the
  `LoginWindow` sweep/delete paths are covering a real file.
- **No signed build exists**, so SmartScreen reputation has not started; that is gated on SignPath
  enrollment (an external approval).
