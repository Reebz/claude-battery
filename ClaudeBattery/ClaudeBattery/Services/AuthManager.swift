import AppKit
import WebKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "Auth")

enum LoginState: Equatable {
    case idle
    case signingIn
    case error(String)

    /// True only in the `.error` state. The capture funnel (`captureSessionCookie`) checks this so a
    /// cancelled or failed login cannot auto-recapture the still-present session cookie while an
    /// error card is on screen. `retryLogin` resets `.error` -> `.idle` before reloading, so the
    /// user-initiated retry path is unaffected.
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

/// Which overlay (if any) is currently shown over the login WebView (U2).
enum LoginOverlayKind: Equatable {
    case none
    case signingIn
    case error
}

/// Outcome of the manual paste sign-in (U5). Drives the Settings UI's inline status.
enum ManualSignInResult: Equatable {
    /// Account added/reactivated. Carries its display name and how many ALREADY-STORED entries
    /// this action wrote fresh credentials to. The count is here because the picker route repairs
    /// the picked org's stored siblings in the same action (R2, issue #41), and a bare display name
    /// would report none of that. Zero is a plain first add, with nothing to repair.
    case success(String, refreshedCount: Int)
    /// Multiple orgs with no existing match — the user must pick one (pattern #6).
    case needsOrgChoice([Organization])
    /// Every org on the account is already stored (any N >= 2); the matched sessions were refreshed
    /// rather than a new account added (issue #32, KTD-3). Carries how many entries were repaired
    /// and whether the account currently being VIEWED was one of them. The second value exists
    /// because this route deliberately leaves a non-matching active account alone: a bare count
    /// there would be a false claim printed while the menu bar still shows the failure marker
    /// (R6, D6, issue #41).
    case alreadySignedInAllOrgs(refreshedCount: Int, activeAccountRefreshed: Bool)
    /// The paste did not contain a usable `sessionKey`.
    case invalidInput
    /// 401/403 from claude.ai. `suggestFullHeader` is true when only a bare key was pasted,
    /// so the likely cause is a missing HttpOnly `__cf_bm` (Cloudflare block).
    case authFailed(suggestFullHeader: Bool)
    case noOrganizations
    case accountLimitReached
    case connectionError
}

@MainActor
class AuthManager: NSObject, ObservableObject {
    @Published var loginState: LoginState = .idle {
        didSet { updateLoginOverlay(for: loginState) }
    }

    private let storage: StorageService
    // internal for @testable access in AuthManagerTests
    let accountStore: AccountStore
    private let session: any HTTPDataFetching
    // internal for @testable access in AuthManagerTests (webViewDidClose capture test)
    var loginWebView: WKWebView?
    private var loginWindowController: NSWindowController?
    private var loginTimeoutTask: Task<Void, Never>?
    private var orgDiscoveryTask: Task<Void, Never>?
    /// Stored continuation for the in-progress org-picker sheet, so a teardown can resume it
    /// (resume-once via `resumeOrgPicker`) instead of leaking the suspended `fetchOrganizationId`
    /// task when the window is closed out from under the open sheet.
    // internal for @testable access in AuthManagerTests (funnel has no other test seam)
    var orgPickerContinuation: CheckedContinuation<Organization?, Never>?
    private var cookieEnumerationTask: Task<Void, Never>?
    private var cookiePollTimer: Timer?
    private var urlObservation: NSKeyValueObservation?
    private var hasCapturedSession = false
    // internal for @testable access in AuthManagerTests
    var pendingSessionKey: String?
    /// Full Cookie header string built from every `.claude.ai` cookie in the login WebView.
    /// Passed to `ClaudeAPI` alongside `pendingSessionKey` so authenticated API calls during
    /// org discovery carry the full cookie set instead of `sessionKey` alone.
    // internal for @testable access in AuthManagerTests (the nil-header guard, KTD4/issue #41,
    // has no other seam: the real value is written by the WebView cookie-store read)
    var pendingCookieHeader: String?
    /// Context stashed between `manualSignIn` and `completeManualSignIn` when a paste resolves
    /// to multiple orgs and the user must pick one (U5, pattern #6).
    ///
    /// `orgs` is the decoded response the picker was built from. It is carried here rather than
    /// handed back through `completeManualSignIn`'s signature, because the completion is what
    /// writes credentials and view state must not be the authority on which entries get written
    /// (KTD5, issue #41). It is what lets the pick route repair the chosen org's stored siblings.
    private var pendingManualSignIn: (sessionKey: String, cookieHeader: String?, email: String, orgs: [Organization])?
    /// Child WebView hosting OAuth popups spawned by `window.open()`. Added as a subview of
    /// the primary `loginWebView` so the OAuth provider's callback can `postMessage` back to
    /// the claude.ai page via `window.opener`. Torn down on `webViewDidClose` or login-window
    /// shutdown. Required for "Continue with Google" - without it, `window.open()` returns nil
    /// and Google OAuth fails immediately.
    // internal for @testable access in AuthManagerTests (popup teardown test)
    var popupWebView: WKWebView?
    var onAuthSuccess: (() -> Void)?
    /// Hook the app wires to open Settings at the manual paste section (U5). Invoked by the
    /// sign-in error overlay's "Sign in manually" button so a stuck user reaches the floor.
    var onManualSignInRequested: (() -> Void)?
    /// Hook the app wires to show the one-line repair confirmation after a WebView sign-in (R6,
    /// issue #41). The manual paste path returns its confirmation in `ManualSignInResult` and
    /// Settings prints it inline; the WebView path returns nothing and closes its window on success,
    /// so the count has nowhere else to go. Left nil in tests, which assert the message instead of
    /// presenting it.
    var onSignInConfirmation: ((String) -> Void)?
    /// Pause and un-pause polling for the network windows of a manual sign-in (R11, issue #41).
    ///
    /// A narrow pair of callbacks rather than a reference to `UsageService`: this class has never
    /// held the polling service and does not need to start knowing what one is to say "not now"
    /// (KTD7). The app wires them where it wires `onAuthSuccess`. Left nil in tests that do not
    /// care, and recorded as a call sequence in the ones that do.
    ///
    /// They cover NETWORK WINDOWS ONLY, never user think-time (KTD8): the manual flow resumes when
    /// it hands off to the org picker, which waits on a person and can sit open indefinitely, and
    /// `completeManualSignIn` suspends again for its own writes.
    var onSuspendPolling: (() -> Void)?
    var onResumePolling: (() -> Void)?

    /// The overlay currently shown over the login WebView (U2).
    // internal for @testable access in AuthManagerTests
    private(set) var loginOverlayKind: LoginOverlayKind = .none
    private var loginOverlay: NSView?

    init(storage: StorageService, accountStore: AccountStore, session: any HTTPDataFetching = ClaudeAPI.session) {
        self.storage = storage
        self.accountStore = accountStore
        self.session = session
        super.init()
    }

    // MARK: - Login WebView configuration

    /// Build the login `WKWebViewConfiguration`: a non-persistent data store, the production
    /// WebAuthn/One-Tap shim (U4), and — only in DEBUG — the network-tracing instrumentation.
    // internal for @testable access in AuthManagerTests
    func makeLoginConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        // U4: ships in production (small, non-secret). Makes passkey/Google degrade instead of
        // hanging, without regressing password/federated credential flows.
        config.userContentController.addUserScript(
            WKUserScript(source: Self.credentialsShimSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )

        #if DEBUG
        // Debug-only network tracing — capture every fetch / XHR inside the login webview so we
        // can see which claude.ai request fails when a user reports "error logging you in".
        config.userContentController.addUserScript(
            WKUserScript(source: Self.netLogScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        config.userContentController.add(self, name: "claudebatteryNetLog")
        #endif

        return config
    }

    /// WebAuthn-only credentials shim + Google One Tap suppression (KTD-4). Ships in production.
    ///
    /// - Wraps `navigator.credentials.get/create` and rejects **only** when `options.publicKey`
    ///   is present (a WebAuthn request, #25), racing the real call against a short timeout so
    ///   claude.ai's passkey UI fails fast instead of spinning forever in an un-entitled WKWebView.
    ///   Password and federated credential requests pass through unchanged (no-regression invariant).
    /// - Forces `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable` to `false`.
    /// - Hides the auto-rendered Google One Tap iframe (#7) via injected CSS rather than a
    ///   MutationObserver — a subtree observer on claude.ai's SPA would be a CPU hot-loop (issue #11).
    /// - Posts a `webauthn-intercept` sentinel to the DEBUG netlog handler (a no-op in production,
    ///   where no handler is registered) so G1 can confirm the wrapper is the path claude.ai invokes.
    static let credentialsShimSource = """
    (function() {
        if (!navigator.credentials) { return; }
        var post = function(data) {
            try {
                var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.claudebatteryNetLog;
                if (h) { h.postMessage(JSON.stringify(data)); }
            } catch (e) {}
        };
        var TIMEOUT_MS = 3000;
        var rejectAfterTimeout = function() {
            return new Promise(function(_resolve, reject) {
                setTimeout(function() {
                    reject(new DOMException("WebAuthn is not available in this sign-in window.", "NotAllowedError"));
                }, TIMEOUT_MS);
            });
        };
        var origGet = navigator.credentials.get && navigator.credentials.get.bind(navigator.credentials);
        var origCreate = navigator.credentials.create && navigator.credentials.create.bind(navigator.credentials);
        if (origGet) {
            navigator.credentials.get = function(options) {
                if (options && options.publicKey) {
                    post({kind: 'webauthn-intercept', method: 'get'});
                    return Promise.race([origGet(options), rejectAfterTimeout()]);
                }
                return origGet(options);
            };
        }
        if (origCreate) {
            navigator.credentials.create = function(options) {
                if (options && options.publicKey) {
                    post({kind: 'webauthn-intercept', method: 'create'});
                    return Promise.race([origCreate(options), rejectAfterTimeout()]);
                }
                return origCreate(options);
            };
        }
        if (window.PublicKeyCredential) {
            window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function() {
                return Promise.resolve(false);
            };
            if (window.PublicKeyCredential.isConditionalMediationAvailable) {
                window.PublicKeyCredential.isConditionalMediationAvailable = function() {
                    return Promise.resolve(false);
                };
            }
        }
        try {
            var style = document.createElement('style');
            style.textContent = '#credential_picker_container, #credential_picker_iframe, iframe[src*="accounts.google.com/gsi"] { display: none !important; }';
            (document.head || document.documentElement).appendChild(style);
        } catch (e) {}
    })();
    """

    /// DEBUG-only network tracing script (relocated from `presentLogin`). Never ships in release.
    static let netLogScriptSource = """
    (function() {
        const post = (data) => {
            try {
                const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.claudebatteryNetLog;
                if (h) h.postMessage(JSON.stringify(data));
            } catch (e) {}
        };
        post({kind: 'script-injected', url: location.href});
        const origFetch = window.fetch;
        window.fetch = async function(input, init) {
            const url = typeof input === 'string' ? input : (input && input.url) || '';
            const method = (init && init.method) || (typeof input === 'object' && input.method) || 'GET';
            post({kind: 'fetch-start', url, method});
            try {
                const response = await origFetch(input, init);
                post({kind: 'fetch-done', url, method, status: response.status});
                return response;
            } catch (e) {
                post({kind: 'fetch-error', url, method, error: String(e)});
                throw e;
            }
        };
        const OrigXHR = window.XMLHttpRequest;
        window.XMLHttpRequest = function() {
            const xhr = new OrigXHR();
            const origOpen = xhr.open;
            xhr.open = function(method, url) {
                this._method = method; this._url = url;
                post({kind: 'xhr-open', method, url});
                return origOpen.apply(this, arguments);
            };
            xhr.addEventListener('loadend', function() {
                post({kind: 'xhr-done', method: xhr._method, url: xhr._url, status: xhr.status});
            });
            return xhr;
        };
        window.addEventListener('error', function(ev) {
            post({kind: 'js-error', message: String(ev.message), source: String(ev.filename || ''), lineno: ev.lineno || 0});
        });
        const origConsoleError = console.error;
        console.error = function() {
            try { post({kind: 'console-error', args: Array.from(arguments).map(a => String(a)).join(' ') }); } catch (e) {}
            return origConsoleError.apply(console, arguments);
        };
    })();
    """

    // MARK: - Login

    func presentLogin() {
        guard loginState != .signingIn else { return }

        guard loginWindowController == nil else {
            loginWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        loginState = .idle

        let config = makeLoginConfiguration()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        webView.customUserAgent = ClaudeAPI.safariUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
        self.loginWebView = webView

        config.websiteDataStore.httpCookieStore.add(self)
        config.websiteDataStore.httpCookieStore.getAllCookies { _ in }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.title = "Sign in to Claude"
        window.level = .floating
        window.center()
        window.delegate = self

        let controller = NSWindowController(window: window)
        self.loginWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // KVO: observe URL changes for SPA navigations that don't trigger didFinish
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.hasCapturedSession else { return }
                self.reReadCookieStore(webView)
            }
        }

        // Poll cookies every 0.2s — most reliable fallback for non-persistent store observer bugs.
        // Note (KTD-2): a faster poll only samples more often; it does not shrink the store's
        // sync latency. The load-bearing #17 fix is the webViewDidClose / KVO re-read.
        cookiePollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.hasCapturedSession, let webView = self.loginWebView else { return }
                self.reReadCookieStore(webView)
            }
        }

