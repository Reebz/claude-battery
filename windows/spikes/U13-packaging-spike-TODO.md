# U13 spike (TODO): Velopack + SignPath + single-file packaging chain

Status: NOT RUN. This spike needs a real Windows box, the `vpk` (Velopack) CLI, and one approved
SignPath Foundation project (a third-party-controlled enrollment). It cannot run on macOS, so it was
deferred. Everything below is the script to run and the exact decision the result feeds.

## Why this gates distribution

The distribution chain has three pieces that have never been proven to compose together for this
app, and service code already assumes the result (the stable `current\App.exe` path that autostart
in `AutostartService.cs` and update-apply in `UpdateService.cs` depend on). Prove the chain before
trusting that path:

1. **Single-file publish vs Velopack's own bundling.** The csproj publishes self-contained
   single-file with `IncludeNativeLibrariesForSelfExtract=true` (so `WebView2Loader.dll` bundles).
   Velopack also bundles. Running both can double-bundle or fight over the extraction layout. Decide
   which one produces the distributable.
2. **SignPath's async submit-and-poll vs Velopack's synchronous `--signTemplate` hook.** They do not
   compose cleanly: `--signTemplate` expects `{{file}}` signed IN PLACE by the time the templated
   command returns, but SignPath submits an artifact and you POLL for the signed result. `build/pack.ps1`
   already encodes the workaround (sign the published exe BEFORE pack, sign Setup.exe AFTER pack, no
   `--signTemplate`); this spike confirms that workaround actually round-trips against a real SignPath
   project.
3. **WebView2 init from the PACKAGED single-file build**, not just `dotnet run`. Single-file extraction
   and InPrivate UDF creation can behave differently when the runtime ships inside the packed bundle.

## What to run

On a Windows box with `vpk` installed and a SignPath Foundation project approved:

1. **Hello-world first.** Build a trivial WPF exe (or the spike auth app), run `vpk pack` against its
   self-contained single-file publish, and confirm the installer + delta + RELEASES feed are produced
   and that a stable `current\` launcher path exists after install.
2. **Reconcile single-file vs Velopack bundle.** Try publishing with `PublishSingleFile=true` and packing;
   then try without; compare which produces a working installer where the app launches and the
   `current\App.exe` path is stable across a simulated update. Record the verdict.
3. **One full SignPath round-trip wired into pack.** Run `build/pack.ps1` with the SignPath env vars set
   (`SIGNPATH_API_TOKEN`, `SIGNPATH_ORGANIZATION_ID`, `SIGNPATH_PROJECT_SLUG`,
   `SIGNPATH_SIGNING_POLICY_SLUG`). Confirm both passes sign: the published `ClaudeBatteryWin.exe`
   before pack, and `*Setup.exe` after pack. Verify each signed artifact with `signtool verify /pa`.
4. **WebView2 from the packaged build.** Install the packed Setup.exe, launch the installed app (NOT
   `dotnet run`), and confirm a WebView2 control initializes (open the login window and reach
   claude.ai). This is the single-file + bundled-loader reality check.
5. **Unsigned-payload block (manual, policy not code).** With Smart App Control on, confirm an UNSIGNED
   Velopack update is OS-blocked at apply time (do not ship it; this just confirms the gate exists).

## Pass / fail signals

- **Packaging reconciliation (steps 1-2):** PASS = a single produced installer where the app launches
  and `current\App.exe` is stable across an update. Record WHICH publish mode won (single-file on or
  off). FAIL = double-bundling, a missing/changing `current\` path, or a non-launching install -> the
  autostart + update-apply assumptions break and `build/pack.ps1` + the csproj publish props need
  adjusting before U12 ships.
- **SignPath round-trip (step 3):** PASS = both artifacts come back signed and `signtool verify /pa`
  succeeds. FAIL or enrollment STALLED = fall back to the OV-cert path (`OV_CERT_PFX_PATH` /
  `OV_CERT_PASSWORD`, already wired in `Sign-Artifact`) to start the SmartScreen reputation clock; do
  NOT ship unsigned to real users.
- **WebView2 from packaged build (step 4):** PASS = the WebView2 control initializes and reaches
  claude.ai from the installed single-file build. FAIL = single-file extraction is not surfacing
  `WebView2Loader.dll`; flip `IncludeNativeLibrariesForSelfExtract` / publish mode per the step-2 verdict.

## What the result gates

- **U12 packaging + auto-update:** the single-file-vs-Velopack-bundle verdict and the working SignPath
  (or OV-cert) invocation are exactly what `build/pack.ps1` and the release CI consume. The stable
  `current\App.exe` confirmation is what `AutostartService.CanonicalExePath` and
  `UpdateService.ApplyUpdateAsync` rely on.
- **The signed-build Definition of Done** for U12 has an exogenous gate (SignPath enrollment approval);
  this spike is where that approval is first exercised end-to-end.
