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

@MainActor
class AuthManager: NSObject, ObservableObject {
    @Published var loginState: LoginState = .idle

    private let storage: StorageService
    private let accountStore: AccountStore
    private var loginWebView: WKWebView?
    private var loginWindowController: NSWindowController?
    private var loginTimeoutTask: Task<Void, Never>?
    private var orgDiscoveryTask: Task<Void, Never>?
    private var cookiePollTimer: Timer?
    private var urlObservation: NSKeyValueObservation?
    private var hasCapturedSession = false
    private var pendingSessionKey: String?
    private var pendingExpiration: Date?
    private var pendingCookieHeader: String?
    private var popupWebView: WKWebView?

    init(storage: StorageService, accountStore: AccountStore) {
        self.storage = storage
        self.accountStore = accountStore
        super.init()
    }

    // MARK: - Login

    func presentLogin() {
        guard loginState != .signingIn else { return }

        guard loginWindowController == nil else {
            loginWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        loginState = .idle

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = ClaudeAPI.safariUserAgentSuffix

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
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

        // Poll cookies every 0.5s — most reliable fallback for non-persistent store observer bugs
        cookiePollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.hasCapturedSession, let webView = self.loginWebView else { return }
                self.checkCookiesFromAllSources(webView)
            }
        }

        if let url = URL(string: "https://claude.ai/login") {
            webView.load(URLRequest(url: url))
        }
    }

    /// Check for session cookie via both WKHTTPCookieStore and JavaScript document.cookie
    private func checkCookiesFromAllSources(_ webView: WKWebView) {
        guard !hasCapturedSession else { return }

        // Path 1: WKHTTPCookieStore (captures HTTP Set-Cookie headers)
        Task {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()

            #if DEBUG
            let names = cookies.map { "\($0.name)=\($0.domain)" }.joined(separator: ", ")
            logger.debug("Cookie store poll — \(cookies.count) cookies: \(names)")
            #endif

            if let sessionCookie = cookies.first(where: Self.isSessionCookie) {
                handleCookieCaptured(sessionCookie)
                return
            }
        }

        // Path 2: JavaScript document.cookie (captures JS-set cookies missed by WKHTTPCookieStore)
        webView.evaluateJavaScript("document.cookie") { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, !self.hasCapturedSession else { return }
                guard let cookieString = result as? String, !cookieString.isEmpty else { return }

                #if DEBUG
                logger.debug("JS document.cookie: \(cookieString.prefix(200))")
                #endif

                // Parse "sessionKey=value; other=value2; ..." format
                let pairs = cookieString.components(separatedBy: "; ")
                for pair in pairs {
                    let parts = pair.components(separatedBy: "=")
                    guard parts.count >= 2, parts[0] == "sessionKey" else { continue }
                    let value = parts.dropFirst().joined(separator: "=")
                    guard !value.isEmpty else { continue }

                    logger.info("Session cookie captured via JavaScript fallback")
                    self.hasCapturedSession = true
                    self.pendingSessionKey = value
                    self.pendingExpiration = nil  // JS cookies don't expose expiration
                    self.pendingCookieHeader = cookieString  // Full JS cookie string includes all visible cookies
                    self.loginState = .signingIn
                    self.cookiePollTimer?.invalidate()
                    self.cookiePollTimer = nil

                    self.orgDiscoveryTask = Task { await self.fetchOrganizationId() }
                    return
                }
            }
        }
    }

    private func stopLoginWindow() {
        loginTimeoutTask?.cancel()
        loginTimeoutTask = nil
        cookiePollTimer?.invalidate()
        cookiePollTimer = nil
        urlObservation?.invalidate()
        urlObservation = nil
        popupWebView?.removeFromSuperview()
        popupWebView = nil
        loginWebView?.stopLoading()
        loginWebView?.configuration.websiteDataStore.httpCookieStore.remove(self)
        loginWebView = nil
        loginWindowController?.close()
        loginWindowController = nil
    }

    private static func isSessionCookie(_ cookie: HTTPCookie) -> Bool {
        cookie.name == "sessionKey" &&
        (cookie.domain == "claude.ai" || cookie.domain == ".claude.ai" || cookie.domain.hasSuffix(".claude.ai"))
    }

    private func handleCookieCaptured(_ cookie: HTTPCookie) {
        guard !hasCapturedSession else { return }

        guard Self.isSessionCookie(cookie),
              cookie.isSecure,
              cookie.path == "/" else {
            logger.debug("Cookie rejected — name=\(cookie.name) domain=\(cookie.domain) path=\(cookie.path)")
            return
        }

        hasCapturedSession = true
        pendingSessionKey = cookie.value
        pendingExpiration = cookie.expiresDate
        loginState = .signingIn
        cookiePollTimer?.invalidate()
        cookiePollTimer = nil

        logger.info("Session cookie captured via cookie store")

        // Capture ALL cookies from the WebView to include in API requests
        // (Cloudflare, CSRF tokens, etc. may be required alongside sessionKey)
        Task {
            guard let webView = loginWebView else {
                orgDiscoveryTask = Task { await fetchOrganizationId() }
                return
            }
            let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let claudeCookies = allCookies.filter { $0.domain == "claude.ai" || $0.domain == ".claude.ai" || $0.domain.hasSuffix(".claude.ai") }
            let header = claudeCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            pendingCookieHeader = header.isEmpty ? nil : header
            logger.info("Captured \(claudeCookies.count) cookies for API requests")
            orgDiscoveryTask = Task { await fetchOrganizationId() }
        }
    }

    // MARK: - Org Discovery

    private func fetchOrganizationId() async {
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
            let (data, response) = try await ClaudeAPI.session.data(for: request)

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

            logger.info("Found \(orgs.count) organization(s): \(orgs.map(\.uuid).joined(separator: ", "))")

            // Probe each org's usage endpoint to find one that grants access.
            // The first org isn't always the one with a Pro/Max subscription.
            let cookieHeader = pendingCookieHeader
            var validOrgUUID: String?
            for org in orgs {
                guard !Task.isCancelled else { return }
                if let probe = ClaudeAPI.makeRequest(path: "/api/organizations/\(org.uuid)/usage", sessionKey: sessionKey, cookieHeader: cookieHeader) {
                    do {
                        let (_, probeResp) = try await ClaudeAPI.session.data(for: probe)
                        if let httpProbe = probeResp as? HTTPURLResponse {
                            logger.info("Usage probe for org \(org.uuid): HTTP \(httpProbe.statusCode)")
                            if (200...299).contains(httpProbe.statusCode) {
                                validOrgUUID = org.uuid
                                break
                            }
                        }
                    } catch {
                        logger.warning("Usage probe failed for org \(org.uuid): \(error.localizedDescription)")
                    }
                }
            }

            guard let orgUUID = validOrgUUID else {
                logger.warning("No organization with usage access found")
                handleOrgDiscoveryFailure("No organization with usage access.")
                showLoginAlert("No Usage Access", "None of the \(orgs.count) organization(s) on this account have usage data access. A Pro or Max subscription may be required.")
                return
            }

            // Try to extract email from org response
            let email = extractEmail(from: data) ?? "Account \(accountStore.accounts.count + 1)"

            let account = Account(
                email: email,
                sessionKey: sessionKey,
                organizationId: orgUUID,
                sessionKeyExpiration: pendingExpiration,
                allCookieHeader: cookieHeader
            )

            if accountStore.addAccount(account) {
                accountStore.switchTo(account.id)
                logger.info("Account added and activated: \(account.displayName)")
            } else if let existing = accountStore.accounts.first(where: { $0.organizationId == orgUUID }) {
                // Re-authentication: update session key on existing account
                accountStore.updateSessionKey(existing.id, sessionKey, expiration: pendingExpiration, cookieHeader: cookieHeader)
                accountStore.switchTo(existing.id)
                logger.info("Re-authenticated existing account: \(existing.displayName)")
            } else {
                // Org ID changed — remove the stale account and add fresh
                if let stale = accountStore.accounts.first(where: { $0.email == email || $0.email.hasPrefix("Account ") }) {
                    accountStore.removeAccount(stale.id)
                    logger.info("Removed stale account: \(stale.displayName)")
                }
                if accountStore.addAccount(account) {
                    accountStore.switchTo(account.id)
                    logger.info("Account added (replaced stale): \(account.displayName)")
                } else {
                    logger.warning("Failed to add account (limit reached)")
                    handleOrgDiscoveryFailure("Account limit reached.")
                    showLoginAlert("Account Limit", "You can have up to \(AccountStore.maxAccounts) accounts. Remove one in Settings before adding another.")
                    return
                }
            }

            // Success — clean up and close window
            pendingSessionKey = nil
            pendingExpiration = nil
            pendingCookieHeader = nil
            loginState = .idle
            stopLoginWindow()
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Org discovery failed: \(error.localizedDescription)")
            handleOrgDiscoveryFailure("Connection error. Please try again.")
            showLoginAlert("Connection Error", "Could not complete sign-in. Please close this window and try again.")
        }
    }

    private func handleOrgDiscoveryFailure(_ message: String) {
        pendingSessionKey = nil
        pendingExpiration = nil
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

    private func extractEmail(from data: Data) -> String? {
        // Try to extract email from the organizations response, checking multiple possible keys
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = json.first else { return nil }

        let emailKeys = ["email_address", "email", "billing_email", "primary_email"]
        for key in emailKeys {
            if let email = first[key] as? String, !email.isEmpty {
                return email
            }
        }
        // Try nested billing object
        if let billing = first["billing"] as? [String: Any],
           let email = billing["email"] as? String, !email.isEmpty {
            return email
        }
        return nil
    }

    // MARK: - Sign Out

    func signOut(accountId: UUID) {
        accountStore.removeAccount(accountId)
        hasCapturedSession = false
        loginState = .idle
        ClaudeAPI.clearCookies()
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
        ClaudeAPI.clearCookies()
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
        // hasSuffix is acceptable here — false positives only show content, not leak credentials.
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

        // Allow about:blank and about:srcdoc — used by OAuth flows and iframes
        if url.scheme == "about" {
            decisionHandler(.allow)
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            loginWindowController?.window?.title = "Sign in to Claude — \(url.host ?? "")"
        }

        // Check cookies on every page load (immediate check + polling handles the rest)
        checkCookiesFromAllSources(webView)

        // Reset timeout on every navigation — proves user is still actively signing in.
        // Prevents the window from closing while the user checks email for their code.
        loginTimeoutTask?.cancel()
        loginTimeoutTask = Task {
            try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.orgDiscoveryTask?.cancel()
            self.orgDiscoveryTask = nil
            self.loginState = .idle
            self.hasCapturedSession = false
            self.pendingSessionKey = nil
            self.pendingExpiration = nil
            self.stopLoginWindow()
        }
    }
}