        // U3: arm a fallback timeout BEFORE the modal so a never-dismissed modal cannot wedge
        // the window open (the didFinish timeout cannot arm until the page actually loads).
        armLoginTimeout()

        // U3: steer the user to the email-code path before the page loads. The claude.ai login
        // page load is deferred until the user acknowledges the sheet.
        presentEmailCodeModal { [weak self] in
            guard let self, let webView = self.loginWebView,
                  let url = URL(string: "https://claude.ai/login") else { return }
            webView.load(URLRequest(url: url))
        }
    }

    /// Present the forced "use an email code" sheet on the login window (KTD-1), then run
    /// `onDismiss`. The sheet renders above the `.floating` login window and has exactly one
    /// button with no click-away dismissal, so the page load can be deferred safely until the
    /// user acknowledges. If there is no window to host it, `onDismiss` runs immediately.
    private func presentEmailCodeModal(then onDismiss: @escaping () -> Void) {
        guard let window = loginWindowController?.window else {
            onDismiss()
            return
        }
        Self.makeEmailCodeAlert().beginSheetModal(for: window) { _ in onDismiss() }
    }

    /// The forced email-code sheet's copy (KTD-1). Static + pure so the exact button title and
    /// guidance (including the manual-fallback pointer) are unit-testable and drift-protected.
    static func makeEmailCodeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Sign in with an email code"
        alert.informativeText = "To sign in, choose \"Continue with email\" and enter the code Claude sends you. Google and passkey sign-in aren't available in this sign-in window. If you get stuck, you can sign in manually under Settings."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Ok, I'll login with email code")
        return alert
    }

    /// Arm (or re-arm) the 10-minute inactivity timeout that tears down the login window.
    /// Armed before the U3 modal so an un-dismissed modal cannot wedge the window, and re-armed
    /// on every `didFinish` so an actively-signing-in user is never timed out mid-flow.
    private func armLoginTimeout() {
        loginTimeoutTask?.cancel()
        loginTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.orgDiscoveryTask?.cancel()
            self.orgDiscoveryTask = nil
            self.loginState = .idle
            self.hasCapturedSession = false
            self.pendingSessionKey = nil
            self.pendingCookieHeader = nil
            self.stopLoginWindow()
        }
    }

    /// Re-read the WKHTTPCookieStore and capture the `sessionKey` if it has appeared.
    ///
    /// Called from every capture trigger: the cookie observer, the poll timer, KVO `url`
    /// changes, `didFinish`, and (the load-bearing #17 path) `webViewDidClose`. The former
    /// JS `document.cookie` fallback was deleted: `sessionKey` is HttpOnly, so `document.cookie`
    /// can never see it — it was dead code that could only ever capture via the store
    /// enumeration below.
    ///
    /// `lastPolledCookieNames` dedupes the 0.2s poll: a `cookie-store-poll` line is emitted only
    /// when the cookie set changes (REL-03), so a stalled login does not drive a per-line fsync
    /// storm. Capture still runs every tick.
    private var lastPolledCookieNames: String?

    private func reReadCookieStore(_ webView: WKWebView) {
        guard !hasCapturedSession else { return }

        Task { @MainActor [weak self] in
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            // Re-validate liveness AFTER the await: the login may have been torn down while the
            // store read was in flight. stopLoginWindow nils loginWebView, so a non-nil value is
            // the "login still active" signal; without this, a read that resolves post-teardown
            // would silently complete sign-in for a login the user already abandoned.
            guard let self, !self.hasCapturedSession, self.loginWebView != nil else { return }

            // U6 diagnostics: cookie NAMES + domains only, never `.value`. Runtime-gated by the
            // logger; the call compiles unconditionally (no `#if DEBUG` at the call site).
            let names = cookies.map { "\($0.name)=\($0.domain)" }.joined(separator: ", ")
            #if DEBUG
            logger.debug("Cookie store poll — \(cookies.count) cookies: \(names)")
            #endif
            // REL-03: emit only when the cookie set changes (the poll fires every 0.2s).
            if names != lastPolledCookieNames {
                lastPolledCookieNames = names
                // DI-04: emit name+domain as STRUCTURED pairs, not a `name=domain` string. The
                // string form is key=value shaped, so the redactor rewrites the domain of
                // credential-named cookies (sessionKey=.claude.ai -> sessionKey=REDACTED_LEN_n);
                // structured pairs keep the domain as diagnostic signal. The cookie VALUE is never read.
                let cookiePairs = cookies.map { ["name": $0.name, "domain": $0.domain] }
                DiagnosticsLogger.shared.emitMilestone(kind: "cookie-store-poll", payload: [
                    "count": cookies.count,
                    "names": cookiePairs
                ])
            }

            self.captureSessionCookie(from: cookies)
        }
    }

    /// Single capture funnel. Every path that observes cookies (store poll, KVO, navigation
    /// response, popup close) routes its cookie set through here so the `hasCapturedSession`
    /// guard (critical pattern #3) enforces exactly-once capture regardless of which trigger
    /// fires first. Per pattern #5, only the cookie value is read downstream — no store
    /// metadata (e.g. `expiresDate`) is trusted.
    // internal for @testable access in AuthManagerTests
    func captureSessionCookie(from cookies: [HTTPCookie]) {
        // `!loginState.isError`: a cancelled/failed login leaves the 0.2s poll timer armed and the
        // session cookie live in the non-persistent store; without this gate the next tick would
        // re-capture and re-launch org discovery, silently undoing the user's Cancel and overwriting
        // every discovery-failure error card with a spinner. retryLogin clears .error -> .idle first,
        // so the user-initiated retry path still captures.
        guard !hasCapturedSession, !loginState.isError else { return }
        guard let sessionCookie = cookies.first(where: Self.isSessionCookie) else { return }
        handleCookieCaptured(sessionCookie)
    }

    // internal for @testable access in AuthManagerTests (verifies teardown resumes a suspended picker)
    func stopLoginWindow() {
        removeLoginOverlay()
        // Release a suspended org-picker await (if any) so teardown never leaks the awaiting task;
        // resume-once makes this a no-op when the sheet's own handler already resumed.
        resumeOrgPicker(with: nil)
        loginTimeoutTask?.cancel()
        loginTimeoutTask = nil
        cookieEnumerationTask?.cancel()
        cookieEnumerationTask = nil
        orgDiscoveryTask?.cancel()
        orgDiscoveryTask = nil
        cookiePollTimer?.invalidate()
        cookiePollTimer = nil
        urlObservation?.invalidate()
        urlObservation = nil
        popupWebView?.stopLoading()
        popupWebView?.removeFromSuperview()
        popupWebView = nil
        loginWebView?.stopLoading()
        loginWebView?.configuration.websiteDataStore.httpCookieStore.remove(self)
        #if DEBUG
        loginWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "claudebatteryNetLog")
        #endif
        loginWebView = nil
        loginWindowController?.close()
        loginWindowController = nil
    }

    // MARK: - Login Overlay (U2)

    /// Drive the overlay from the login-state machine (called by `loginState.didSet`):
    /// `.signingIn` shows "Finishing sign-in…", `.error` swaps to a recoverable error card,
    /// `.idle` clears it. No-ops when there is no login WebView to host the overlay.
    private func updateLoginOverlay(for state: LoginState) {
        // U6 diagnostics: single chokepoint for every loginState transition. The state name
        // (and the user-facing `.error` message) carry no secret/email/sessionKey value.
        let stateName: String
        switch state {
        case .idle: stateName = "idle"
        case .signingIn: stateName = "signingIn"
        case .error(let message): stateName = "error: \(message)"
        }
        DiagnosticsLogger.shared.emitMilestone(kind: "login-state", payload: ["state": stateName])

        switch state {
        case .signingIn:
            showSigningInOverlay()
        case .error(let message):
            showLoginOverlayError(message)
        case .idle:
            removeLoginOverlay()
        }
    }

    // internal for @testable access in AuthManagerTests
    func showSigningInOverlay() {
        guard let host = loginWebView else { return }
        attachOverlay(Self.makeSigningInOverlay(), to: host)
        loginOverlayKind = .signingIn
    }

    // internal for @testable access in AuthManagerTests
    func showLoginOverlayError(_ message: String) {
        guard let host = loginWebView else { return }
        attachOverlay(makeErrorOverlay(message: message), to: host)
        loginOverlayKind = .error
    }

    // internal for @testable access in AuthManagerTests
    func removeLoginOverlay() {
        loginOverlay?.removeFromSuperview()
        loginOverlay = nil
        loginOverlayKind = .none
    }

    /// Swap in `overlay` as the single overlay subview filling `host`, replacing any prior one.
    private func attachOverlay(_ overlay: NSView, to host: NSView) {
        loginOverlay?.removeFromSuperview()
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay)
        loginOverlay = overlay
    }

    /// The "Finishing sign-in…" overlay: a blurred panel with a spinner and label. Pure (no
    /// `self` capture) so it is unit-testable in isolation. VoiceOver reads "Finishing sign-in".
    /// Identifier on the overlay container so teardown and tests can find the mounted overlay.
    static let loginOverlayIdentifier = NSUserInterfaceItemIdentifier("ClaudeBatteryLoginOverlay")

    static func makeSigningInOverlay() -> NSView {
        let container = NSVisualEffectView()
        container.identifier = loginOverlayIdentifier
        container.material = .hudWindow
        container.blendingMode = .withinWindow
        container.state = .active
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel("Finishing sign-in")

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        spinner.setAccessibilityLabel("Finishing sign-in")

        let label = NSTextField(labelWithString: "Finishing sign-in…")
        label.font = .preferredFont(forTextStyle: .title3) // scales with Dynamic Type (was fixed 15pt)
        label.alignment = .center

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// The recoverable error overlay shown when org discovery fails: a message plus
    /// "Try again" (reload the login flow) and "Sign in manually" (jump to the paste floor).
    private func makeErrorOverlay(message: String) -> NSView {
        let container = NSVisualEffectView()
        container.identifier = Self.loginOverlayIdentifier
        container.material = .hudWindow
        container.blendingMode = .withinWindow
        container.state = .active
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel("Sign-in problem")

        let title = NSTextField(labelWithString: "Couldn’t finish sign-in")
        title.font = .preferredFont(forTextStyle: .title3) // scales with Dynamic Type (was fixed 15pt)
        title.alignment = .center

        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .preferredFont(forTextStyle: .callout) // scales with Dynamic Type (was fixed 12pt)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 320

        let retry = NSButton(title: "Try again", target: self, action: #selector(overlayRetryTapped))
        retry.bezelStyle = .rounded
        retry.keyEquivalent = "\r"

        let manual = NSButton(title: "Sign in manually", target: self, action: #selector(overlayManualTapped))
        manual.bezelStyle = .rounded

        let buttons = NSStackView(views: [retry, manual])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [title, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        return container
    }

    // internal for @testable access in AuthManagerTests (error-overlay affordance tests)
    @objc func overlayRetryTapped() {
        retryLogin()
    }

    // internal for @testable access in AuthManagerTests (error-overlay affordance tests)
    @objc func overlayManualTapped() {
        onManualSignInRequested?()
        loginState = .idle
        stopLoginWindow()
    }

    /// Reset capture state and reload claude.ai/login in the existing login WebView.
    // internal for @testable access in AuthManagerTests
    func retryLogin() {
        hasCapturedSession = false
        pendingSessionKey = nil
        pendingCookieHeader = nil
        removeLoginOverlay()
        loginState = .idle
        // Restart the inactivity clock the moment the user chooses to retry, rather than only
        // after the reload reaches didFinish — otherwise a stale near-expiry timeout from the
        // prior load could tear the window down mid-retry. (The 0.2s poll backstop is still
        // armed; it was not invalidated on the prior capture.)
        armLoginTimeout()
        if let url = URL(string: "https://claude.ai/login") {
            loginWebView?.load(URLRequest(url: url))
        }
    }

    // internal for @testable access in AuthManagerTests
    static func isSessionCookie(_ cookie: HTTPCookie) -> Bool {
        cookie.name == "sessionKey" &&
        (cookie.domain == "claude.ai" || cookie.domain == ".claude.ai")
    }

    /// Any cookie scoped to claude.ai (exact or leading-dot only).
    /// Used when building the full Cookie header after capture.
    /// Per Critical Pattern #2: never use hasSuffix for domain validation -
    /// hasSuffix(".claude.ai") would match evil-claude.ai.
    static func isClaudeCookie(_ cookie: HTTPCookie) -> Bool {
        cookie.domain == "claude.ai" || cookie.domain == ".claude.ai"
    }

    /// Parse Set-Cookie headers from a navigation response into cookies whose declared `Domain=`
    /// actually belongs to the response `url` host. Foundation's `HTTPCookie.cookies(...)` honors
    /// a `Domain=` attribute regardless of the response origin, so without this pinning an
    /// allowlisted third-party response could inject a `Domain=.claude.ai` cookie (session
    /// fixation, critical pattern #2). Static + pure for unit testing.
    static func sessionCookies(fromResponseHeaders headers: [AnyHashable: Any], url: URL) -> [HTTPCookie] {
        guard let host = url.host else { return [] }
        var headerFields: [String: String] = [:]
        for (key, value) in headers {
            if let key = key as? String, let value = value as? String {
                headerFields[key] = value
            }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
            .filter { cookieDomainMatchesHost($0.domain, host: host) }
    }

    /// True when a cookie may legitimately carry `cookieDomain` on a response from `host`:
    /// an exact match, or a leading-dot parent domain of the host. Exact-label only - never a
    /// substring (pattern #2): `evil-claude.ai` must not match `.claude.ai`.
    static func cookieDomainMatchesHost(_ cookieDomain: String, host: String) -> Bool {
        let normalized = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        guard !normalized.isEmpty else { return false }
        return host == normalized || host.hasSuffix("." + normalized)
    }

    // internal for @testable access in AuthManagerTests
    func handleCookieCaptured(_ cookie: HTTPCookie) {
        guard !hasCapturedSession else { return }

        guard Self.isSessionCookie(cookie),
              cookie.isSecure,
              cookie.path == "/" else {
            logger.debug("Cookie rejected — name=\(cookie.name) domain=\(cookie.domain)")
            // U6 diagnostics: rejected cookie NAME + domain only, never `.value`.
            DiagnosticsLogger.shared.emitMilestone(kind: "cookie-rejected", payload: [
                "name": cookie.name,
                "domain": cookie.domain
            ])
            return
        }

        hasCapturedSession = true
        pendingSessionKey = cookie.value
        loginState = .signingIn
        // U6 diagnostics: the single capture-funnel success point. Records that capture fired
        // and the cookie domain (non-secret); never the `sessionKey` value.
        DiagnosticsLogger.shared.emitMilestone(kind: "session-cookie-captured", payload: [
            "domain": cookie.domain,
            "isSecure": cookie.isSecure
        ])
        // Deliberately do NOT invalidate cookiePollTimer here. The poll closure already
        // guards on `hasCapturedSession`, so it no-ops while a capture is in flight, and it
        // is torn down in stopLoginWindow. Leaving it armed means that if org discovery fails
        // (handleOrgDiscoveryFailure resets hasCapturedSession) or the user taps "Try again",
        // the 0.2s store-poll backstop resumes automatically without being re-created.

        logger.info("Session cookie captured via cookie store")

        // Enumerate every `.claude.ai` cookie into a Cookie header string so authenticated
        // API requests carry the full set (including Cloudflare `__cf_bm`) - not `sessionKey`
        // alone. Then kick off org discovery.
        // Capture loginWebView before the first await so a concurrent stopLoginWindow call
        // that nils the property does not cause us to skip cookie enumeration (COR-002).
        let capturedWebView = self.loginWebView
        cookieEnumerationTask = Task { [weak self] in
            guard let self else { return }
            if let webView = capturedWebView {
                let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                guard !Task.isCancelled else { return }
                let claudeCookies = allCookies.filter(Self.isClaudeCookie)
                let header = claudeCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                self.pendingCookieHeader = header.isEmpty ? nil : header
                logger.info("Captured \(claudeCookies.count) .claude.ai cookies for API requests")
            }
            guard !Task.isCancelled else { return }
            self.orgDiscoveryTask = Task { await self.fetchOrganizationId() }
        }
    }

    // MARK: - Org Discovery

    /// Pure org-selection rule (pattern #6: never blindly take orgs[0]) shared by the WebView and
    /// manual-paste sign-in paths. Single org -> take it; a multi-org account with at least one
    /// un-added org -> the caller shows a picker (so a second org of the same account is reachable,
    /// issue #32); a multi-org account where every org is already stored -> the caller refreshes
    /// the matched session and reports it. There is deliberately NO silent auto-match: the same
    /// paste is used both to refresh an existing org and to add a different org of the same account,
    /// so when an addable org exists the user must choose. Unit-tested in isolation; each call site
    /// supplies its own side-effect shell (NSAlert vs ManualSignInResult).
    enum OrgSelection {
        case single(Organization)
        case needsChoice([Organization])
        /// Every org on the account is already stored — refresh, do not add (KTD-3).
        case allAlreadyAdded([Organization])
    }

    // `nonisolated`: a pure rule over value types, so it needs no main-actor isolation and can be
    // unit-tested (and called from any context) directly.
    nonisolated static func selectOrg(orgs: [Organization], accounts: [Account]) -> OrgSelection {
        if orgs.count == 1 {
            return .single(orgs[0])
        }
        let unadded = orgs.filter { org in !accounts.contains(where: { $0.organizationId == org.uuid }) }
        if unadded.isEmpty {
            return .allAlreadyAdded(orgs)
        }
        return .needsChoice(orgs)
    }

    /// The stored account to refresh when every org is already added (`.allAlreadyAdded`): the
    /// active account when its org is in the list, else the first stored match. Active-preference
    /// is mandatory, not cosmetic — `AccountStore.updateSessionKey` re-primes the shared cookie jar
    /// only for the active account, so refreshing a non-active sibling while the active account's
    /// org is present would leave the live session unrefreshed (KTD-3).
    func matchedAccount(in orgs: [Organization]) -> Account? {
        if let active = accountStore.activeAccount,
           orgs.contains(where: { $0.uuid == active.organizationId }) {
            return active
        }
        return accountStore.accounts.first { acct in orgs.contains { $0.uuid == acct.organizationId } }
    }

    /// Every stored account whose org appears in `orgs`, in stored order. This is the set of entries
    /// one successful sign-in repairs: the credentials enumerate every org on the account, so they
    /// are good for every stored entry among them, not only the one being viewed (R1, issue #41).
    /// Shared by all three repair routes so the rule lives in one testable place.
    ///
    /// Deliberately NOT derived from `matchedAccount`, and do NOT "simplify" the callers to use the
    /// first refreshed entry instead. The callers gate the jar restore and the success callback on
    /// whether the ACTIVE entry was refreshed. Today that is equivalent to `matched.id ==
    /// activeAccountId`, but only because `matchedAccount` prefers the active account when its org
    /// is listed - an invariant that lives in a different function and that no test fails on if it
    /// stops holding. Keying the gate on the ids this function returns removes that hidden
    /// dependence (KTD1). `matchedAccount` stays as it is, because the WebView path still has to
    /// pick ONE entry to switch to, under the active-preference rule issue #32 recorded as
    /// mandatory.
    ///
    /// A repeated org uuid in `orgs` cannot yield a duplicate entry: the walk is over `accounts`.
    ///
    /// `nonisolated`: a pure rule over value types, same as `selectOrg`, so it is unit-testable
    /// without an `AuthManager` and callable from any context.
    nonisolated static func matchedAccounts(orgs: [Organization], accounts: [Account]) -> [Account] {
        let orgIds = Set(orgs.map(\.uuid))
        return accounts.filter { orgIds.contains($0.organizationId) }
    }

    /// Copy the plan fields off the freshly fetched org onto a stored entry. Every repair route
    /// calls this next to its `updateSessionKey`, because a sign-in is the only moment the app sees
    /// the organizations response, and a user who upgraded or downgraded since the last one would
    /// otherwise keep the old plan until they removed and re-added the account (R4).
    ///
    /// Does nothing when the entry's org is not in `orgs`. That cannot happen on the routes calling
    /// it - all of them walk `matchedAccounts`, whose entries are listed by definition - but it is
    /// the right answer if that ever stops holding: no org in hand is no evidence of a plan, and
    /// writing one anyway is the class of guess this whole change exists to remove.
    private func refreshStoredPlan(for account: Account, from orgs: [Organization]) {
        guard let org = orgs.first(where: { $0.uuid == account.organizationId }) else { return }
        accountStore.updatePlan(account.id, rateLimitTier: org.rateLimitTier,
                                capabilities: org.capabilities, billingType: org.billingType)
    }

    /// The one-line confirmation for a sign-in that repaired stored entries (R6, issue #41). Shared
    /// by all three repair routes - the manual all-already-stored branch, the manual picker, and the
    /// WebView sign-in - so one event cannot end up described three different ways.
    ///
    /// `viewedAccountRepaired` is false only on the manual branch that deliberately leaves the
    /// account being viewed untouched (D6). A bare count there would be a false claim printed while
    /// the menu bar still shows the failure marker, so that message says so and names the next step
    /// rather than stopping at a number the user cannot act on.
    ///
    /// `nonisolated`: pure string building over value types, unit-testable without an `AuthManager`,
    /// the same shape as `selectOrg` and `matchedAccounts`.
    nonisolated static func repairConfirmation(refreshedCount: Int, viewedAccountRepaired: Bool) -> String {
        // Spelled out rather than interpolated, because one repaired entry reading
        // "1 organizations" is the exact defect this branch exists to prevent.
        let orgs = refreshedCount == 1 ? "1 organization" : "\(refreshedCount) organizations"
        if viewedAccountRepaired {
            return "Refreshed \(orgs)."
        }
        return "Refreshed \(orgs), but not the one you're viewing - switch to a refreshed one, or paste that account's cookie header."
    }

    /// The paste box's status line for a completed sign-in (R6, issue #41). A count of zero is a
    /// first add of an org the app had never stored, which repaired nothing and keeps the plain
    /// sentence the paste box always showed.
    ///
    /// Here rather than inline in `SettingsView.apply` because the view has no test that can reach
    /// it: dropping the repair half of the sentence would put the picker route back to confirming
    /// "Signed in as X" while silently having rescued the user's other orgs, and the tests that
    /// claimed to cover the sentence were rebuilding it themselves, so they would still have passed
    /// (review finding). Same convention as `UsagePopoverView.batteryColor` - the view keeps the
    /// rendering, the pure value it renders is testable on its own.
    ///
    /// `viewedAccountRepaired` is not a parameter: every `.success` route ends in `switchTo` on the
    /// entry the pasted credentials just wrote, so the account being viewed afterwards is always one
    /// of the repaired. D6's branch belongs to `.alreadySignedInAllOrgs`, which calls
    /// `repairConfirmation` directly with the value the auth layer computed.
    nonisolated static func signInConfirmation(name: String, refreshedCount: Int) -> String {
        guard refreshedCount > 0 else { return "Signed in as \(name)." }
        return "Signed in as \(name). " + repairConfirmation(refreshedCount: refreshedCount,
                                                             viewedAccountRepaired: true)
    }

    /// Report a WebView sign-in's repair count to the app so it can show it (R6, issue #41).
    ///
    /// Fires only when the sign-in wrote fresh credentials to a stored entry OTHER than the org the
    /// user signed in to. This route has no inline status line the way the manual paste section does,
    /// so the app wires this to a one-line alert, and a modal for every ordinary single-org re-auth
    /// would charge a click for news the user does not have. The manual path states the count even at
    /// one, because writing another line into a status field it was already writing costs nothing.
    ///
    /// The gate takes the sibling count rather than the total because the three call sites arrive
    /// with the org signed in to counted differently: the picker's add route stored it new, the other
    /// two repaired it. A single `refreshedCount >= 2` therefore meant "at least one sibling" on two
    /// routes and "at least two siblings" on the third, so a browser sign-in that added an org and
    /// rescued exactly one stored sibling said nothing at all, while the manual paste box reported
    /// the same event (P3, review finding). Splitting the two quantities leaves one threshold over
    /// one meaning, which cannot drift apart again.
    ///
    /// The number shown is the siblings plus the org signed in to when that org was itself a repair -
    /// the same arithmetic `completeManualSignIn` does with `pickedOrgWasStored`, so one event cannot
    /// be counted two ways on the two paths.
    ///
    /// `viewedAccountRepaired` is always true here: every success route on this path ends in
    /// `switchTo`, so the account being viewed afterwards holds credentials this sign-in just wrote,
    /// repaired on two routes and newly added on the third. D6's branch is for an entry the sign-in
    /// deliberately left stale, which cannot arise here.
    private func reportWebViewRepair(siblingsRepaired: Int, signedInOrgRepaired: Bool) {
        guard siblingsRepaired >= 1 else { return }
        let refreshedCount = siblingsRepaired + (signedInOrgRepaired ? 1 : 0)
        onSignInConfirmation?(Self.repairConfirmation(refreshedCount: refreshedCount, viewedAccountRepaired: true))
    }

    /// Put the active account's cookies back in the shared jar (R5, R10, issue #41).
    ///
    /// `ClaudeAPI.activateCookies` mutates the SHARED jar that `UsageService.pollUsage` reads, so
    /// every non-success outcome of a sign-in has to put the active account's cookies back. Without
    /// this, a failed attempt to ADD a new account would clobber the working account's cookies and
    /// its next poll would 401 - silently breaking a healthy account (P1, review finding).
    ///
    /// Read the store AT restore time rather than snapshotting before the network call (R10, KTD6,
    /// issue #41). Account is a struct, so a pre-network capture is a frozen copy: if the user
    /// switches accounts or removes one while the sign-in is still waiting on the network, putting
    /// that copy back writes the old account's cookies over whichever account is active now - the
    /// same healthy-account breakage this helper exists to prevent, just aimed at a different
    /// account. A nil read means the entry that was active has been removed with nothing left to
    /// fall back to, so the jar is cleared rather than re-primed from a deleted account.
    ///
    /// One method on `AuthManager` rather than a helper nested in each sign-in function: it started
    /// nested inside `discoverAndAddManualAccount`, and the browser path was later found to need the
    /// identical restore (P1, review finding). Two copies of a rule this sharp drift.
    private func restoreActiveJar() {
        if let active = accountStore.activeAccount {
            ClaudeAPI.activateCookies(sessionKey: active.sessionKey, cookieHeader: active.allCookieHeader)
        } else {
            ClaudeAPI.clearClaudeCookies()
        }
    }

    // internal for @testable access in AuthManagerTests
    func fetchOrganizationId() async {
        guard let sessionKey = pendingSessionKey else {
            loginState = .idle
            stopLoginWindow()
            return
        }

        // Pause polling for this sign-in's network window (R11, KTD8, issue #41), immediately before
        // the first jar prime and never after it. `ClaudeAPI.makeRequest` below rewrites the SHARED
        // jar that `UsageService.pollUsage` reads, and URLSession writes a request's Cookie header
        // when the request goes out rather than when it was created - so a poll already in flight
        // can be answered with the signing-in account's credentials. That answer is a 403, which
        // marks a healthy account expired and stops polling, and the failure routes below fire no
        // success callback, so nothing would start it again.
        //
        // Declared BEFORE the jar-restore `defer` below so it runs AFTER it: defers unwind in
        // reverse order, and resuming into a jar that still held the abandoned sign-in's cookies
        // would hand the very poll this pause protects the wrong credentials.
        //
        // On the success routes this resume is a no-op rather than a second poll: they fire
        // `onAuthSuccess` synchronously, which reaches `UsageService.restartPolling` and clears the
        // suspend bookkeeping, so `resumePolling` returns at its own guard.
        onSuspendPolling?()
        defer { onResumePolling?() }

        guard let request = ClaudeAPI.makeRequest(path: "/api/organizations", sessionKey: sessionKey, cookieHeader: pendingCookieHeader) else {
            logger.error("Failed to construct organizations API URL")
            handleOrgDiscoveryFailure("Connection error. Please try again.")
            return
        }

        // The request above has now primed the shared jar with the login window's cookies, so every
        // failure and every cancellation exit below would otherwise return leaving a half-signed-in
        // account's cookies live for the active account's next poll (P1, review finding; the same
        // defect class `restoreActiveJar` was added to the manual path for).
        //
        // A `defer` here rather than a call inside `handleOrgDiscoveryFailure`: the
        // `guard !Task.isCancelled` returns below are how the 10-minute login timeout and the
        // window-close teardown leave this function, and they never reach that handler.
        //
        // `endedOnFreshCredentials` keeps it off the success routes, which deliberately end in
        // `switchTo` having primed the jar with the credentials just written - a restore there would
        // fight the switch and would throw away any Cloudflare rotation the response put in the jar.
        // `jarPrimed` keeps it off the KTD4 nil-header refusal, which never primed the jar. Both
        // read before the branches below, because the failure handler clears `pendingCookieHeader`.
        let jarPrimed = !(pendingCookieHeader ?? "").isEmpty
        var endedOnFreshCredentials = false
        defer { if jarPrimed && !endedOnFreshCredentials { restoreActiveJar() } }

        do {
            let (data, response) = try await session.data(for: request)

            guard !Task.isCancelled else { return }

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Non-HTTP response from organizations API")
                handleOrgDiscoveryFailure("Connection error. Please try again.")
                return
            }

            logger.info("Org discovery HTTP \(httpResponse.statusCode)")
            // U6 diagnostics: HTTP status code only — never the response body (which carries
            // email/org data and stays behind the `#if DEBUG` guards below).
            DiagnosticsLogger.shared.emitMilestone(kind: "org-discovery-status", payload: [
                "status": httpResponse.statusCode,
                "path": "webview"
            ])

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                #if DEBUG
                let body = String(data: data, encoding: .utf8) ?? "(non-utf8)"
                logger.warning("Auth failure during org discovery (HTTP \(httpResponse.statusCode)): \(body.prefix(500))")
                #endif
                handleOrgDiscoveryFailure("Sign-in failed. Please try again.")
                return
            }

            #if DEBUG
            let rawBody = String(data: data, encoding: .utf8) ?? "(non-utf8)"
            logger.debug("Org discovery response: \(rawBody.prefix(1000))")
            #endif

            let orgs = try JSONDecoder().decode([Organization].self, from: data)

            guard !Task.isCancelled else { return }

            if orgs.isEmpty {
                logger.info("No organizations found — user may not have Pro/Max subscription")
                handleOrgDiscoveryFailure("No Claude organizations were found for this account. A Pro or Max plan may be required.")
                return
            }

            // Refuse to write anything when the login WebView produced no cookie header (KTD4,
            // issue #41). A nil header means the request above carried no cookies of its own, so it
            // was authenticated by whatever is already in the SHARED jar - the previously active
            // account's cookies. The response then describes THAT account, every org of which is
            // stored, so the flow would reach a repair route and repoint all of the old account's
            // entries at the new key. The guard sits here, before the org-selection switch, so one
            // check covers all three routes out of it (all-already-stored, the picker, and the
            // single-org add); inside any one branch it would leave the other two open. Empty is
            // treated as absent for the same reason it is at the capture site and in
            // `AccountStore.updateSessionKey`: both mean no header was captured.
            guard let capturedCookieHeader = pendingCookieHeader, !capturedCookieHeader.isEmpty else {
                logger.error("Org discovery finished with no captured cookie header - refusing to write credentials")
                handleOrgDiscoveryFailure("Sign-in could not be completed. Please try again.")
                return
            }

            // The real address to label accounts with (R7). Resolved HERE, above the org-selection
            // switch, rather than at the add site below: the all-already-stored branch returns
            // without ever reaching that line, and that branch is exactly where an existing user's
            // placeholder gets repaired. One extra request per sign-in, never on the poll (KTD7).
            let resolvedEmail = await resolveEmail(sessionKey: sessionKey, orgs: orgs, rawData: data)
            // Another suspension point, so another cancellation check before anything is written:
            // the login timeout and the window-close teardown both cancel this task, and a write
            // past either of them is a write on behalf of a sign-in the user has already left.
            guard !Task.isCancelled else { return }

            // Determine which org to use via the pure, unit-tested `Self.selectOrg` (shared with
            // the manual-paste path). This site supplies the imperative shell: the NSAlert picker
            // and the login-window state machine.
            let chosenOrg: Organization
            switch Self.selectOrg(orgs: orgs, accounts: accountStore.accounts) {
            case .single(let org):
                chosenOrg = org
            case .allAlreadyAdded:
                // Every org on this account is already stored. This is a foreground sign-in the
                // user just completed, so refresh EVERY stored entry these credentials list, not
                // only the one being viewed (R1, issue #41), and switch to the matched one (KTD-3
                // WebView branch - unlike the manual path, which repairs without switching,
                // switching is expected here; that divergence is deliberate and R3 keeps it). Log
                // the non-PII account id only; displayName/org name can carry PII in off-device logs.
                //
                // `matchedAccount` is kept, and it chooses the SWITCH TARGET only. It prefers the
                // active account when its org is listed, which is the active-preference rule issue
                // #32 recorded as mandatory. Do NOT replace it with the loop's first entry: that is
                // stored order, so it would switch to whichever org happens to sit first (KTD1).
                guard let matched = matchedAccount(in: orgs) else {
                    handleOrgDiscoveryFailure("Account limit reached.")
                    return
                }
                // Accepted limit (D7): an entry is keyed only by org and labelled with whoever added
                // it first, and there is deliberately no owner check here - see the
                // all-orgs-already-stored branch in discoverAndAddManualAccount for why the stored
                // email cannot serve as one.
                var refreshedIds: Set<UUID> = []
                for account in Self.matchedAccounts(orgs: orgs, accounts: accountStore.accounts) {
                    accountStore.updateSessionKey(account.id, sessionKey, cookieHeader: capturedCookieHeader)
                    refreshStoredPlan(for: account, from: orgs)
                    // This is the route an existing user takes: their orgs are all stored already,
                    // so the add path below never runs and a placeholder label would survive every
                    // future sign-in without this (R7).
                    repairPlaceholderEmail(for: account, with: resolvedEmail)
                    refreshedIds.insert(account.id)
                }
                // `switchTo` stays the last jar-touching step (KTD3): every write above put the same
                // fresh credentials in, so the jar ends up holding `matched`'s copy of them.
                accountStore.switchTo(matched.id)
                // Past the switch the jar holds credentials this sign-in just wrote, so the restore
                // installed above must not fire on the way out (it would fight the switch).
                endedOnFreshCredentials = true
                // The manual path gates its success callback and its jar restore on whether the
                // ACTIVE entry was among those repaired (KTD1). That gate collapses here rather than
                // being dropped: `switchTo` has just made `matched` active, and `matched` is always a
                // member of `refreshedIds` because `matchedAccount` returns an entry whose org is in
                // `orgs`, which is exactly what `matchedAccounts` filters on. So there is no branch
                // to take, and this is a route the jar restore must stay off, which is what the flag
                // set above does.
                logger.info("Re-auth: all orgs already added, refreshed \(refreshedIds.count) account(s), active is \(matched.id.uuidString)")
                pendingSessionKey = nil
                pendingCookieHeader = nil
                loginState = .idle
                stopLoginWindow()
                // Say how many were repaired (R6). Reported after stopLoginWindow so the message is
                // about a finished sign-in rather than arriving over the login window. `matched` is
                // always a member of `refreshedIds` (see just above), so the org signed in to was
                // itself repaired and the rest of the set are its siblings.
                reportWebViewRepair(siblingsRepaired: refreshedIds.count - 1, signedInOrgRepaired: true)
                onAuthSuccess?()
                return
            case .needsChoice(let choices):
                // Hand the jar and polling back before waiting on a person (KTD8, R5, issue #41).
                // This picker is an NSAlert sheet that can sit open until the 10-minute login
                // timeout, and `beginSheetModal` does not block the run loop, so the poll timer
                // keeps firing: a pause held across it is exactly the think-time pause KTD8 rules
                // out. The jar goes back FIRST, because resuming polling while the jar still held
                // the signing-in account's cookies would be worse than not resuming at all. Same
                // order and same reason as the manual path, which restores before returning
                // `.needsOrgChoice`. The KTD4 guard above means the jar has been primed by here.
                restoreActiveJar()
                onResumePolling?()
                let picked = await showOrgPicker(orgs: choices)
                // Second window, matching `completeManualSignIn`: the writes below re-point the
                // shared jar (`addOrReactivateWebViewAccount` ends in `switchTo`), so they are
                // paused too. Above the cancellation and cancel-button guards so every route out of
                // the picker is balanced by the resume on the way out.
                onSuspendPolling?()
                // If teardown (timeout / window close) resumed the picker with nil, orgDiscoveryTask
                // is already cancelled — do not fight the teardown by re-driving login state.
                guard !Task.isCancelled else { return }
                guard let picked else {
                    // User cancelled the picker
                    handleOrgDiscoveryFailure("Sign-in cancelled.")
                    return
                }
                chosenOrg = picked
            }

            guard !Task.isCancelled else { return }

            // Positional placeholder only when neither `/api/account` nor the org body produced an
            // address (R7). It is the label the user sees, so it is also what the repair routes test
            // against - see `isPlaceholderEmail`.
            let email = resolvedEmail ?? "Account \(accountStore.accounts.count + 1)"

            guard addOrReactivateWebViewAccount(org: chosenOrg, orgs: orgs, sessionKey: sessionKey,
                                                cookieHeader: capturedCookieHeader, email: email) else {
                handleOrgDiscoveryFailure("Account limit reached.")
                return
            }
            // Same as the all-already-stored route: this ended in `switchTo`, so the jar already
            // holds the credentials just written and the restore must not fire on the way out.
            endedOnFreshCredentials = true

            // Success — clean up, close window, and notify
            pendingSessionKey = nil
            pendingCookieHeader = nil
            loginState = .idle
            stopLoginWindow()
            onAuthSuccess?()
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Org discovery failed: \(error.localizedDescription)")
            handleOrgDiscoveryFailure("Connection error. Please try again.")
        }
    }

    /// The add-or-reactivate tail of a WebView sign-in, reached from the single-org route and from
    /// the org picker. Returns false only when the entry limit refuses the add; on every other path
    /// it has written credentials and switched by the time it returns.
    ///
    /// Split out of `fetchOrganizationId` rather than left inline so both of its routes are testable:
    /// the picker runs through an NSAlert sheet, which needs a visible window and is unavailable
    /// headless (the same reason the existing picker tests drive `orgPickerContinuation` directly).
    // internal for @testable access in AuthManagerTests
    func addOrReactivateWebViewAccount(org: Organization, orgs: [Organization], sessionKey: String,
                                       cookieHeader: String, email: String) -> Bool {
        // The same credentials that repair (or add) the chosen org are good for every OTHER stored
        // org they enumerate, so repair those in the same sign-in instead of making the user sign in
        // again per org (R1, R2, issue #41). The chosen org is skipped because the route calling this
        // has already written it. On the single-org route this is a no-op by construction: `orgs`
        // holds one entry and it is the chosen one.
        //
        // Called ONLY from the two success routes below, never before the limit-reached exit (KTD3):
        // picking an un-stored org while at the entry limit must report the limit having rewritten
        // nothing. Called just before `switchTo`, which keeps `switchTo` the last jar-touching step:
        // `AccountStore.updateSessionKey` re-primes the shared jar only for the active entry, so a
        // sibling write is jar-neutral unless the sibling is the outgoing active account, and that
        // write puts in the same fresh credentials `switchTo` is about to.
        //
        // No jar restore inside THIS function, and none belongs here: every success route below ends
        // in `switchTo`, and the limit-reached route returns without having written anything, so a
        // restore here would only fight the switch. That covers this function's own writes and
        // nothing more. It is NOT true of the shared cookie jar on the path as a whole - by the time
        // this runs, `ClaudeAPI.makeRequest` in `fetchOrganizationId` has already repointed that jar
        // at the signing-in account. The restore for that lives in `fetchOrganizationId`'s `defer`,
        // which every failure and cancellation exit passes through. An earlier version of this
        // comment read "this route has no jar restore and needs none", which was true of the account
        // store and false of the jar, and the gap it blessed was a P1 (review finding).
        //
        // Accepted limit (D7): an entry is keyed only by org and labelled with whoever added it
        // first, and there is deliberately no owner check here - see the all-orgs-already-stored
        // branch in discoverAndAddManualAccount for why the stored email cannot serve as one.
        //
        // Returns how many SIBLINGS were repaired. That is the quantity the confirmation is gated on,
        // and the chosen org is counted separately by each branch below, because only one of the two
        // repaired it (R6).
        func refreshSiblings() -> Int {
            let siblings = Self.matchedAccounts(orgs: orgs, accounts: accountStore.accounts)
                .filter { $0.organizationId != org.uuid }
            for sibling in siblings {
                accountStore.updateSessionKey(sibling.id, sessionKey, cookieHeader: cookieHeader)
                refreshStoredPlan(for: sibling, from: orgs)
                // The siblings belong to the same claude.ai login as the org being signed in to -
                // that is what `matchedAccounts` means - so this sign-in's address labels them too
                // wherever they are still carrying a placeholder (R7).
                repairPlaceholderEmail(for: sibling, with: email)
            }
            if !siblings.isEmpty {
                logger.info("Re-auth: refreshed \(siblings.count) sibling account(s) of the chosen org")
            }
            return siblings.count
        }

        let account = Account(
            email: email,
            sessionKey: sessionKey,
            organizationId: org.uuid,
            organizationName: org.sanitizedName,
            rateLimitTier: org.rateLimitTier,
            capabilities: org.capabilities,
            billingType: org.billingType,
            allCookieHeader: cookieHeader
        )

        if accountStore.addAccount(account) {
            // The chosen org is newly stored, so it is not part of the repaired count - only the
            // siblings this sign-in rescued alongside it are (R6). Same basis as the manual picker
            // with `pickedOrgWasStored` false, so adding an org that rescued one stored sibling
            // reports "Refreshed 1 organization." on both paths rather than only on the paste box.
            let siblings = refreshSiblings()
            accountStore.switchTo(account.id)
            // Non-PII id, not displayName (= email by default); os_log can be read off-device.
            logger.info("Account added and activated: \(account.id.uuidString)")
            reportWebViewRepair(siblingsRepaired: siblings, signedInOrgRepaired: false)
            return true
        }

        if let existing = accountStore.accounts.first(where: { $0.organizationId == org.uuid }) {
            // Re-authentication: update session key AND the full cookie header so the next
            // API call primes the jar with the fresh Cloudflare / CSRF cookies, not the stale
            // pair that was paired with the previous sessionKey.
            accountStore.updateSessionKey(existing.id, sessionKey, cookieHeader: cookieHeader)
            // Re-auth is also when a changed plan shows up, so refresh it here and not only on the
            // add path above (R4).
            accountStore.updatePlan(existing.id, rateLimitTier: org.rateLimitTier,
                                    capabilities: org.capabilities, billingType: org.billingType)
            // And it is when a placeholder label can finally be replaced with the real address (R7).
            repairPlaceholderEmail(for: existing, with: email)
            // The chosen org WAS already stored, so it counts as repaired along with its siblings.
            let siblings = refreshSiblings()
            accountStore.switchTo(existing.id)
            logger.info("Re-authenticated existing account: \(existing.id.uuidString)")
            reportWebViewRepair(siblingsRepaired: siblings, signedInOrgRepaired: true)
            return true
        }

        logger.warning("Failed to add account (limit reached)")
        return false
    }

    private func handleOrgDiscoveryFailure(_ message: String) {
        pendingSessionKey = nil
        pendingCookieHeader = nil
        hasCapturedSession = false
        loginState = .error(message)
    }

    private func showOrgPicker(orgs: [Organization]) async -> Organization? {
        guard let window = loginWindowController?.window else { return nil }

        return await withCheckedContinuation { continuation in
            // Store the continuation so a teardown (timeout / stopLoginWindow) that closes the window
            // out from under this sheet can resume it instead of leaking the suspended
            // fetchOrganizationId task. resumeOrgPicker is resume-once, so whichever fires first —
            // this completion handler or teardown — wins and the other is a no-op.
            orgPickerContinuation = continuation
            let alert = NSAlert()
            alert.messageText = "Choose Organization"
            alert.informativeText = "Multiple organizations found. Select which one to monitor."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Select")
            alert.addButton(withTitle: "Cancel")

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28), pullsDown: false)
            for (index, org) in orgs.enumerated() {
                var title = org.displayName == "Organization" ? "Organization \(index + 1)" : org.displayName
                // Disambiguate if another org has the same display name
                let duplicateCount = orgs.prefix(index).filter { $0.displayName == org.displayName && org.displayName != "Organization" }.count
                if duplicateCount > 0 {
                    title = "\(title) (\(duplicateCount + 1))"
                }
                // Mark orgs already stored so the user can tell an "add" choice from a "reactivate".
                if accountStore.accounts.contains(where: { $0.organizationId == org.uuid }) {
                    title = "\(title) (already added)"
                }
                popup.addItem(withTitle: title)
            }
            alert.accessoryView = popup

            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    let selectedIndex = popup.indexOfSelectedItem
                    guard selectedIndex >= 0, selectedIndex < orgs.count else {
                        self?.resumeOrgPicker(with: nil)
                        return
                    }
                    self?.resumeOrgPicker(with: orgs[selectedIndex])
                } else {
                    self?.resumeOrgPicker(with: nil)
                }
            }
        }
    }

    /// Resume the stored org-picker continuation AT MOST ONCE and clear it. Both the sheet's
    /// completion handler and a teardown (`stopLoginWindow`) call this; the nil-check makes the
    /// second caller a no-op, so a checked continuation is never double-resumed (a trap) and a
    /// suspended picker is never leaked when the window is torn down mid-choice.
    // internal for @testable access in AuthManagerTests
    func resumeOrgPicker(with org: Organization?) {
        guard let continuation = orgPickerContinuation else { return }
        orgPickerContinuation = nil
        continuation.resume(returning: org)
    }

    /// The address to label a stored account with: `/api/account` first, the organizations body
    /// second (R7, KTD7).
    ///
    /// Nil when neither produces one, which is what makes the caller fall back to the positional
    /// "Account N" placeholder. That fallback used to be the ONLY outcome: `email_address` is absent
    /// from the organizations response entirely, so every branch of `extractEmail` was dead and every
    /// account on every install was named "Account 1", "Account 2".
    ///
    /// `extractEmail` is kept underneath rather than deleted with the bug it failed to catch. It
    /// costs one pass over data already in hand, it is the only thing standing between a future
    /// `/api/account` change and the placeholder coming back, and its branches are pinned by tests.
    private func resolveEmail(sessionKey: String, orgs: [Organization], rawData: Data) async -> String? {
        if let email = await fetchAccountEmail(sessionKey: sessionKey) {
            return email
        }
        return extractEmail(from: orgs, rawData: rawData)
    }

    /// The signed-in person's address from `GET /api/account`, or nil when the lookup does not
    /// produce one (R7, KTD7).
    ///
    /// Every failure route returns nil rather than throwing, and the callers fall back. This request
    /// decides a label and nothing else, so a sign-in must never fail because a cosmetic lookup did.
    ///
    /// `/api/account` and not `/api/bootstrap`: both carry `email_address` and bootstrap is about
    /// 15x the bytes for it. It runs on the two sign-in routes only, never on the two-minute poll.
    ///
    /// No `cookieHeader` is passed to `makeRequest`, deliberately. Both callers have just primed the
    /// shared jar for this sign-in - the browser path through `makeRequest`, the paste path through
    /// `activateCookies` - and handing a header in again would re-prime it, throwing away whatever
    /// Cloudflare cookie the organizations response rotated in. Nil means "use the jar as it stands",
    /// which is what `UsageService.pollUsage` does too.
    // internal for @testable access in AuthManagerTests
    func fetchAccountEmail(sessionKey: String) async -> String? {
        guard let request = ClaudeAPI.makeRequest(path: "/api/account", sessionKey: sessionKey) else {
            return nil
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // Status only. The body of this endpoint is the account record itself, so it never
                // goes to os_log, which can be read off-device.
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.info("Account email lookup returned HTTP \(status) - falling back to the org body")
                return nil
            }
            let profile = try JSONDecoder().decode(AccountProfile.self, from: data)
            guard let email = profile.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty else {
                logger.info("Account email lookup carried no address - falling back to the org body")
                return nil
            }
            return email
        } catch {
            logger.info("Account email lookup failed - falling back to the org body")
            return nil
        }
    }

    /// Whether a stored label is one of the app's own "Account N" placeholders rather than a real
    /// address. Those are written by both sign-in routes when no address could be found, and by the
    /// single-account migration in `StorageService`.
    ///
    /// This is the whole safety rule behind `repairPlaceholderEmail`: an entry is keyed by org and
    /// labelled with whoever added it first (D7), and two claude.ai logins can share one org, so
    /// overwriting a REAL label with a fresh sign-in's address would rename someone else's entry.
    /// An empty label counts as a placeholder because it renders as nothing at all.
    ///
    /// `nonisolated`: a pure rule over a string, unit-testable without an `AuthManager`, the same
    /// shape as `selectOrg` and `repairConfirmation`.
    nonisolated static func isPlaceholderEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        guard trimmed.hasPrefix("Account ") else { return false }
        let digits = trimmed.dropFirst("Account ".count)
        // ASCII digits only: `Character.isNumber` also accepts Eastern Arabic and other numerals,
        // and this is matching text the app itself wrote, which is always plain ASCII.
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Replace an "Account N" placeholder on a stored entry with the real address this sign-in found
    /// (R7). Every re-auth route calls this next to its `updateSessionKey`, because everyone who
    /// signed in before this release has a placeholder on every entry and nothing else would ever
    /// repair it: without this, only newly added accounts get real names and every existing user
    /// stays broken.
    ///
    /// Three things it deliberately does not do. It does not touch a real stored address, for the
    /// reason spelled out in `isPlaceholderEmail`. It writes nothing when this sign-in's own lookup
    /// came back empty, so one placeholder is never swapped for another. And it leaves `nickname`
    /// alone: `Account.displayName` is `nickname ?? email`, so an account the user has renamed keeps
    /// showing that name and only the label underneath it is corrected.
    private func repairPlaceholderEmail(for account: Account, with email: String?) {
        guard let email,
              !Self.isPlaceholderEmail(email),
              Self.isPlaceholderEmail(account.email) else { return }
        accountStore.updateEmail(account.id, email)
        // Non-PII id, never the address itself: os_log can be read off-device.
        logger.info("Repaired placeholder label on account \(account.id.uuidString)")
    }

    private func extractEmail(from orgs: [Organization], rawData: Data) -> String? {
        // Prefer the enriched model's emailAddress field
        for org in orgs {
            if let email = org.emailAddress, !email.isEmpty {
                return email
            }
        }
        // Fallback: search raw JSON for additional email keys not in the model
        guard let json = try? JSONSerialization.jsonObject(with: rawData) as? [[String: Any]],
              let first = json.first else { return nil }
        for key in ["email", "billing_email", "primary_email"] {
            if let email = first[key] as? String, !email.isEmpty {
                return email
            }
        }
        if let billing = first["billing"] as? [String: Any],
           let email = billing["email"] as? String, !email.isEmpty {
            return email
        }
        return nil
    }

    // MARK: - Manual sign-in (U5 — the universal paste floor)

    /// Validate a pasted credential (a full `name=value; …` cookie header or a bare `sessionKey`)
    /// and add the account. This is the universal floor (#5): it works without the login WebView,
    /// so it covers accounts the embedded flow can't complete (Google-federated, passkey-only).
    /// Reuses `ClaudeAPI.activateCookies` and the same org-discovery + account-add semantics as
    /// the WebView path, including the multi-org picker contract (pattern #6).
    func manualSignIn(_ pasted: String) async -> ManualSignInResult {
        guard let parsed = Self.parsePastedCredentials(pasted) else {
            return .invalidInput
        }
        return await discoverAndAddManualAccount(sessionKey: parsed.sessionKey, cookieHeader: parsed.cookieHeader)
    }

    /// Finish a manual sign-in after the user picks an org (the multi-org, no-existing-match case).
    func completeManualSignIn(org: Organization) -> ManualSignInResult {
        // The second network window of the manual flow (R11, KTD8, issue #41).
        // `discoverAndAddManualAccount` resumed polling when it handed off to the picker, because a
        // picker waits on a person; the writes below - `addOrReactivateManualAccount` ends in
        // `switchTo`, which re-primes the shared jar, and the sibling loop writes more entries -
        // would otherwise run with polling live. A pause taken in the discovery function and
        // resumed only there leaves this half unprotected.
        //
        // Above the pending-context guard, and paired with `defer`, so no exit here or added later
        // can skip the resume. Suspending for the invalid-input return costs one immediately
        // reversed pause; leaving a route un-resumed costs polling until the app restarts.
        onSuspendPolling?()
        defer { onResumePolling?() }
        guard let ctx = pendingManualSignIn else { return .invalidInput }
        pendingManualSignIn = nil
        // Read before the write, because afterwards every route below has an entry for this org and
        // the two cases are indistinguishable. A picked org that was already stored is a repair and
        // counts towards the confirmation; a newly added one is not (R6).
        let pickedOrgWasStored = accountStore.accounts.contains { $0.organizationId == org.uuid }
        let result = addOrReactivateManualAccount(org: org, sessionKey: ctx.sessionKey, cookieHeader: ctx.cookieHeader, email: ctx.email)
        // The sibling refresh runs ONLY behind this success check (KTD3). Picking an un-stored org
        // while at the entry limit returns .accountLimitReached, and repairing siblings first would
        // report a limit error having already rewritten several entries' credentials.
        guard case .success(let name, _) = result else { return result }
        // The same credentials that just repaired (or added) the picked org are good for every other
        // stored org they enumerate, so repair those too instead of making the user pick, paste, and
        // repeat per org (R2, issue #41). The picked entry is skipped: addOrReactivateManualAccount
        // already wrote it, and it is now the active one.
        //
        // Jar order (KTD3): addOrReactivateManualAccount ends in switchTo, which primed the jar with
        // the picked account's fresh cookies. Every entry written below is non-active, and
        // AccountStore.updateSessionKey re-primes the jar only for the active entry, so this loop is
        // jar-neutral and switchTo stays the last jar-touching step. Unlike the all-already-stored
        // branch this route DOES switch, which is pre-existing behaviour R3 preserves.
        //
        // Accepted limit (D7): an entry is keyed only by org and labelled with whoever added it
        // first, and there is deliberately no owner check here - see the all-already-stored branch
        // in discoverAndAddManualAccount for why the stored email cannot serve as one.
        let siblings = Self.matchedAccounts(orgs: ctx.orgs, accounts: accountStore.accounts)
            .filter { $0.organizationId != org.uuid }
        for sibling in siblings {
            accountStore.updateSessionKey(sibling.id, ctx.sessionKey, cookieHeader: ctx.cookieHeader)
            refreshStoredPlan(for: sibling, from: ctx.orgs)
            // `ctx.email` is the label the discovery step resolved, so the pick route repairs the
            // picked org's stored siblings with the same address the add site used (R7).
            repairPlaceholderEmail(for: sibling, with: ctx.email)
        }
        if !siblings.isEmpty {
            logger.info("Manual sign-in pick: refreshed \(siblings.count) sibling account(s) of the picked org")
        }
        // Re-report the success with the repaired total. Without this the picker route would confirm
        // "Signed in as X" having also rescued X's siblings, which is the silent half of the same
        // bug R6 exists to close (R6, issue #41).
        return .success(name, refreshedCount: siblings.count + (pickedOrgWasStored ? 1 : 0))
    }

    /// Parse a pasted credential into a `sessionKey` and (when present) the full cookie header.
    /// Returns nil when no usable `sessionKey` can be extracted. Pure + static for unit testing.
    static func parsePastedCredentials(_ raw: String) -> (sessionKey: String, cookieHeader: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Full cookie header: contains a `sessionKey=…` pair somewhere in the string.
        if trimmed.contains("sessionKey=") {
            for pair in trimmed.components(separatedBy: ";") {
                let kv = pair.trimmingCharacters(in: .whitespaces)
                guard kv.hasPrefix("sessionKey=") else { continue }
                let value = String(kv.dropFirst("sessionKey=".count))
                guard !value.isEmpty else { return nil }
                // Keep the full header when other cookies are present (carries HttpOnly `__cf_bm`);
                // otherwise treat it as a bare key.
                let hasOtherCookies = trimmed.contains(";")
                return (value, hasOtherCookies ? trimmed : nil)
            }
            return nil
        }

        // Bare `sessionKey`: a single token with no cookie syntax or whitespace.
        if !trimmed.contains(";"), !trimmed.contains(" ") {
            return (trimmed, nil)
        }

        return nil
    }

    private func discoverAndAddManualAccount(sessionKey: String, cookieHeader: String?) async -> ManualSignInResult {
        // Drop any prior unfinished org-choice context so a stale credential is not retained.
        pendingManualSignIn = nil

        // `restoreActiveJar` (the method, shared with the browser path) is what every non-success
        // outcome below calls to put the active account's cookies back after `activateCookies`
        // rewrote the SHARED jar that UsageService.pollUsage reads. It reads the store at restore
        // time, not before the network call (R10, KTD6) - see the method for why that matters.

        // Pause polling for this sign-in's network window (R11, KTD8, issue #41), immediately
        // before the first jar prime and never after it. The line below rewrites the SHARED jar
        // that `UsageService.pollUsage` reads, and URLSession writes a request's Cookie header when
        // the request goes out rather than when it was created - so a poll already in flight can be
        // answered with the pasted account's credentials. That answer is a 403, which marks a
        // healthy account expired and stops polling, and Branch B below fires no success callback,
        // so nothing would start it again.
        //
        // `defer` rather than a call on each route: this function has ten exits including a throw,
        // and a missed one leaves polling dead until the app restarts - worse than the race being
        // fixed. The pause covers the network window ONLY: the `.needsChoice` route returns here to
        // show the SwiftUI picker, which waits on a person, so the resume fires and
        // `completeManualSignIn` suspends again for its own writes (KTD8).
        onSuspendPolling?()
        defer { onResumePolling?() }

        ClaudeAPI.activateCookies(sessionKey: sessionKey, cookieHeader: cookieHeader)

        guard let request = ClaudeAPI.makeRequest(path: "/api/organizations", sessionKey: sessionKey, cookieHeader: cookieHeader) else {
            restoreActiveJar()
            return .connectionError
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                restoreActiveJar()
                return .connectionError
            }

            // U6 diagnostics: manual-path org-discovery HTTP status code only.
            DiagnosticsLogger.shared.emitMilestone(kind: "org-discovery-status", payload: [
                "status": http.statusCode,
                "path": "manual"
            ])

            if http.statusCode == 401 || http.statusCode == 403 {
                // 403 with only a bare key is most often a Cloudflare block (missing HttpOnly
                // `__cf_bm`) — steer the user to paste the full header. Pattern #5: the server is
                // authoritative; we do not guess validity client-side.
                restoreActiveJar()
                return .authFailed(suggestFullHeader: cookieHeader == nil)
            }

            let orgs = try JSONDecoder().decode([Organization].self, from: data)
            guard !orgs.isEmpty else {
                restoreActiveJar()
                return .noOrganizations
            }

            // Same lookup and same fallback as the browser path (R7, KTD7): `/api/account` answers
            // 200 under a bare `sessionKey` cookie, so a paste with no full header still gets a real
            // address rather than "Account N".
            let email = await resolveEmail(sessionKey: sessionKey, orgs: orgs, rawData: data) ?? "Account \(accountStore.accounts.count + 1)"

            // Org choice via the same pure `Self.selectOrg` rule as the WebView path; this site
            // returns a ManualSignInResult for the SwiftUI picker instead of driving an NSAlert.
            let selectedOrg: Organization
            switch Self.selectOrg(orgs: orgs, accounts: accountStore.accounts) {
            case .single(let org):
                selectedOrg = org
            case .needsChoice(let choices):
                // Restore the active account's jar while the picker is shown; completeManualSignIn
                // re-primes the jar to the chosen account via switchTo.
                restoreActiveJar()
                pendingManualSignIn = (sessionKey, cookieHeader, email, orgs)
                return .needsOrgChoice(choices)
            case .allAlreadyAdded:
                // Every org on this account is already stored. Refresh EVERY stored entry these
                // credentials list, not only the one being viewed (R1, issue #41): before this, a
                // user with two orgs on one email had to switch org in Settings and paste the same
                // credentials a second time. Early-return here so this bypasses the trailing
                // `if case .success = result {} else { restoreActiveJar() }` guard below - Branch A
                // must NOT restore, or it would undo the refresh it just primed into the jar.
                let toRefresh = Self.matchedAccounts(orgs: orgs, accounts: accountStore.accounts)
                guard !toRefresh.isEmpty else {
                    // Unreachable by construction: `.allAlreadyAdded` is returned only when every
                    // org in `orgs` is already stored, and `orgs` is non-empty by the check above,
                    // so at least one stored entry always matches. Kept as a defensive exit instead
                    // of a force-unwrap; it is not a real terminal anyone is expected to hit.
                    restoreActiveJar()
                    return .accountLimitReached
                }
                // Accepted limit (D7): an entry is keyed only by org and labelled with whoever added
                // it first. If two claude.ai logins share one org and both are stored on this Mac,
                // this write puts the second login's credentials onto an entry carrying the first's
                // label, and that entry then reports the second person's usage. There is
                // deliberately no owner check: the stored email is frequently the fallback text
                // "Account 3", and it is read from the FIRST org in the response rather than
                // per-org, so gating on it would refuse ordinary repairs and reintroduce the issue
                // #32 bug. This already happened on the single refreshed entry; the loop widens it.
                var refreshedIds: Set<UUID> = []
                for account in toRefresh {
                    accountStore.updateSessionKey(account.id, sessionKey, cookieHeader: cookieHeader)
                    refreshStoredPlan(for: account, from: orgs)
                    // The paste twin of the browser all-stored repair: this is the route an existing
                    // user reaches, so it is where their placeholder labels get corrected (R7).
                    repairPlaceholderEmail(for: account, with: email)
                    refreshedIds.insert(account.id)
                }
                // Gate on the refreshed SET, never on a single matched entry (KTD1). `matchedAccount`
                // happens to prefer the active account when its org is listed, which made the old
                // `matched.id == activeAccountId` check correct, but that invariant lives in another
                // function and no test fails if it stops holding. Do NOT "simplify" this back to the
                // first refreshed entry.
                let activeAccountRefreshed = accountStore.activeAccountId.map { refreshedIds.contains($0) } ?? false
                if activeAccountRefreshed {
                    // Branch A - the active entry is among those repaired: updateSessionKey already
                    // re-primed the jar to the fresh cookies. Do not restore, do not switch. Fire
                    // onAuthSuccess so polling restarts (recovers an active session that had gone
                    // authFailed) - once, after the loop, not per entry, because it clears the
                    // cached usage and chains a restart (KTD2).
                    logger.info("Manual sign-in: all orgs already added, refreshed \(refreshedIds.count) account(s) including the active one")
                    onAuthSuccess?()
                } else {
                    // Branch B - the active entry is NOT among them: persist fresh creds on the
                    // siblings, then restore the real active account's jar so it keeps serving its
                    // own cookies. Do not switch (a paste must not silently switch the active
                    // account) and do not fire onAuthSuccess (the active account was left untouched,
                    // so it must stay stopped rather than restart on credentials that are not its).
                    restoreActiveJar()
                    logger.info("Manual sign-in: all orgs already added, refreshed \(refreshedIds.count) background account(s)")
                }
                // Both numbers travel to the view, which is the only place a user-facing string is
                // built. Branch B is why the flag is carried and not inferred: the confirmation there
                // has to say the viewed account was deliberately left alone (R6, D6).
                return .alreadySignedInAllOrgs(refreshedCount: refreshedIds.count,
                                               activeAccountRefreshed: activeAccountRefreshed)
            }

            let result = addOrReactivateManualAccount(org: selectedOrg, sessionKey: sessionKey, cookieHeader: cookieHeader, email: email)
            // Only a successful add/reactivate (which re-primes the jar to the new account via
            // switchTo) should leave the jar mutated; a limit-reached result must restore.
            if case .success = result {} else { restoreActiveJar() }
            return result
        } catch {
            logger.error("Manual sign-in org discovery failed: \(error.localizedDescription)")
            restoreActiveJar()
            return .connectionError
        }
    }

    private func addOrReactivateManualAccount(org: Organization, sessionKey: String, cookieHeader: String?, email: String) -> ManualSignInResult {
        let account = Account(email: email, sessionKey: sessionKey, organizationId: org.uuid,
                              organizationName: org.sanitizedName, rateLimitTier: org.rateLimitTier,
                              capabilities: org.capabilities, billingType: org.billingType,
                              allCookieHeader: cookieHeader)
        if accountStore.addAccount(account) {
            accountStore.switchTo(account.id)
            logger.info("Manual sign-in added a new account")
            onAuthSuccess?()
            // Disambiguated so adding org B of a same-email account confirms which org (issue #32).
            // A brand-new entry repairs nothing, so the count is zero and the confirmation stays the
            // plain "Signed in as X" it always was (R6).
            return .success(accountStore.disambiguatedName(for: account), refreshedCount: 0)
        } else if let existing = accountStore.accounts.first(where: { $0.organizationId == org.uuid }) {
            accountStore.updateSessionKey(existing.id, sessionKey, cookieHeader: cookieHeader)
            // Same reason as the browser twin: a re-auth is when a changed plan becomes visible (R4).
            accountStore.updatePlan(existing.id, rateLimitTier: org.rateLimitTier,
                                    capabilities: org.capabilities, billingType: org.billingType)
            // Same as the browser twin: a re-auth is when a placeholder label can be replaced (R7).
            repairPlaceholderEmail(for: existing, with: email)
            accountStore.switchTo(existing.id)
            logger.info("Manual sign-in reactivated an existing account")
            onAuthSuccess?()
            // An existing entry rewritten with fresh credentials IS a repair, so it counts as one.
            // `completeManualSignIn` replaces this count with its own total once it has added the
            // siblings the pick also rescued.
            //
            // Re-read the entry for the confirmation instead of naming `existing`: `Account` is a
            // struct, so that copy still carries the label the repair above has just replaced, and
            // the paste box would confirm "Signed in as Account 2" in the one moment it finally has
            // the real address to print.
            let relabelled = accountStore.accounts.first { $0.id == existing.id } ?? existing
            return .success(accountStore.disambiguatedName(for: relabelled), refreshedCount: 1)
        }
        return .accountLimitReached
    }

    // MARK: - Sign Out

    func signOut(accountId: UUID) {
        accountStore.removeAccount(accountId)
        hasCapturedSession = false
        loginState = .idle
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { }
        logger.info("Signed out account \(accountId.uuidString)")
    }

    func signOutAll() {
        let ids = accountStore.accounts.map(\.id)
        for id in ids { accountStore.removeAccount(id) }
        hasCapturedSession = false
        loginState = .idle
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { }
        logger.info("Signed out all accounts")
    }

    func handleAuthFailure() {
        // Mark the active account as failed — user switches manually
        hasCapturedSession = false
        loginState = .idle
        logger.info("Auth failure for active account")
    }

    // MARK: - Allowed Domains

    /// Google serves "Continue with Google" on country-specific accounts hosts
    /// (e.g. `accounts.google.com.tr`, `accounts.google.co.uk`, `accounts.google.de`)
    /// that 302 back to `accounts.google.com`. The navigation allowlist evaluates the
    /// localized host *before* that redirect fires, so unless it is allowed the OAuth
    /// flow dead-ends on a blank screen for users in those regions. A Turkish reporter's
    /// NetLog confirmed `Blocked navigation to disallowed domain: accounts.google.com.tr`
    /// (issues #17, #25; original fix by @MidnightCoke in PR #24).
    ///
    /// Per the OAuth-domain hardening rule (docs/solutions/security-issues/
    /// keychain-credential-storage-and-auth-hardening.md) these are enumerated as exact
    /// Google ccTLD hosts and matched with `==` for the apex plus a `.`-prefixed
    /// `hasSuffix` for subdomains - never a structural `accounts.google.<any-tld>`
    /// wildcard, which would trust hosts Google does not serve (`accounts.google.io`)
    /// or `google.<tld>` registrations Google may not own. Every entry is a
    /// Google-operated country domain. A locale we miss surfaces in the exported
    /// nav-decision diagnostics as a blocked `accounts.google.*` host; add it here.
    static let googleAccountsLocalizedHosts: Set<String> = [
        // Europe
        "accounts.google.co.uk", "accounts.google.de", "accounts.google.fr",
        "accounts.google.es", "accounts.google.it", "accounts.google.nl",
        "accounts.google.pl", "accounts.google.ru", "accounts.google.ch",
        "accounts.google.at", "accounts.google.be", "accounts.google.se",
        "accounts.google.no", "accounts.google.dk", "accounts.google.fi",
        "accounts.google.pt", "accounts.google.gr", "accounts.google.cz",
        "accounts.google.hu", "accounts.google.ro", "accounts.google.ie",
        "accounts.google.sk", "accounts.google.bg", "accounts.google.hr",
        "accounts.google.lt", "accounts.google.lv", "accounts.google.ee",
        "accounts.google.si", "accounts.google.com.ua",
        // Americas
        "accounts.google.ca", "accounts.google.com.br", "accounts.google.com.mx",
        "accounts.google.com.ar", "accounts.google.com.co", "accounts.google.com.pe",
        "accounts.google.cl",
        // Middle East & Africa
        "accounts.google.com.tr", "accounts.google.com.sa", "accounts.google.ae",
        "accounts.google.com.eg", "accounts.google.co.za", "accounts.google.com.ng",
        "accounts.google.co.ke", "accounts.google.co.il",
        // Asia-Pacific
        "accounts.google.co.jp", "accounts.google.co.kr", "accounts.google.co.in",
        "accounts.google.co.id", "accounts.google.co.th", "accounts.google.com.sg",
        "accounts.google.com.hk", "accounts.google.com.tw", "accounts.google.com.ph",
        "accounts.google.com.vn", "accounts.google.com.my", "accounts.google.com.pk",
        "accounts.google.com.au", "accounts.google.co.nz",
    ]

    /// Exact-or-subdomain membership test for `googleAccountsLocalizedHosts`: matches
    /// the apex with `==` and subdomains with a leading-dot `hasSuffix` (pattern #2),
    /// so `accounts.google.com.tr` and `x.accounts.google.com.tr` pass while
    /// `evilaccounts.google.com.tr` and `accounts.google.com.tr.evil.com` do not.
    static func isLocalizedGoogleAccountsHost(_ host: String) -> Bool {
        googleAccountsLocalizedHosts.contains(host)
            || googleAccountsLocalizedHosts.contains { host.hasSuffix("." + $0) }
    }

    // internal for @testable access in AuthManagerTests
    func isAllowedDomain(_ host: String) -> Bool {
        // Exact match plus `".X"` suffix for multi-label domains - rejects
        // attacker-injected prefixes like `evil.googleapis.com.attacker.com`
        // that a bare `hasSuffix(".googleapis.com")` would accept.
        host == "claude.ai" ||
        host.hasSuffix(".claude.ai") ||
        host.hasSuffix(".anthropic.com") ||
        host == "accounts.google.com" ||
        host.hasSuffix(".accounts.google.com") ||
        Self.isLocalizedGoogleAccountsHost(host) ||
        host == "google.com" ||
        host.hasSuffix(".google.com") ||
        host.hasSuffix(".gstatic.com") ||
        host.hasSuffix(".googleapis.com") ||
        host.hasSuffix(".googleusercontent.com") ||
        host == "youtube.com" ||
        host.hasSuffix(".youtube.com") ||
        host == "appleid.apple.com" ||
        host.hasSuffix(".appleid.apple.com") ||
        host.hasSuffix(".icloud.com") ||
        host.hasSuffix(".challenges.cloudflare.com") ||
        host == "cf-chl-widget.cloudflare.com"
    }

    /// Whether a `window.open()` to `url` should spawn an OAuth popup. Pattern #7: the `about:`
    /// scheme check MUST precede the host check - `about:blank` (Google's OAuth bootstrap) has
    /// no host, so a host guard placed first would silently block it and break Google sign-in.
    // internal for @testable access in AuthManagerTests
    func allowsOAuthPopup(for url: URL) -> Bool {
        if url.scheme == "about" {
            let abs = url.absoluteString
            return abs == "about:blank" || abs.hasPrefix("about:blank") || abs.hasPrefix("about:srcdoc")
        }
        guard let host = url.host else { return false }
        return isAllowedDomain(host)
    }
}

