import Foundation
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "AccountStore")

@MainActor
class AccountStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var activeAccountId: UUID?

    static let maxAccounts = 5

    var activeAccount: Account? {
        guard let id = activeAccountId else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    var isAuthenticated: Bool {
        activeAccount != nil
    }

    var canAddAccount: Bool {
        accounts.count < Self.maxAccounts
    }

    private let storage: StorageService

    init(storage: StorageService) {
        self.storage = storage
        self.accounts = storage.readAccounts()
        self.activeAccountId = storage.getActiveAccountId()

        // If we have accounts but no active one, select the first
        if activeAccountId == nil, let first = accounts.first {
            activeAccountId = first.id
            storage.setActiveAccountId(first.id)
        }

        // Prime the ClaudeAPI cookie jar from the active account's captured cookies.
        // Runs at app launch so the first /usage poll after boot carries the full cookie set
        // (sessionKey + Cloudflare __cf_bm etc.), not sessionKey alone.
        if let active = activeAccount {
            ClaudeAPI.activateCookies(sessionKey: active.sessionKey, cookieHeader: active.allCookieHeader)
        }
    }

    // MARK: - Mutations

    func addAccount(_ account: Account) -> Bool {
        guard accounts.count < Self.maxAccounts else {
            logger.warning("Cannot add account — limit of \(Self.maxAccounts) reached")
            return false
        }

        // Check for duplicate organizationId
        if accounts.contains(where: { $0.organizationId == account.organizationId }) {
            logger.warning("Cannot add account — duplicate organizationId: \(account.organizationId)")
            return false
        }

        accounts.append(account)
        persist()

        // If this is the first account, make it active
        if accounts.count == 1 {
            switchTo(account.id)
        }

        // Non-PII id, not displayName (= email when no nickname); os_log can be read off-device,
        // so never emit an email here.
        logger.info("Added account: \(account.id.uuidString)")
        return true
    }

    func removeAccount(_ id: UUID) {
        let wasActive = (activeAccountId == id)
        accounts.removeAll(where: { $0.id == id })

        if wasActive {
            activeAccountId = accounts.first?.id
            storage.setActiveAccountId(activeAccountId)
            if let newActive = activeAccount {
                ClaudeAPI.activateCookies(sessionKey: newActive.sessionKey, cookieHeader: newActive.allCookieHeader)
            } else {
                ClaudeAPI.clearClaudeCookies()
            }
        }

        persist()
        logger.info("Removed account \(id.uuidString). Remaining: \(self.accounts.count)")
    }

    func switchTo(_ id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        activeAccountId = id
        storage.setActiveAccountId(id)
        ClaudeAPI.activateCookies(sessionKey: account.sessionKey, cookieHeader: account.allCookieHeader)
        logger.info("Switched to account \(id.uuidString)")
    }

    func updateSessionKey(_ id: UUID, _ sessionKey: String, cookieHeader: String? = nil) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].sessionKey = sessionKey
        if let cookieHeader {
            accounts[index].allCookieHeader = cookieHeader
        }
        persist()
        if activeAccountId == id {
            // Re-prime the cookie jar with the fresh credentials so the next API call uses them.
            ClaudeAPI.activateCookies(sessionKey: sessionKey, cookieHeader: accounts[index].allCookieHeader)
        }
    }

    func updateNickname(_ id: UUID, _ nickname: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = String(nickname.trimmingCharacters(in: .whitespaces).prefix(30))
        accounts[index].nickname = trimmed.isEmpty ? nil : trimmed
        persist()
    }

    func updateDidNotify(_ id: UUID, _ value: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].didNotifyBelowThreshold = value
        persist()
    }

    func updateThreshold(_ id: UUID, _ threshold: Double) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].notificationThreshold = threshold
        persist()
    }

    // MARK: - Display

    /// Name to show for an account, disambiguated by org name ONLY when another stored account
    /// shares the same email (two orgs of one Claude account — issue #32). A nickname always wins.
    /// Single-org accounts, unique-email accounts, and accounts with no stored org name render
    /// exactly as `Account.displayName` (nickname ?? email), so existing users see no change.
    func disambiguatedName(for account: Account) -> String {
        if let nickname = account.nickname, !nickname.isEmpty {
            return nickname
        }
        let sharesEmail = accounts.contains { $0.id != account.id && $0.email == account.email }
        if sharesEmail, let orgName = account.organizationName, !orgName.isEmpty {
            return "\(account.email) (\(orgName))"
        }
        return account.displayName
    }

    // MARK: - Persistence

    private func persist() {
        storage.saveAccounts(accounts)
    }
}
