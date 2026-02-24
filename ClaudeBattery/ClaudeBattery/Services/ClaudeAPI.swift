import Foundation

// MARK: - API Configuration

enum ClaudeAPI {
    static let baseURL = "https://claude.ai"

    /// Safari version token — the only component that changes between releases. Update when shipping.
    private static let safariVersionToken = "Version/18.3"

    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(safariVersionToken) Safari/605.1.15"

    static let safariUserAgentSuffix = "\(safariVersionToken) Safari/605.1.15"

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    static func makeRequest(path: String, sessionKey: String) -> URLRequest? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
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