// MARK: - WKNavigationDelegate

extension AuthManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Allow OAuth blank-frame bootstraps (about:blank / about:srcdoc). These appear as
        // intermediate frames during Google's OAuth flow; blocking them breaks the popup.
        if url.scheme == "about" {
            let absoluteString = url.absoluteString
            if absoluteString == "about:" ||
               absoluteString.hasPrefix("about:blank") ||
               absoluteString.hasPrefix("about:srcdoc") {
                decisionHandler(.allow)
            } else {
                // Log the scheme only, never the full URI — an `about:` payload (e.g.
                // about:blank?code=…) could carry a live OAuth code in Release.
                logger.info("Blocked navigation to unusual about: URI (scheme \(url.scheme ?? "?", privacy: .public))")
                decisionHandler(.cancel)
            }
            return
        }

        guard let host = url.host else {
            decisionHandler(.cancel)
            return
        }

        if isAllowedDomain(host) {
            logger.debug("Navigation allowed: \(host)")
            // U6 diagnostics: decision + host only (never url.absoluteString — it may carry
            // query params). Written to the exported diag-*.jsonl.
            DiagnosticsLogger.shared.emitMilestone(kind: "nav-decision", payload: ["decision": "allow", "host": host])
            decisionHandler(.allow)
        } else {
            logger.info("Blocked navigation to disallowed domain: \(host)")
            DiagnosticsLogger.shared.emitMilestone(kind: "nav-decision", payload: ["decision": "block", "host": host])
            decisionHandler(.cancel)
        }
    }

    /// Additive #17 backstop (KTD-2): if a claude.ai navigation response carries a
    /// `Set-Cookie: sessionKey=…`, capture it. This **likely never fires** for the real
    /// failure case — `sessionKey` is HttpOnly and XHR-set during the SPA navigation, and
    /// WebKit strips HttpOnly `Set-Cookie` from the response it hands the delegate. Kept as
    /// a cheap bonus path only; the load-bearing fix is the store re-read on
    /// `webViewDidClose` / KVO. Always allows the response.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        defer { decisionHandler(.allow) }

        guard !hasCapturedSession,
              let httpResponse = navigationResponse.response as? HTTPURLResponse,
              let url = httpResponse.url,
              let host = url.host,
              // Only claude.ai itself can legitimately set the claude.ai sessionKey. Gating on
              // the broad isAllowedDomain allowlist here would let any allowlisted OAuth third
              // party (accounts.google.com, *.gstatic.com, …) deliver a
              // `Set-Cookie: sessionKey=…; Domain=.claude.ai` that Foundation's parser honors —
              // a session-fixation vector (critical pattern #2). Pin to claude.ai.
              host == "claude.ai" || host.hasSuffix(".claude.ai") else { return }

        captureSessionCookie(from: Self.sessionCookies(fromResponseHeaders: httpResponse.allHeaderFields, url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            loginWindowController?.window?.title = "Sign in to Claude — \(url.host ?? "")"
        }

        // Check cookies on every page load (immediate check + polling handles the rest)
        reReadCookieStore(webView)

        // Reset timeout on every navigation — proves user is still actively signing in.
        // Prevents the window from closing while the user checks email for their code.
        armLoginTimeout()
    }
}

