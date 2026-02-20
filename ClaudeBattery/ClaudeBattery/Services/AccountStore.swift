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

    private let keychain: KeychainService

    init(keychain: KeychainService) {
        self.keychain = keychain
        self.accounts = keychain.readAccounts()
        self.activeAccountId = keychain.getActiveAccountId()

        // If we have accounts but no active one, select the first
        if activeAccountId == nil, let first = accounts.first {
            activeAccountId = first.id
            keychain.setActiveAccountId(first.id)
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

        logger.info("Added account: \(account.displayName)")
        return true
    }

    func removeAccount(_ id: UUID) {
        accounts.removeAll(where: { $0.id == id })

        if activeAccountId == id {
            activeAccountId = accounts.first?.id
            keychain.setActiveAccountId(activeAccountId)
        }

        persist()
        logger.info("Removed account \(id.uuidString). Remaining: \(self.accounts.count)")
    }

    func switchTo(_ id: UUID) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeAccountId = id
        keychain.setActiveAccountId(id)
        logger.info("Switched to account \(id.uuidString)")
    }

    func updateSessionKey(_ id: UUID, _ sessionKey: String, expiration: Date? = nil) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].sessionKey = sessionKey
        accounts[index].sessionKeyExpiration = expiration
        persist()
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

    // MARK: - Persistence

    private func persist() {
        keychain.saveAccounts(accounts)
    }
}
