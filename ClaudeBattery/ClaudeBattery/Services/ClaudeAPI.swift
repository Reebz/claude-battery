import Foundation

// MARK: - API Configuration

enum ClaudeAPI {
    static let baseURL = "https://claude.ai"

    /// Safari version token - the only component that changes between releases. Update when shipping.
    private static let safariVersionToken = "Version/18.3"

    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariVersionToken) Safari/605.1.15"

    /// Cookie jar for API requests. Points at `HTTPCookieStorage.shared` because the custom
    /// `HTTPCookieStorage()` init returns a placeholder that does not actually retain cookies
    /// (a long-standing Foundation quirk on macOS). Sharing with the process-wide storage is
    /// safe in practice: `UpdateChecker.session` explicitly nil's out its cookie storage, and
    /// WKWebView uses a non-persistent data store at login time, so nothing else writes to the
    /// shared jar. At account-activation boundaries we call `activateCookies(...)` which wipes
    /// every claude.ai cookie and re-injects from `Account.allCookieHeader`, preventing stale
    /// cookies from a prior account or app run from leaking into the next session.
    private static var cookieStorage: HTTPCookieStorage { .shared }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = cookieStorage
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.urlCredentialStorage = nil
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// Replace any claude.ai cookies in the per-session jar with the provided cookie set.
    /// Call at Account-becomes-active moments (app init, account switch, re-auth) so the jar
    /// reflects the newly-active account's captured cookies. After activation, URLSession
    /// constructs the `Cookie` header automatically and updates the jar from any `Set-Cookie`
    /// responses, preserving Cloudflare `__cf_bm` rotation without further intervention.
    ///
    /// When `cookieHeader` is nil or empty, the jar is primed with just `sessionKey=<sessionKey>`
    /// as a fallback - enough for pre-#7-fix accounts on first load, and enough for unit tests
    /// that do not prime the jar explicitly.
    static func activateCookies(sessionKey: String, cookieHeader: String?) {
        clearClaudeCookies()
        if let cookieHeader, !cookieHeader.isEmpty {
            injectCookies(from: cookieHeader)
        } else {
            injectCookies(from: "sessionKey=\(sessionKey)")
        }
    }

    /// Remove every claude.ai-scoped cookie from the per-session jar.
    /// Used at sign-out and as the first step of `activateCookies`.
    static func clearClaudeCookies() {
        cookieStorage.cookies?.forEach { cookie in
            if cookie.domain == "claude.ai" || cookie.domain == ".claude.ai" || cookie.domain.hasSuffix(".claude.ai") {
                cookieStorage.deleteCookie(cookie)
            }
        }
    }

    /// Parse a `"name1=value1; name2=value2"` cookie header string and insert each pair as an
    /// `HTTPCookie` scoped to `.claude.ai`. Synthesizes a `Set-Cookie` line per pair and parses
    /// it via `HTTPCookie.cookies(withResponseHeaderFields:for:)` - more reliable than the
    /// properties-dict initializer, which silently returns nil for some valid inputs.
    /// Caller is responsible for clearing first if a clean slate is required (see
    /// `activateCookies`).
    private static func injectCookies(from headerString: String) {
        guard let url = URL(string: baseURL) else { return }
        // Split on ";" (not "; ") then trim — bare semicolons without trailing space
        // are valid per RFC 6265 and must not silently drop subsequent cookies.
        for pair in headerString.components(separatedBy: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1]
            guard !name.isEmpty, !value.isEmpty else { continue }
            let setCookieValue = "\(name)=\(value); Domain=.claude.ai; Path=/; Secure"
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": setCookieValue], for: url)
            for cookie in cookies {
                cookieStorage.setCookie(cookie)
            }
        }
    }

    /// Build a request for a claude.ai endpoint. URLSession constructs the `Cookie` header
    /// from the per-session jar on dispatch - do not set one explicitly here, since an
    /// explicit header would suppress the jar's rotation-updated cookies.
    ///
    /// `cookieHeader` is an optional escape hatch for callers that want to prime the jar as
    /// part of the request (e.g., `AuthManager.fetchOrganizationId` right after cookie capture).
    /// Most production callers (e.g., `UsageService.pollUsage`) should pass `nil` and rely on
    /// `ClaudeAPI.activateCookies(...)` having been called at the account-activation boundary.
    static func makeRequest(path: String, sessionKey: String, cookieHeader: String? = nil) -> URLRequest? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }

        // Prime the jar only when the caller explicitly provides a cookieHeader
        // (e.g., AuthManager.fetchOrganizationId right after capture). All other
        // callers rely on activateCookies at account-activation boundaries.
        // Removed the fallback "jar has no sessionKey → re-prime" branch because
        // it caused a TOCTOU: concurrent callers could clobber each other's cookies
        // in the shared HTTPCookieStorage (see ADV-007).
        if let cookieHeader, !cookieHeader.isEmpty {
            activateCookies(sessionKey: sessionKey, cookieHeader: cookieHeader)
        }

        var request = URLRequest(url: url)
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("1.0.0", forHTTPHeaderField: "anthropic-client-version")
        request.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue(baseURL, forHTTPHeaderField: "origin")
        request.setValue("\(baseURL)/settings/usage", forHTTPHeaderField: "referer")
        return request
    }
}