// MARK: - WKUIDelegate

extension AuthManager: WKUIDelegate {
    /// Handle `window.open()` requests from the login WebView. Google "Continue with Google"
    /// uses this to spawn its OAuth flow as a popup; if we return nil, OAuth fails with
    /// "There was an error logging you in." Create a real child WebView built from the
    /// provided configuration so `window.opener` is preserved and the OAuth callback can
    /// `postMessage` back to the parent claude.ai page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }

        // Pattern #7: allowsOAuthPopup checks the about: scheme BEFORE the host, so Google's
        // about:blank OAuth bootstrap (no host) is permitted while disallowed hosts are blocked.
        guard allowsOAuthPopup(for: url) else {
            // Scheme + host only, never absoluteString — a custom-scheme OAuth redirect can carry
            // a live `code=` in its path/query (Release info-leak). Mirrors nav-decision logging.
            logger.info("Blocked popup to disallowed URL (scheme \(url.scheme ?? "?", privacy: .public) host \(url.host ?? "?", privacy: .public))")
            return nil
        }

        // Fully retire any previous popup before creating a new one: clear its delegate pointers
        // and nil our reference, so a late webViewDidClose from a replaced popup cannot fall
        // through to this manager (review finding).
        popupWebView?.navigationDelegate = nil
        popupWebView?.uiDelegate = nil
        popupWebView?.stopLoading()
        popupWebView?.removeFromSuperview()
        popupWebView = nil