// MARK: - WKUIDelegate

extension AuthManager: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Create a real child webview for popups (e.g. Google OAuth).
        // Using the provided `configuration` preserves `window.opener` so the OAuth
        // callback can postMessage back to the parent claude.ai page.
        guard let url = navigationAction.request.url else { return nil }

        if let host = url.host, !isAllowedDomain(host), url.scheme != "about" {
            logger.info("Blocked popup to disallowed domain: \(host)")
            return nil
        }

        let popup = WKWebView(frame: webView.bounds, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        popup.autoresizingMask = [.width, .height]

        // Add popup on top of the parent webview so user can interact with it
        webView.addSubview(popup)
        self.popupWebView = popup

        logger.debug("Created popup webview for: \(url.host ?? url.absoluteString)")
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        // Called when popup's JavaScript executes window.close() after OAuth callback
        if webView == popupWebView {
            logger.debug("Popup webview closed by page")
            popupWebView?.removeFromSuperview()
            popupWebView = nil
        }
    }

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

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window = loginWindowController?.window else {
            completionHandler(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in completionHandler(response == .alertFirstButtonReturn) }
    }
}

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
        // Cancel in-flight org discovery if user closes window
        orgDiscoveryTask?.cancel()
        orgDiscoveryTask = nil

        // Reset auth state so user can try again
        if loginState == .signingIn {
            hasCapturedSession = false
            pendingSessionKey = nil
            pendingExpiration = nil
            pendingCookieHeader = nil
        }
        loginState = .idle

        loginTimeoutTask?.cancel()
        loginTimeoutTask = nil
        cookiePollTimer?.invalidate()
        cookiePollTimer = nil
        urlObservation?.invalidate()
        urlObservation = nil
        popupWebView?.removeFromSuperview()
        popupWebView = nil
        loginWebView?.stopLoading()
        loginWebView?.configuration.websiteDataStore.httpCookieStore.remove(self)
        loginWebView = nil
        loginWindowController = nil
    }
}

// MARK: - Models

struct Organization: Codable {
    let uuid: String
}
