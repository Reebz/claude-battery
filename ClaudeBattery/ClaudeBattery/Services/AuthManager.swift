import AppKit
import WebKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "Auth")

enum LoginState: Equatable {
    case idle
    case signingIn
    case error(String)
}

/// Which overlay (if any) is currently shown over the login WebView (U2).
enum LoginOverlayKind: Equatable {
    case none
    case signingIn
    case error
}

/// Outcome of the manual paste sign-in (U5). Drives the Settings UI's inline status.
enum ManualSignInResult: Equatable {
    /// Account added/reactivated; associated value is its display name.
    case success(String)
    /// Multiple orgs with no existing match — the user must pick one (pattern #6).
    case needsOrgChoice([Organization])
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
    private var cookieEnumerationTask: Task<Void, Never>?
    private var cookiePollTimer: Timer?
    private var urlObservation: NSKeyValueObservation?
    private var hasCapturedSession = false
    // internal for @testable access in AuthManagerTests
    var pendingSessionKey: String?
    /// Full Cookie header string built from every `.claude.ai` cookie in the login WebView.
    /// Passed to `ClaudeAPI` alongside `pendingSessionKey` so authenticated API calls during
    /// org discovery carry the full cookie set instead of `sessionKey` alone.
    private var pendingCookieHeader: String?
    /// Context stashed between `manualSignIn` and `completeManualSignIn` when a paste resolves
    /// to multiple orgs and the user must pick one (U5, pattern #6).
    private var pendingManualSignIn: (sessionKey: String, cookieHeader: String?, email: String)?
    /// Child WebView hosting OAuth popups spawned by `window.open()`. Added as a subview of
    /// the primary `loginWebView` so the OAuth provider's callback can `postMessage` back to
    /// the claude.ai page via `window.opener`. Torn down on `webViewDidClose` or login-window
    /// shutdown. Required for "Continue with Google" - without it, `window.open()` returns nil
    /// and Google OAuth fails immediately.
    private var popupWebView: WKWebView?
    var onAuthSuccess: (() -> Void)?
    /// Hook the app wires to open Settings at the manual paste section (U5). Invoked by the
    /// sign-in error overlay's "Sign in manually" button so a stuck user reaches the floor.
    var onManualSignInRequested: (() -> Void)?

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
                self.checkCookiesFromAllSources(webView)
            }
        }

        // Poll cookies every 0.2s — most reliable fallback for non-persistent store observer bugs.
        // Note (KTD-2): a faster poll only samples more often; it does not shrink the store's
        // sync latency. The load-bearing #17 fix is the webViewDidClose / KVO re-read.
        cookiePollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.hasCapturedSession, let webView = self.loginWebView else { return }
                self.checkCookiesFromAllSources(webView)
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
    private func checkCookiesFromAllSources(_ webView: WKWebView) {
        guard !hasCapturedSession else { return }

        Task {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()

            #if DEBUG
            let names = cookies.map { "\($0.name)=\($0.domain)" }.joined(separator: ", ")
            logger.debug("Cookie store poll — \(cookies.count) cookies: \(names)")
            #endif

            captureSessionCookie(from: cookies)
        }
    }

    /// Single capture funnel. Every path that observes cookies (store poll, KVO, navigation
    /// response, popup close) routes its cookie set through here so the `hasCapturedSession`
    /// guard (critical pattern #3) enforces exactly-once capture regardless of which trigger
    /// fires first. Per pattern #5, only the cookie value is read downstream — no store
    /// metadata (e.g. `expiresDate`) is trusted.
    // internal for @testable access in AuthManagerTests
    func captureSessionCookie(from cookies: [HTTPCookie]) {
        guard !hasCapturedSession else { return }
        guard let sessionCookie = cookies.first(where: Self.isSessionCookie) else { return }
        handleCookieCaptured(sessionCookie)
    }

    private func stopLoginWindow() {
        removeLoginOverlay()
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
        label.font = .systemFont(ofSize: 15, weight: .medium)
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
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center

        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .systemFont(ofSize: 12)
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

    @objc private func overlayRetryTapped() {
        retryLogin()
    }

    @objc private func overlayManualTapped() {
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

    // internal for @testable access in AuthManagerTests
    func handleCookieCaptured(_ cookie: HTTPCookie) {
        guard !hasCapturedSession else { return }

        guard Self.isSessionCookie(cookie),
              cookie.isSecure,
              cookie.path == "/" else {
            logger.debug("Cookie rejected — name=\(cookie.name) domain=\(cookie.domain)")
            return
        }

        hasCapturedSession = true
        pendingSessionKey = cookie.value
        loginState = .signingIn
        cookiePollTimer?.invalidate()
        cookiePollTimer = nil

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

    // internal for @testable access in AuthManagerTests
    func fetchOrganizationId() async {
        guard let sessionKey = pendingSessionKey else {
            loginState = .idle
            stopLoginWindow()
            return
        }

        guard let request = ClaudeAPI.makeRequest(path: "/api/organizations", sessionKey: sessionKey, cookieHeader: pendingCookieHeader) else {
            logger.error("Failed to construct organizations API URL")
            handleOrgDiscoveryFailure("Connection error. Please try again.")
            showLoginAlert("Connection Error", "Could not complete sign-in. Please close this window and try again.")
            return
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard !Task.isCancelled else { return }

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Non-HTTP response from organizations API")
                handleOrgDiscoveryFailure("Connection error. Please try again.")
                showLoginAlert("Connection Error", "Could not complete sign-in. Please close this window and try again.")
                return
            }

            logger.info("Org discovery HTTP \(httpResponse.statusCode)")

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                #if DEBUG
                let body = String(data: data, encoding: .utf8) ?? "(non-utf8)"
                logger.warning("Auth failure during org discovery (HTTP \(httpResponse.statusCode)): \(body.prefix(500))")
                #endif
                handleOrgDiscoveryFailure("Sign-in failed. Please try again.")
                showLoginAlert("Sign-in Failed", "The session could not be verified. Please close this window and try again.")
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
                handleOrgDiscoveryFailure("No organizations found for this account.")
                showLoginAlert("No Organizations", "No Claude organizations were found for this account. A Pro or Team subscription may be required.")
                return
            }

            // Determine which org to use
            let chosenOrg: Organization
            if orgs.count == 1 {
                chosenOrg = orgs[0]
            } else if let existingAccount = accountStore.accounts.first(where: { acct in orgs.contains(where: { $0.uuid == acct.organizationId }) }),
                      let match = orgs.first(where: { $0.uuid == existingAccount.organizationId }) {
                // Re-auth: auto-select if any existing account's org is in the list
                chosenOrg = match
                logger.info("Re-auth auto-selected org for account \(existingAccount.displayName): \(match.displayName)")
            } else {
                // Multiple orgs, no auto-select match — show picker
                guard let picked = await showOrgPicker(orgs: orgs) else {
                    // User cancelled the picker
                    handleOrgDiscoveryFailure("Sign-in cancelled.")
                    return
                }
                chosenOrg = picked
            }

            guard !Task.isCancelled else { return }

            // Try to extract email from org response
            let email = extractEmail(from: orgs, rawData: data) ?? "Account \(accountStore.accounts.count + 1)"

            let account = Account(
                email: email,
                sessionKey: sessionKey,
                organizationId: chosenOrg.uuid,
                allCookieHeader: pendingCookieHeader
            )

            if accountStore.addAccount(account) {
                accountStore.switchTo(account.id)
                logger.info("Account added and activated: \(account.displayName)")
            } else if let existing = accountStore.accounts.first(where: { $0.organizationId == chosenOrg.uuid }) {
                // Re-authentication: update session key AND the full cookie header so the next
                // API call primes the jar with the fresh Cloudflare / CSRF cookies, not the stale
                // pair that was paired with the previous sessionKey.
                accountStore.updateSessionKey(existing.id, sessionKey, cookieHeader: pendingCookieHeader)
                accountStore.switchTo(existing.id)
                logger.info("Re-authenticated existing account: \(existing.displayName)")
            } else {
                logger.warning("Failed to add account (limit reached)")
                handleOrgDiscoveryFailure("Account limit reached.")
                showLoginAlert("Account Limit", "You can have up to \(AccountStore.maxAccounts) accounts. Remove one in Settings before adding another.")
                return
            }

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
            showLoginAlert("Connection Error", "Could not complete sign-in. Please close this window and try again.")
        }
    }

    private func handleOrgDiscoveryFailure(_ message: String) {
        pendingSessionKey = nil
        pendingCookieHeader = nil
        hasCapturedSession = false
        loginState = .error(message)
    }

    private func showLoginAlert(_ title: String, _ message: String) {
        guard let window = loginWindowController?.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func showOrgPicker(orgs: [Organization]) async -> Organization? {
        guard let window = loginWindowController?.window else { return nil }

        return await withCheckedContinuation { continuation in
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
                popup.addItem(withTitle: title)
            }
            alert.accessoryView = popup

            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    let selectedIndex = popup.indexOfSelectedItem
                    guard selectedIndex >= 0, selectedIndex < orgs.count else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: orgs[selectedIndex])
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
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
        guard let ctx = pendingManualSignIn else { return .invalidInput }
        pendingManualSignIn = nil
        return addOrReactivateManualAccount(org: org, sessionKey: ctx.sessionKey, cookieHeader: ctx.cookieHeader, email: ctx.email)
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
        ClaudeAPI.activateCookies(sessionKey: sessionKey, cookieHeader: cookieHeader)

        guard let request = ClaudeAPI.makeRequest(path: "/api/organizations", sessionKey: sessionKey, cookieHeader: cookieHeader) else {
            return .connectionError
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .connectionError }

            if http.statusCode == 401 || http.statusCode == 403 {
                // 403 with only a bare key is most often a Cloudflare block (missing HttpOnly
                // `__cf_bm`) — steer the user to paste the full header. Pattern #5: the server is
                // authoritative; we do not guess validity client-side.
                return .authFailed(suggestFullHeader: cookieHeader == nil)
            }

            let orgs = try JSONDecoder().decode([Organization].self, from: data)
            guard !orgs.isEmpty else { return .noOrganizations }

            let email = extractEmail(from: orgs, rawData: data) ?? "Account \(accountStore.accounts.count + 1)"

            // Org choice (pattern #6): never blindly take orgs[0] for multi-org users.
            if orgs.count == 1 {
                return addOrReactivateManualAccount(org: orgs[0], sessionKey: sessionKey, cookieHeader: cookieHeader, email: email)
            }
            if let existing = accountStore.accounts.first(where: { acct in orgs.contains(where: { $0.uuid == acct.organizationId }) }),
               let match = orgs.first(where: { $0.uuid == existing.organizationId }) {
                return addOrReactivateManualAccount(org: match, sessionKey: sessionKey, cookieHeader: cookieHeader, email: email)
            }
            pendingManualSignIn = (sessionKey, cookieHeader, email)
            return .needsOrgChoice(orgs)
        } catch {
            logger.error("Manual sign-in org discovery failed: \(error.localizedDescription)")
            return .connectionError
        }
    }

    private func addOrReactivateManualAccount(org: Organization, sessionKey: String, cookieHeader: String?, email: String) -> ManualSignInResult {
        let account = Account(email: email, sessionKey: sessionKey, organizationId: org.uuid, allCookieHeader: cookieHeader)
        if accountStore.addAccount(account) {
            accountStore.switchTo(account.id)
            logger.info("Manual sign-in added a new account")
            onAuthSuccess?()
            return .success(account.displayName)
        } else if let existing = accountStore.accounts.first(where: { $0.organizationId == org.uuid }) {
            accountStore.updateSessionKey(existing.id, sessionKey, cookieHeader: cookieHeader)
            accountStore.switchTo(existing.id)
            logger.info("Manual sign-in reactivated an existing account")
            onAuthSuccess?()
            return .success(existing.displayName)
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

    private func isAllowedDomain(_ host: String) -> Bool {
        // Exact match plus `".X"` suffix for multi-label domains - rejects
        // attacker-injected prefixes like `evil.googleapis.com.attacker.com`
        // that a bare `hasSuffix(".googleapis.com")` would accept.
        host == "claude.ai" ||
        host.hasSuffix(".claude.ai") ||
        host.hasSuffix(".anthropic.com") ||
        host == "accounts.google.com" ||
        host.hasSuffix(".accounts.google.com") ||
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
                logger.info("Blocked navigation to unusual about: URI: \(absoluteString)")
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
            decisionHandler(.allow)
        } else {
            logger.info("Blocked navigation to disallowed domain: \(host)")
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
              isAllowedDomain(host) else { return }

        var headerFields: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headerFields[key] = value
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        captureSessionCookie(from: cookies)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            loginWindowController?.window?.title = "Sign in to Claude — \(url.host ?? "")"
        }

        // Check cookies on every page load (immediate check + polling handles the rest)
        checkCookiesFromAllSources(webView)

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

        // Allow about:blank/about:srcdoc (Google OAuth bootstraps popups at about:blank
        // before navigating to accounts.google.com). For all other URLs, apply the same
        // domain allowlist as the parent WebView.
        if url.scheme == "about" {
            let abs = url.absoluteString
            guard abs == "about:blank" || abs.hasPrefix("about:blank") || abs.hasPrefix("about:srcdoc") else {
                logger.info("Blocked popup to unusual about: URI: \(abs)")
                return nil
            }
        } else {
            guard let host = url.host, isAllowedDomain(host) else {
                logger.info("Blocked popup to disallowed domain: \(url.host ?? url.scheme ?? "nil")")
                return nil
            }
        }

        // Tear down any previous popup before creating a new one.
        popupWebView?.stopLoading()
        popupWebView?.removeFromSuperview()

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

        logger.debug("Created OAuth popup WebView for: \(url.host ?? url.absoluteString)")
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
            checkCookiesFromAllSources(loginWebView)
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
            if let sessionCookie = cookies.first(where: Self.isSessionCookie) {
                self.handleCookieCaptured(sessionCookie)
            }
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

struct Organization: Codable, Equatable {
    let uuid: String
    let name: String?
    let billingType: String?
    let emailAddress: String?

    var displayName: String {
        if let name, !name.isEmpty {
            let sanitized = name.filter { !$0.isNewline && $0 != "\u{200F}" && $0 != "\u{200E}" }
            return String(sanitized.prefix(100))
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
    }
}