        let popup = WKWebView(frame: webView.bounds, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.customUserAgent = ClaudeAPI.safariUserAgent
        popup.autoresizingMask = [.width, .height]
        #if DEBUG
        if #available(macOS 13.3, *) {
            popup.isInspectable = true
        }
        #endif
        webView.addSubview(popup)
        self.popupWebView = popup

        // Host (or scheme when hostless) only — never absoluteString, which on a custom-scheme
        // redirect can carry a live `code=`.
        logger.debug("Created OAuth popup WebView for host \(url.host ?? url.scheme ?? "?", privacy: .public)")
        return popup
    }

    /// Called when the OAuth popup's JavaScript executes `window.close()` after the flow
    /// completes. Tear down the child WebView so the parent login WebView regains focus.
    func webViewDidClose(_ webView: WKWebView) {
        if webView === popupWebView {
            popupWebView?.removeFromSuperview()
            popupWebView = nil
            logger.debug("OAuth popup closed itself")
        }

        // Load-bearing #17 fix (KTD-2): a popup closing is exactly when claude.ai has finished
        // the OAuth redirect and the non-persistent store has had a navigation cycle to sync,
        // so `sessionKey` is now readable even if the poll/observer missed it mid-flight.
        // Re-read the *login* store (not the popup's) right now.
        if let loginWebView, !hasCapturedSession {
            reReadCookieStore(loginWebView)
        }
    }

    /// Surface JS `alert()` messages as native NSAlert sheets. Without this, claude.ai's
    /// error messages are silently dropped inside the WebView.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window = loginWindowController?.window else {
            completionHandler()
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    /// Surface JS `confirm()` prompts as native NSAlert sheets with OK / Cancel.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window = loginWindowController?.window else {
            completionHandler(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }
}

