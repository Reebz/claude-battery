import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "Storage")

// MARK: - Account Model

struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var email: String
    var sessionKey: String
    var organizationId: String
    var nickname: String?
    let addedDate: Date
    var notificationThreshold: Double
    var didNotifyBelowThreshold: Bool
    var sessionKeyExpiration: Date?
    /// Full cookie header captured from the login WebView (e.g. "sessionKey=abc; __cf_bm=xyz; ...")
    var allCookieHeader: String?

    var displayName: String {
        nickname ?? email
    }

    /// The Cookie header value to use for API requests.
    /// Prefers the full captured cookie header; falls back to just sessionKey.
    var cookieHeaderValue: String {
        allCookieHeader ?? "sessionKey=\(sessionKey)"
    }

    init(id: UUID = UUID(), email: String, sessionKey: String, organizationId: String, nickname: String? = nil, addedDate: Date = Date(), notificationThreshold: Double = 20.0, didNotifyBelowThreshold: Bool = false, sessionKeyExpiration: Date? = nil, allCookieHeader: String? = nil) {
        self.id = id
        self.email = email
        self.sessionKey = sessionKey
        self.organizationId = organizationId
        self.nickname = nickname
        self.addedDate = addedDate
        self.notificationThreshold = notificationThreshold
        self.didNotifyBelowThreshold = didNotifyBelowThreshold
        self.sessionKeyExpiration = sessionKeyExpiration
        self.allCookieHeader = allCookieHeader
    }
}

// MARK: - Storage

final class StorageService {
    private let defaults = UserDefaults.standard
    private let prefix: String

    enum Keys {
        static let sessionKey = "sessionKey"
        static let organizationId = "organizationId"
        static let accounts = "accounts"
        static let activeAccountId = "activeAccountId"
        static let migrated = "migrated"
    }

    init() {
        self.prefix = "cb_"
        migrateIfNeeded()
    }

    // MARK: - Legacy single-value access

    func save(_ value: String, forKey key: String) {
        defaults.set(value, forKey: prefix + key)
    }

    func read(forKey key: String) -> String? {
        defaults.string(forKey: prefix + key)
    }

    func delete(forKey key: String) {
        defaults.removeObject(forKey: prefix + key)
    }

    func deleteAll() {
        delete(forKey: Keys.sessionKey)
        delete(forKey: Keys.organizationId)
    }

    // MARK: - Multi-Account Storage

    func saveAccounts(_ accounts: [Account]) {
        guard let data = try? JSONEncoder().encode(accounts) else {
            logger.error("Failed to encode accounts")
            return
        }
        defaults.set(data, forKey: prefix + Keys.accounts)
    }

    func readAccounts() -> [Account] {
        guard let data = defaults.data(forKey: prefix + Keys.accounts) else { return [] }
        guard let accounts = try? JSONDecoder().decode([Account].self, from: data) else {
            logger.error("Failed to decode accounts")
            return []
        }
        return accounts
    }

    func getActiveAccountId() -> UUID? {
        guard let str = defaults.string(forKey: prefix + Keys.activeAccountId) else { return nil }
        return UUID(uuidString: str)
    }

    func setActiveAccountId(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: prefix + Keys.activeAccountId)
        } else {
            defaults.removeObject(forKey: prefix + Keys.activeAccountId)
        }
    }

    // MARK: - Migration

    private func migrateIfNeeded() {
        guard !defaults.bool(forKey: prefix + Keys.migrated) else { return }

        guard let sessionKey = read(forKey: Keys.sessionKey),
              let orgId = read(forKey: Keys.organizationId) else {
            // No existing credentials — mark as migrated (fresh install)
            defaults.set(true, forKey: prefix + Keys.migrated)
            return
        }

        let account = Account(
            email: "Account 1",
            sessionKey: sessionKey,
            organizationId: orgId
        )

        // Write new format first
        saveAccounts([account])
        setActiveAccountId(account.id)

        // Verify it reads back
        let verified = readAccounts()
        guard verified.count == 1, verified[0].sessionKey == sessionKey else {
            logger.error("Migration verification failed — keeping old keys")
            return
        }

        // Delete old keys and mark migrated
        delete(forKey: Keys.sessionKey)
        delete(forKey: Keys.organizationId)
        defaults.set(true, forKey: prefix + Keys.migrated)
        logger.info("Migrated single account to multi-account format")
    }
}
