import AppKit
import WebKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "Auth")

@MainActor
class AuthManager: NSObject, ObservableObject {
    private let keychain: KeychainService
    private let accountStore: AccountStore
    private var loginWebView: WKWebView?
    private var loginWindowController: NSWindowController?
    private var loginTimeoutTask: Task<Void, Never>?
    private var hasCapturedSession = false
    private var pendingSessionKey: String?

    private static let sessionExpirationKey = "sessionKeyExpiration"

    init(keychain: KeychainService, accountStore: AccountStore) {
        self.keychain = keychain
        self.accountStore = accountStore
        super.init()
    }

    // MARK: - Login

    func presentLogin() {
        guard loginWindowController == nil else {
            loginWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: config)
        webView.navigationDelegate = self
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

        if let url = URL(string: "https://claude.ai/login") {
            webView.load(URLRequest(url: url))
        }
    }

    private func handleCookieCaptured(_ cookie: HTTPCookie) {
        guard !hasCapturedSession else { return }

        guard cookie.domain == "claude.ai" || cookie.domain == ".claude.ai",
              cookie.isSecure,
              cookie.path == "/" else {
            logger.info("Cookie rejected — domain=\(cookie.domain)")
            return
        }

        hasCapturedSession = true
        pendingSessionKey = cookie.value

        if let expiresDate = cookie.expiresDate {
            UserDefaults.standard.set(expiresDate, forKey: Self.sessionExpirationKey)
        }

        logger.info("Session cookie captured")

        loginTimeoutTask?.cancel()
        loginTimeoutTask = nil

        loginWebView?.stopLoading()
        loginWebView?.configuration.websiteDataStore.httpCookieStore.remove(self)

        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { [weak self] in
            Task { @MainActor in
                self?.loginWebView = nil
                self?.loginWindowController?.close()
                self?.loginWindowController = nil
                await self?.fetchOrganizationId()
            }
        }
    }

    // MARK: - Org Discovery

    private func fetchOrganizationId() async {
        guard let sessionKey = pendingSessionKey else { return }

        guard let request = ClaudeAPI.makeRequest(path: "/api/organizations", sessionKey: sessionKey) else {
            logger.error("Failed to construct organizations API URL")
            return
        }

        do {
            let (data, response) = try await ClaudeAPI.session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Non-HTTP response from organizations API")
                return
            }

            logger.info("Org discovery HTTP \(httpResponse.statusCode)")

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                let body = String(data: data, encoding: .utf8) ?? "(non-utf8)"
                logger.warning("Auth failure during org discovery (HTTP \(httpResponse.statusCode)): \(body.prefix(500))")
                pendingSessionKey = nil
                hasCapturedSession = false
                return
            }

            #if DEBUG
            let rawBody = String(data: data, encoding: .utf8) ?? "(non-utf8)"
            logger.debug("Org discovery response: \(rawBody.prefix(1000))")
            #endif

            let orgs = try JSONDecoder().decode([Organization].self, from: data)

            if orgs.isEmpty {
                logger.info("No organizations found — user may not have Pro/Max subscription")
                pendingSessionKey = nil
                hasCapturedSession = false
                return
            }

            // Try to extract email from org response
            let email = extractEmail(from: data) ?? "Account \(accountStore.accounts.count + 1)"

            let account = Account(
                email: email,
                sessionKey: sessionKey,
                organizationId: orgs[0].uuid
            )

            if accountStore.addAccount(account) {
                accountStore.switchTo(account.id)
                logger.info("Account added and activated: \(account.displayName)")
            } else {
                logger.warning("Failed to add account (duplicate or limit reached)")
            }

            pendingSessionKey = nil
        } catch {
            logger.error("Org discovery failed: \(error.localizedDescription)")
            pendingSessionKey = nil
            hasCapturedSession = false
        }
    }

    private func extractEmail(from data: Data) -> String? {
        // Try to extract email from the organizations response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = json.first,
              let email = first["email_address"] as? String, !email.isEmpty else {
            return nil
        }
        return email
    }

    // MARK: - Sign Out

    func signOut(accountId: UUID) {
        accountStore.removeAccount(accountId)
        hasCapturedSession = false
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
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { }
        logger.info("Signed out all accounts")
    }

    func handleAuthFailure() {
        // Mark the active account as failed — user switches manually
        hasCapturedSession = false
        logger.info("Auth failure for active account")
    }

    // MARK: - Allowed Domains

    private func isAllowedDomain(_ host: String) -> Bool {
        host == "claude.ai" ||
        host.hasSuffix(".claude.ai") ||
        host.hasSuffix(".anthropic.com") ||
        host == "accounts.google.com" ||
        host == "appleid.apple.com" ||
        host.hasSuffix(".challenges.cloudflare.com")
    }
}

// MARK: - WKNavigationDelegate

extension AuthManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let host = url.host else {
            decisionHandler(.cancel)
            return
        }

        if isAllowedDomain(host) {
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

        Task {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            if let sessionCookie = cookies.first(where: {
                $0.name == "sessionKey" && ($0.domain == "claude.ai" || $0.domain == ".claude.ai")
            }) {
                handleCookieCaptured(sessionCookie)
                return
            }
        }

        if loginTimeoutTask == nil {
            loginTimeoutTask = Task {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                loginWebView?.stopLoading()
                loginWebView?.configuration.websiteDataStore.httpCookieStore.remove(self)
                loginWebView = nil
                loginWindowController?.close()
                loginWindowController = nil
            }
        }
    }
}

// MARK: - WKHTTPCookieStoreObserver

extension AuthManager: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            let cookies = await cookieStore.allCookies()
            if let sessionCookie = cookies.first(where: {
                $0.name == "sessionKey" && ($0.domain == "claude.ai" || $0.domain == ".claude.ai")
            }) {
                self?.handleCookieCaptured(sessionCookie)
            }
        }
    }
}

// MARK: - NSWindowDelegate

extension AuthManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        loginTimeoutTask?.cancel()
        loginTimeoutTask = nil
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