// MARK: - WKScriptMessageHandler (debug-DMG netlog)

#if DEBUG
extension AuthManager: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "claudebatteryNetLog" else { return }
        let body: String
        if let str = message.body as? String {
            body = str
        } else {
            body = String(describing: message.body)
        }
        logger.info("NetLog: \(body, privacy: .public)")
    }
}
#endif

// MARK: - WKHTTPCookieStoreObserver

extension AuthManager: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self, !self.hasCapturedSession else { return }
            let cookies = await cookieStore.allCookies()
            // Re-validate after the await: the login may have been torn down mid-read (stopLoginWindow
            // nils loginWebView). Route through the same funnel/guards as every other trigger.
            guard !self.hasCapturedSession, self.loginWebView != nil else { return }
            self.captureSessionCookie(from: cookies)
        }
    }
}

// MARK: - NSWindowDelegate

extension AuthManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Reset auth state so user can try again
        if loginState == .signingIn {
            hasCapturedSession = false
            pendingSessionKey = nil
            pendingCookieHeader = nil
        }
        loginState = .idle

        // Nil the window controller BEFORE calling stopLoginWindow to break the
        // recursion cycle: stopLoginWindow calls close() which triggers windowWillClose.
        loginWindowController = nil

        // Delegate remaining resource cleanup to stopLoginWindow (single teardown path)
        stopLoginWindow()
    }
}

