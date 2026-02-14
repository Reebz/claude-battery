import AppKit
import WebKit
import Combine

@MainActor
class AuthManager: NSObject, ObservableObject {
    @Published var isAuthenticated: Bool = false

    private let keychain: KeychainService
    private var loginWebView: WKWebView?
    private var loginWindowController: NSWindowController?
    private var loginTimeoutTask: Task<Void, Never>?

    init(keychain: KeychainService) {
        self.keychain = keychain
        super.init()

        // Check for existing credentials on launch
        if keychain.read(forKey: "sessionKey") != nil,
           keychain.read(forKey: "organizationId") != nil {
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

        // Register cookie observer before navigation
        config.websiteDataStore.httpCookieStore.add(self)

        // Prime cookie store
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
        // Validate cookie attributes
        guard cookie.domain.hasSuffix("claude.ai"),
              cookie.isSecure,
              cookie.path == "/" else { return }

        keychain.save(cookie.value, forKey: "sessionKey")

        loginTimeoutTask?.cancel()
        loginTimeoutTask = nil

        loginWebView?.stopLoading()
        loginWebView?.configuration.websiteDataStore.httpCookieStore.remove(self)

        // Clear data store immediately
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { [weak self] in
            Task { @MainActor in
                self?.loginWebView = nil
                self?.loginWindowController?.close()
                self?.loginWindowController = nil

                // Discover org ID
                await self?.fetchOrganizationId()
            }
        }
    }

    // MARK: - Org Discovery

    private func fetchOrganizationId() async {
        guard let sessionKey = keychain.read(forKey: "sessionKey") else { return }

        let url = URL(string: "https://claude.ai/api/organizations")!
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("1.0.0", forHTTPHeaderField: "anthropic-client-version")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                handleAuthFailure()
                return
            }

            let orgs = try JSONDecoder().decode([Organization].self, from: data)

            if orgs.isEmpty {
                // No Pro/Max subscription
                isAuthenticated = false
                return
            }

            keychain.save(orgs[0].uuid, forKey: "organizationId")
            isAuthenticated = true
        } catch {
            // Network or decode error — don't set authenticated
        }
    }

    // MARK: - Sign Out

    func signOut() async {
        keychain.deleteAll()

        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }

        isAuthenticated = false
    }

    func handleAuthFailure() {
        keychain.deleteAll()
        isAuthenticated = false
    }

    // MARK: - Allowed Domains

    private func isAllowedDomain(_ host: String) -> Bool {
        host == "claude.ai" ||
        host.hasSuffix(".claude.ai") ||
        host.hasSuffix(".google.com") ||
        host.hasSuffix(".apple.com") ||
        host.hasSuffix(".cloudflare.com")
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
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Update window title with current URL
        if let url = webView.url {
            loginWindowController?.window?.title = "Sign in to Claude — \(url.host ?? "")"
        }

        // Fallback cookie check on every navigation finish
        Task {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            for cookie in cookies where cookie.name == "sessionKey" {
                handleCookieCaptured(cookie)
                return
            }
        }

        // Start timeout timer on first navigation
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
