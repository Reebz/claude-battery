import Foundation
import Security
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "Keychain")

final class KeychainService {
    private let service: String

    enum Keys {
        static let sessionKey = "sessionKey"
        static let organizationId = "organizationId"
    }

    init() {
        self.service = Bundle.main.bundleIdentifier ?? "com.claudebattery.app"
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func save(_ value: String, forKey account: String) {
        guard let data = value.data(using: .utf8) else { return }

        var deleteQuery = baseQuery
        deleteQuery[kSecAttrAccount as String] = account
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecAttrAccount as String] = account
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Keychain save failed for \(account): \(status)")
        }
    }

    func read(forKey account: String) -> String? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecInteractionNotAllowed {
            return nil
        }

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                logger.error("Keychain read failed for \(account): \(status)")
            }
            return nil
        }

        return value
    }

    func delete(forKey account: String) {
        var query = baseQuery
        query[kSecAttrAccount as String] = account

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain delete failed for \(account): \(status)")
        }
    }

    func deleteAll() {
        delete(forKey: Keys.sessionKey)
        delete(forKey: Keys.organizationId)
    }
}

// MARK: - Shared API Request Builder

enum ClaudeAPI {
    static let baseURL = "https://claude.ai"

    static func makeRequest(path: String, sessionKey: String) -> URLRequest? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("1.0.0", forHTTPHeaderField: "anthropic-client-version")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue(baseURL, forHTTPHeaderField: "origin")
        request.setValue("\(baseURL)/settings/usage", forHTTPHeaderField: "referer")
        return request
    }
}