// MARK: - Models

/// The one field the app reads from `GET /api/account`: the signed-in person's address (R7).
///
/// It is here because `email_address` is absent from the organizations response entirely - confirmed
/// against two live accounts - so `extractEmail`'s every branch returned nil and every account was
/// stored as "Account 1", "Account 2". This endpoint carries the address at the top level and answers
/// 200 under a bare `sessionKey` cookie, so the paste route reaches it as well as the browser one.
///
/// Hand-mapped key for the same reason `Organization` hand-maps its own: this response is read by a
/// plain `JSONDecoder()` with no `keyDecodingStrategy`. Every other field on the endpoint is ignored,
/// which is what keeps the account record from ever reaching a log or the diagnostics export.
struct AccountProfile: Decodable {
    let emailAddress: String?

    private enum CodingKeys: String, CodingKey {
        case emailAddress = "email_address"
    }
}

struct Organization: Codable, Equatable {
    let uuid: String
    let name: String?
    let billingType: String?
    let emailAddress: String?
    /// The org's plan, e.g. "default_claude_max_20x" or "auto_prepaid_tier_3" (both observed live).
    /// This is the only field on the response that names a plan: `billingType` is how the org pays
    /// ("stripe_subscription", "prepaid") and two different plans can share one, so it can never
    /// identify a plan on its own. `PlanRatio.forTier` turns this string into the 5h-over-weekly
    /// ratio the Session dial converts a weekly remainder with (R4).
    let rateLimitTier: String?
    /// What the org is entitled to, e.g. ["claude_max", "chat"] or ["api"] (both observed live).
    /// Stored next to the tier because Free has no positive marker of its own: claude.ai's own
    /// JavaScript picks the plan by looking here for "claude_pro" or "claude_max" and treats their
    /// ABSENCE as Free. Anyone reading this later: do not go looking for a "claude_free" string,
    /// there is none - handle absence.
    let capabilities: [String]?

