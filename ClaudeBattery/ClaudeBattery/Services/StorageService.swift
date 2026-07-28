import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "Storage")

// MARK: - Account Model

struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var email: String
    var sessionKey: String
    var organizationId: String
    /// The org's display name, captured at add time (sanitized like `Organization.displayName`).
    /// Used only to disambiguate two orgs of the SAME account in the UI. Optional and additive:
    /// accounts persisted before issue #32 decode this as nil and render by email as before.
    var organizationName: String?
    /// The org's plan, captured from `rate_limit_tier` on the organizations response and refreshed
    /// on every re-auth, since a user can change plan between sign-ins. The Session dial converts a
    /// weekly remainder into session units with the ratio this maps to (R4). Optional and additive
    /// like `organizationName`: accounts persisted before this release decode it as nil, and nil
    /// means no conversion happens and the true session number is shown.
    var rateLimitTier: String?
    /// The org's `capabilities`, captured and refreshed alongside `rateLimitTier`. Carried for the
    /// diagnostics export and because Free is identified by the absence of "claude_pro"/"claude_max"
    /// here rather than by any positive marker.
    var capabilities: [String]?
    /// The org's `billing_type`, e.g. "stripe_subscription" or "prepaid", captured and refreshed
    /// alongside `rateLimitTier`. It cannot identify a plan on its own - two different plans can
    /// share one payment method - so nothing reads it for the dial. It is stored so the diagnostics
    /// export can carry it (R6): when a reporter comes back with a `rate_limit_tier` string we have
    /// never seen, how their org pays is one of the few things that helps place it.
    var billingType: String?
    /// The account's running capacity measurement (R5): how many session and weekly points it has
    /// actually consumed, which is what its REAL ratio is derived from. Once that measurement is
    /// trustworthy it overrides the unvalidated `PlanRatio` table for this account (D3). Optional
    /// and additive like `organizationName` and `rateLimitTier`: an account persisted before this
    /// release decodes it as nil and simply starts measuring at its next poll.
    var ratioMeasurement: RatioMeasurement?
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

    init(id: UUID = UUID(), email: String, sessionKey: String, organizationId: String, organizationName: String? = nil, rateLimitTier: String? = nil, capabilities: [String]? = nil, billingType: String? = nil, ratioMeasurement: RatioMeasurement? = nil, nickname: String? = nil, addedDate: Date = Date(), notificationThreshold: Double = 20.0, didNotifyBelowThreshold: Bool = false, allCookieHeader: String? = nil) {
        self.id = id
        self.email = email
        self.sessionKey = sessionKey
        self.organizationId = organizationId
        self.organizationName = organizationName
        self.rateLimitTier = rateLimitTier
        self.capabilities = capabilities
        self.billingType = billingType
        self.ratioMeasurement = ratioMeasurement
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
