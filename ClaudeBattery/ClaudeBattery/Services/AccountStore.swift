import Foundation
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "AccountStore")

@MainActor
class AccountStore: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var activeAccountId: UUID?

    /// One entry per organization, shared across every email. Raised from 5 to 10 so a two-email,
    /// three-org user has room (D5, issue #41). Costs no API traffic: polling only ever runs against
    /// the active entry. The limit message and the store tests both read this constant, so it is the
    /// only place the number lives in code.
    static let maxAccounts = 10

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
        if let cookieHeader, !cookieHeader.isEmpty {
            accounts[index].allCookieHeader = cookieHeader
        } else if let stored = accounts[index].allCookieHeader, !stored.isEmpty {
            // A bare session-key paste (no cookie header) used to leave the stored header holding
            // the DEAD key: `ClaudeAPI.activateCookies` prefers a non-empty header and ignores the
            // sessionKey argument entirely, so the app reported a successful refresh and the next
            // poll failed on the old key (R8, issue #41).
            //
            // Two ways out: clear the stored header so priming falls back to `sessionKey=<fresh>`,
            // or swap the key pair inside the header and keep everything else. Swapping wins,
            // because the cookies sitting next to the key are the Cloudflare ones (`__cf_bm`,
            // `cf_clearance`) and the CSRF token, and a bare key without them is exactly the
            // request shape that gets 403'd (issue #7). Clearing would trade a stale-key failure
            // for a Cloudflare failure. Empty is treated as absent here for the same reason
            // `activateCookies` does: both mean "no header was captured".
            accounts[index].allCookieHeader = Self.headerReplacingSessionKey(in: stored, with: sessionKey)
        }
        persist()
        if activeAccountId == id {
            // Re-prime the cookie jar with the fresh credentials so the next API call uses them.
            ClaudeAPI.activateCookies(sessionKey: sessionKey, cookieHeader: accounts[index].allCookieHeader)
        }
    }

    /// Return `header` with its `sessionKey=` pair carrying `sessionKey`, every other cookie left
    /// as it was. Appends the pair when the header has none, so the result always authenticates.
    /// `nonisolated static` and pure so it is unit-testable without a store, the same shape as
    /// `AuthManager.selectOrg`. Splits on ";" rather than "; " for the RFC 6265 reason spelled out
    /// in `ClaudeAPI.injectCookies`: a bare semicolon is valid and must not swallow the next pair.
    nonisolated static func headerReplacingSessionKey(in header: String, with sessionKey: String) -> String {
        var pairs = header
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var replaced = false
        for i in pairs.indices where pairs[i].hasPrefix("sessionKey=") {
            pairs[i] = "sessionKey=\(sessionKey)"
            replaced = true
        }
        if !replaced {
            pairs.append("sessionKey=\(sessionKey)")
        }
        return pairs.joined(separator: "; ")
    }

    /// Rewrite an account's stored plan from a fresh organizations response. Called on every
    /// re-auth route and not only at add time, because a user can change plan between two sign-ins
    /// and a stale tier would convert the Session dial against capacities the account no longer has
    /// (R4).
    ///
    /// A nil OVERWRITES a stored value rather than being skipped as "no news". Absence is real
    /// information - the plan no longer maps, or the field has gone from the response - and a nil
    /// tier makes the dial show the true session number with no conversion, which is the deliberate
    /// answer whenever the app is unsure (D4). Keeping the old string would keep converting on a
    /// plan we can no longer see.
    ///
    /// No cookie-jar work here, unlike `updateSessionKey`: this writes display fields and touches
    /// no credentials, so it is safe to call in either order around a jar-priming write.
    ///
    /// `billingType` is defaulted because nothing reads it for the dial - it exists so the
    /// diagnostics export can carry it (R6) - and a caller with no organizations response in hand
    /// has no honest value to pass. Every sign-in route has the org and passes it.
    func updatePlan(_ id: UUID, rateLimitTier: String?, capabilities: [String]?, billingType: String? = nil) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        // A CONFIRMED plan change also throws the running measurement away. Those points were spent
        // against capacities the account no longer has, the lifetime totals have no decay to work
        // that out on their own, and the measurement OUTRANKS the tier being written here
        // (`PlanRatio.resolve`), so leaving it would keep the dial converting on the old plan while
        // the freshly corrected tier sat unused - the exact failure this function exists to prevent
        // (R4).
        //
        // Both sides have to be present and different before that counts as a plan change. Nil to a
        // string is the ordinary "we have only just learned the tier" case, which is every account
        // carried over from v1.60, and clearing there would destroy a mature correct measurement.
        // A string to nil is just as likely to mean the field stopped arriving as a real change,
        // and it would wipe every account's measurement at once, taking with it the one thing that
        // still converts the dial when the table cannot (D3).
        if let previous = accounts[index].rateLimitTier,
           let incoming = rateLimitTier,
           previous != incoming {
            accounts[index].ratioMeasurement = nil
        }
        accounts[index].rateLimitTier = rateLimitTier
        accounts[index].capabilities = capabilities
        accounts[index].billingType = billingType
        persist()
    }

    /// Store the account's running capacity measurement (R5). Written on every successful poll,
    /// because the totals are built up over many polls and have to survive a relaunch: a version
    /// that started from nothing each time the app quit would hand a user who quits daily a
    /// measurement that never gets anywhere. That is one small UserDefaults write every two
    /// minutes, but only when the measurement actually moved: `accounts` is `@Published`, so
    /// assigning into it re-encodes the whole account list AND invalidates every view watching the
    /// store, and a poll that returns the same percentages produces a value equal to the stored one
    /// (both totals grow by exactly zero). Issue #11 was CPU burned on redraws nothing asked for,
    /// so a publish with no new information is not worth making. Do not assume this write already
    /// happened anyway: the `updateDidNotify` one it resembles sits behind `checkAndNotify`, which
    /// returns early unless notifications are on, and they are off by default.
    ///
    /// Takes the whole value rather than a delta so the accumulation rules all live in one pure
    /// function (`RatioMeasurement.updated`) that can be tested without a store behind it.
    func updateRatioMeasurement(_ id: UUID, _ measurement: RatioMeasurement) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        guard accounts[index].ratioMeasurement != measurement else { return }
        accounts[index].ratioMeasurement = measurement
        persist()
    }

    /// Rewrite a stored entry's email label. The plain setter, matching `updatePlan` and
    /// `updateNickname`; the rule about WHICH labels may be rewritten lives in
    /// `AuthManager.repairPlaceholderEmail`, because it needs the sign-in that found the address.
    ///
    /// Leaves `nickname` alone. `Account.displayName` is `nickname ?? email`, so an account the user
    /// has renamed keeps showing that name and only the label underneath it changes.
    func updateEmail(_ id: UUID, _ email: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].email = email
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