    /// Written out rather than left to the synthesized memberwise init only so the two plan fields
    /// can carry defaults. Every existing construction site predates them and has no plan to supply.
    init(uuid: String, name: String?, billingType: String?, emailAddress: String?,
         rateLimitTier: String? = nil, capabilities: [String]? = nil) {
        self.uuid = uuid
        self.name = name
        self.billingType = billingType
        self.emailAddress = emailAddress
        self.rateLimitTier = rateLimitTier
        self.capabilities = capabilities
    }

    /// The org's real name, sanitized (newline/RTL-mark strip, 100-char cap), or nil when the org
    /// has no usable name. This is what gets stored on `Account.organizationName`, so a persisted
    /// org name matches how the name renders everywhere else and never carries the `displayName`
    /// "Organization"/billing-type fallback.
    var sanitizedName: String? {
        guard let name, !name.isEmpty else { return nil }
        let sanitized = name.filter { !$0.isNewline && $0 != "\u{200F}" && $0 != "\u{200E}" }
        let capped = String(sanitized.prefix(100))
        return capped.isEmpty ? nil : capped
    }

    var displayName: String {
        if let sanitizedName {
            return sanitizedName
        }
        if let billingType, !billingType.isEmpty {
            return billingType.capitalized
        }
        return "Organization"
    }

    private enum CodingKeys: String, CodingKey {
        case uuid
        case name
        case billingType = "billing_type"
        case emailAddress = "email_address"
        // Mapped by hand, exactly like the two above, and it has to be: the organizations response
        // is read by a plain `JSONDecoder()` with no `keyDecodingStrategy`, unlike `UsageService`
        // which sets `.convertFromSnakeCase`. Drop this line and `rate_limit_tier` decodes as nil
        // forever without a single error - the dial just quietly stops converting.
        case rateLimitTier = "rate_limit_tier"
        case capabilities
    }
}
