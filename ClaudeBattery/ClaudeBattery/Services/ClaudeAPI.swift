import Foundation

// MARK: - API Configuration

enum ClaudeAPI {
    static let baseURL = "https://claude.ai"

    /// Safari version token — the only component that changes between releases. Update when shipping.
    private static let safariVersionToken = "Version/18.3"

    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariVersionToken) Safari/605.1.15"

    static let safariUserAgentSuffix = "\(safariVersionToken) Safari/605.1.15"

    /// Cookie storage shared across API requests — preserves Cloudflare and CSRF cookies set by responses.
    private static let cookieStorage = HTTPCookieStorage.shared

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = cookieStorage
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// Inject login cookies into the shared cookie storage so URLSession sends them automatically.
    static func injectCookies(from cookieHeader: String, for baseURLString: String = baseURL) {
        guard URL(string: baseURLString) != nil else { return }
        let pairs = cookieHeader.components(separatedBy: "; ")
        for pair in pairs {
            let parts = pair.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.dropFirst().joined(separator: "=")
            guard !name.isEmpty, !value.isEmpty else { continue }
            if let cookie = HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: ".claude.ai",
                .path: "/",
                .secure: "TRUE",
            ]) {
                cookieStorage.setCookie(cookie)
            }
        }
    }

    /// Clear all claude.ai cookies from the storage (used on sign-out).
    static func clearCookies() {
        guard let url = URL(string: baseURL) else { return }
        cookieStorage.cookies(for: url)?.forEach { cookieStorage.deleteCookie($0) }
    }

    static func makeRequest(path: String, sessionKey: String, cookieHeader: String? = nil) -> URLRequest? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }

        // Ensure login cookies are in the cookie storage
        injectCookies(from: cookieHeader ?? "sessionKey=\(sessionKey)")

        var request = URLRequest(url: url)
        // Don't set Cookie header manually — URLSession merges cookie storage automatically.
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
