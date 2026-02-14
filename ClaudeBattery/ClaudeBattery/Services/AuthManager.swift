import AppKit
import WebKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "Auth")

@MainActor
class AuthManager: NSObject, ObservableObject {
    @Published var isAuthenticated: Bool = false

    private let keychain: KeychainService
    private var loginWebView: WKWebView?
    private var loginWindowController: NSWindowController?
    private var loginTimeoutTask: Task<Void, Never>?

    private static let sessionExpirationKey = "sessionKeyExpiration"

    private lazy var apiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    init(keychain: KeychainService) {
        self.keychain = keychain
        super.init()

        if keychain.read(forKey: KeychainService.Keys.sessionKey) != nil,
           keychain.read(forKey: KeychainService.Keys.organizationId) != nil {
            isAuthenticated = true
        }
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
        guard cookie.domain.hasSuffix("claude.ai"),
              cookie.isSecure,
              cookie.path == "/" else { return }

        keychain.save(cookie.value, forKey: KeychainService.Keys.sessionKey)

        // Store cookie expiration for proactive session management
        if let expiresDate = cookie.expiresDate {
            UserDefaults.standard.set(expiresDate, forKey: Self.sessionExpirationKey)
        }

        logger.info("Session cookie captured successfully")

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
        guard let sessionKey = keychain.read(forKey: KeychainService.Keys.sessionKey) else { return }

        guard let request = ClaudeAPI.makeRequest(path: "/api/organizations", sessionKey: sessionKey) else {
            logger.error("Failed to construct organizations API URL")
            return
        }

        do {
            let (data, response) = try await apiSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Non-HTTP response from organizations API")
                return
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                logger.warning("Auth failure during org discovery (HTTP \(httpResponse.statusCode))")
                handleAuthFailure()
                return
            }

            let orgs = try JSONDecoder().decode([Organization].self, from: data)

            if orgs.isEmpty {
                logger.info("No organizations found — user may not have Pro/Max subscription")
                isAuthenticated = false
                return
            }

            keychain.save(orgs[0].uuid, forKey: KeychainService.Keys.organizationId)
            isAuthenticated = true
            logger.info("Organization discovered successfully")
        } catch {
            logger.error("Org discovery failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Sign Out

    func signOut() {
        keychain.deleteAll()
        UserDefaults.standard.removeObject(forKey: Self.sessionExpirationKey)
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { }
        isAuthenticated = false
        logger.info("Signed out")
    }

    func handleAuthFailure() {
        keychain.deleteAll()
        UserDefaults.standard.removeObject(forKey: Self.sessionExpirationKey)
        isAuthenticated = false
        logger.info("Auth failure — credentials cleared")
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
            for cookie in cookies where cookie.name == "sessionKey" {
                handleCookieCaptured(cookie)
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
            for cookie in cookies where cookie.name == "sessionKey" {
                self?.handleCookieCaptured(cookie)
                return
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
