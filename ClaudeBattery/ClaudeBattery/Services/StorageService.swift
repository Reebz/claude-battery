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
    /// Full `.claude.ai` Cookie header captured from the login WebView at login time.
    /// Format: "name1=value1; name2=value2; ...". Primes `ClaudeAPI`'s per-session cookie
    /// jar when this account becomes active, so authenticated API requests carry the
    /// full cookie set (including Cloudflare `__cf_bm`) rather than `sessionKey` alone.
    /// Nil for accounts migrated from pre-#7-fix builds; those fall back to sessionKey-only.
    var allCookieHeader: String?

    var displayName: String {
        nickname ?? email
    }

    init(id: UUID = UUID(), email: String, sessionKey: String, organizationId: String, nickname: String? = nil, addedDate: Date = Date(), notificationThreshold: Double = 20.0, didNotifyBelowThreshold: Bool = false, allCookieHeader: String? = nil) {
        self.id = id
        self.email = email
        self.sessionKey = sessionKey
        self.organizationId = organizationId
        self.nickname = nickname
        self.addedDate = addedDate
        self.notificationThreshold = notificationThreshold
        self.didNotifyBelowThreshold = didNotifyBelowThreshold
        self.allCookieHeader = allCookieHeader
    }
}

// MARK: - Storage

final class StorageService {
    private let defaults: UserDefaults
    private let prefix: String

    enum Keys {
        static let sessionKey = "sessionKey"
        static let organizationId = "organizationId"
        static let accounts = "accounts"
        static let activeAccountId = "activeAccountId"
        static let migrated = "migrated"
        static let prepaidHistoryPrefix = "prepaidHistory."
    }

    /// One entry per calendar day per account. `date` is the start-of-day boundary
    /// in the writer's current calendar; `maxDollars` is the highest balance observed
    /// during that day. Window trimmed to 100 days on every write.
    struct PrepaidHistoryEntry: Codable, Equatable {
        let date: Date
        let maxDollars: Double
    }

    init(defaults: UserDefaults = .standard, prefix: String = "cb_") {
        self.defaults = defaults
        self.prefix = prefix
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

    // MARK: - Prepaid Balance History

    /// Records an observed prepaid balance. Coalesces same-day observations to the day's
    /// max, appends a new entry for a new day, then trims entries older than 100 days.
    /// `@MainActor` isolated so the read-modify-write does not race when multiple
    /// accounts poll concurrently.
    @MainActor
    func recordPrepaidObservation(accountId: UUID, balance: Double, observedAt: Date = Date()) {
        guard balance >= 0 else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: observedAt)
        guard let cutoff = calendar.date(byAdding: .day, value: -100, to: today) else { return }

        var entries = readPrepaidHistory(accountId: accountId)
        entries.removeAll { $0.date < cutoff }

        if let lastIdx = entries.indices.last, entries[lastIdx].date == today {
            if balance > entries[lastIdx].maxDollars {
                entries[lastIdx] = PrepaidHistoryEntry(date: today, maxDollars: balance)
            }
        } else {
            entries.append(PrepaidHistoryEntry(date: today, maxDollars: balance))
        }

        writePrepaidHistory(accountId: accountId, entries: entries)
    }

    /// Returns the highest observed balance within the 100-day window, or nil if no
    /// observations have been recorded for the account.
    @MainActor
    func prepaidHighWaterMark(accountId: UUID) -> Double? {
        let entries = readPrepaidHistory(accountId: accountId)
        return entries.map { $0.maxDollars }.max()
    }

    private func prepaidHistoryStorageKey(accountId: UUID) -> String {
        prefix + Keys.prepaidHistoryPrefix + accountId.uuidString
    }

    private func readPrepaidHistory(accountId: UUID) -> [PrepaidHistoryEntry] {
        guard let data = defaults.data(forKey: prepaidHistoryStorageKey(accountId: accountId)) else { return [] }
        guard let entries = try? JSONDecoder().decode([PrepaidHistoryEntry].self, from: data) else {
            logger.error("Failed to decode prepaid history for \(accountId)")
            return []
        }
        return entries
    }

    private func writePrepaidHistory(accountId: UUID, entries: [PrepaidHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            logger.error("Failed to encode prepaid history for \(accountId)")
            return
        }
        defaults.set(data, forKey: prepaidHistoryStorageKey(accountId: accountId))
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
