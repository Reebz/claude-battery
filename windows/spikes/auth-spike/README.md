# U2 auth + Cloudflare spike (runnable harness)

This is the throwaway harness for the spike scripted in `../U2-auth-cloudflare-spike-TODO.md`. It
exists so the single most load-bearing assumption of the Windows port - whether a `SocketsHttpHandler`
poll seeded with WebView2-captured cookies clears Cloudflare, or gets a 403 because the TLS/JA3
fingerprint does not match - is one `dotnet run` away on a real Windows box.

It cannot run on macOS (WPF + WebView2). It must be run on a real Windows box, with a real claude.ai
login, on a live network.

## Why it references the production project

`AuthSpike.csproj` has a `ProjectReference` to `../../src/ClaudeBatteryWin/ClaudeBatteryWin.csproj`,
so the gate fires through the REAL `ClaudeApi` transport and the REAL `AccountStore.PrimeCookies`
jar-priming. The result is a verdict about the shipped code, not a copy that can drift.

## Run

```powershell
cd windows/spikes/auth-spike
dotnet run
```

A window opens on `claude.ai/login` in an ephemeral InPrivate WebView2 (isolated user-data folder,
deleted on close - identical config to the production `LoginWindow`).

1. **Log in** with the provider you want to test (Google / Apple / email-code / Entra-SSO).
2. When the dashboard has loaded, click **Run U2 gate test**.
3. Read the log panel. Click **Copy log** to capture it.

## The gate readout (the one decision this feeds)

The `[GATE]` / `[RAW]` lines give the verdict:

- **200, no challenge body** -> the `SocketsHttpHandler` cookie-replay clears Cloudflare. The default
  `ClaudeApi` transport (already wired in `App.xaml.cs` via `SwappableClaudeApi`) is correct as-is.
  **GO on the current architecture; U14 is not needed.**
- **401/403, or a Cloudflare challenge body** -> the TLS/JA3 fingerprint is gating the out-of-process
  poll. **Implement U14:** a second `IClaudeApi` that polls INSIDE the authenticated WebView2, swapped
  in at `App.BuildObjectGraph` / `App.RebuildApiWithUserAgent` via `SwappableClaudeApi.Swap`. No other
  unit changes, because everything consumes `IClaudeApi`.

## What else to record (the rest of the spike script)

The harness logs these automatically; copy them into the spike doc's result section:

- `[RUNTIME]` - what `GetAvailableBrowserVersionString(null)` returned or threw (feeds U8).
- `[COOKIES]` - whether `sessionKey` + `__cf_bm` were captured HttpOnly (confirms U6 capture).
- `[UA]` - that a session UA was captured (length only).
- `[UDF]` - that session material lands on disk during the session (confirms the production
  sweep/delete in `LoginWindow` is load-bearing security, not theatre).

Record by hand (the harness cannot infer these):

- **Per-provider login outcome** (step 2): for each provider you try, note completes / blocked
  (`disallowed_useragent`) / partial, and whether the `NewWindowRequested` OAuth popup flow completed.
  A blocked embedded Google flow is acceptable IF the email-code steering funnel + manual paste cover
  it; it makes that funnel required, not optional.

## Security

Cookie/session values, response bodies, and the UA string are never written to the log - only names,
HttpOnly/Secure flags, status codes, header presence, and body length. The harness stays inside the
same redaction discipline as the shipped app. The ephemeral UDF is deleted on window close.

## Throwaway

Delete `windows/spikes/auth-spike/` once the spike has run and its verdict is recorded in the spike
doc and acted on (GO, or U14 implemented). It is not part of the shipped solution or its CI.
