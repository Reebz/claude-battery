import Combine
import XCTest
@testable import ClaudeBattery

final class AccountStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.AccountStore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        // addAccount/switchTo/updateSessionKey all prime the process-wide shared cookie jar, and
        // the R8 tests below read it back, so start and end every test with a clean jar (same
        // discipline as AuthManagerTests and ClaudeAPITests).
        ClaudeAPI.clearClaudeCookies()
    }

    override func tearDown() {
        ClaudeAPI.clearClaudeCookies()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStorage() -> StorageService {
        StorageService(defaults: defaults, prefix: "cb_")
    }

    private func makeAccount(
        id: UUID = UUID(),
        email: String = "test@example.com",
        sessionKey: String = "sk-test-123",
        organizationId: String = "org-abc"
    ) -> Account {
        Account(id: id, email: email, sessionKey: sessionKey, organizationId: organizationId)
    }

    // MARK: - Happy Path: addAccount

    @MainActor
    func testAddAccountAppendsToAccounts() {
        let store = AccountStore(storage: makeStorage())
        let account = makeAccount()

        let result = store.addAccount(account)

        XCTAssertTrue(result)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first, account)
    }

    // MARK: - Happy Path: addAccount sets active on first account

    @MainActor
    func testAddFirstAccountSetsActive() {
        let store = AccountStore(storage: makeStorage())
        let account = makeAccount()

        _ = store.addAccount(account)

        XCTAssertEqual(store.activeAccountId, account.id)
        XCTAssertEqual(store.activeAccount, account)
    }

    // MARK: - Happy Path: switchTo

    @MainActor
    func testSwitchToChangesActiveAccountId() {
        let store = AccountStore(storage: makeStorage())
        let first = makeAccount(organizationId: "org-1")
        let second = makeAccount(organizationId: "org-2")

        _ = store.addAccount(first)
        _ = store.addAccount(second)

        store.switchTo(second.id)

        XCTAssertEqual(store.activeAccountId, second.id)
        XCTAssertEqual(store.activeAccount, second)
    }

    // MARK: - Happy Path: removeAccount falls back to first

    @MainActor
    func testRemoveActiveAccountFallsBackToFirst() {
        let store = AccountStore(storage: makeStorage())
        let first = makeAccount(organizationId: "org-1")
        let second = makeAccount(organizationId: "org-2")

        _ = store.addAccount(first)
        _ = store.addAccount(second)
        store.switchTo(second.id)

        store.removeAccount(second.id)

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.activeAccountId, first.id)
    }

    // MARK: - Happy Path: updateSessionKey

    @MainActor
    func testUpdateSessionKeyChangesAccountKey() {
        let store = AccountStore(storage: makeStorage())
        let account = makeAccount()

        _ = store.addAccount(account)
        store.updateSessionKey(account.id, "sk-new-key-456")

        XCTAssertEqual(store.accounts.first?.sessionKey, "sk-new-key-456")
    }

    // MARK: - Edge Case: addAccount at max capacity

    @MainActor
    func testAddAccountAtMaxCapacityReturnsFalse() {
        let store = AccountStore(storage: makeStorage())

        for i in 0..<AccountStore.maxAccounts {
            let account = makeAccount(organizationId: "org-\(i)")
            let added = store.addAccount(account)
            XCTAssertTrue(added, "Account \(i) should be added successfully")
        }

        XCTAssertEqual(store.accounts.count, AccountStore.maxAccounts)

        let overflow = makeAccount(organizationId: "org-overflow")
        let result = store.addAccount(overflow)

        XCTAssertFalse(result)
        XCTAssertEqual(store.accounts.count, AccountStore.maxAccounts)
    }

    // MARK: - Entry limit is ten (R7 / AE6, issue #41)
    // The test above reads AccountStore.maxAccounts, so it stays green at any limit. These two
    // assert the NUMBER, with literals, because R7 is about the number: ten, not five. The Settings
    // status line interpolates the same constant ("You can have up to N accounts."), so pinning the
    // constant is what pins the message the user reads (there are no view-body tests here, KTD9).

    @MainActor
    func testEleventhAccountIsRefusedAndTheLimitIsTen() {
        let store = AccountStore(storage: makeStorage())

        XCTAssertEqual(AccountStore.maxAccounts, 10, "the limit message names this number")

        for i in 0..<10 {
            XCTAssertTrue(store.addAccount(makeAccount(organizationId: "org-\(i)")), "account \(i) fits")
        }

        let eleventh = store.addAccount(makeAccount(organizationId: "org-eleventh"))

        XCTAssertFalse(eleventh, "the eleventh entry is refused")
        XCTAssertEqual(store.accounts.count, 10, "and nothing was stored by the refusal")
    }

    @MainActor
    func testTenthAccountIsAccepted() {
        let store = AccountStore(storage: makeStorage())

        for i in 0..<9 {
            XCTAssertTrue(store.addAccount(makeAccount(organizationId: "org-\(i)")))
        }

        let tenth = store.addAccount(makeAccount(organizationId: "org-tenth"))

        XCTAssertTrue(tenth, "ten is the limit, so the tenth entry is inside it, not over it")
        XCTAssertEqual(store.accounts.count, 10)
    }

    // MARK: - Edge Case: addAccount with duplicate organizationId

    @MainActor
    func testAddAccountWithDuplicateOrgIdReturnsFalse() {
        let store = AccountStore(storage: makeStorage())
        let first = makeAccount(organizationId: "org-dup")
        let duplicate = makeAccount(organizationId: "org-dup")

        let added = store.addAccount(first)
        XCTAssertTrue(added)

        let rejected = store.addAccount(duplicate)
        XCTAssertFalse(rejected)
        XCTAssertEqual(store.accounts.count, 1)
    }

    // MARK: - Edge Case: removeAccount last account clears activeAccountId

    @MainActor
    func testRemoveLastAccountClearsActiveId() {
        let store = AccountStore(storage: makeStorage())
        let account = makeAccount()

        _ = store.addAccount(account)
        XCTAssertNotNil(store.activeAccountId)

        store.removeAccount(account.id)

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.activeAccountId)
        XCTAssertNil(store.activeAccount)
        XCTAssertFalse(store.isAuthenticated)
    }

    // MARK: - Edge Case: switchTo with non-existent ID

    @MainActor
    func testSwitchToNonExistentIdNoChange() {
        let store = AccountStore(storage: makeStorage())
        let account = makeAccount()

        _ = store.addAccount(account)
        let bogusId = UUID()

        store.switchTo(bogusId)

        XCTAssertEqual(store.activeAccountId, account.id, "Active ID should not change for non-existent ID")
    }

    // MARK: - Persistence: accounts survive re-init

    @MainActor
    func testAccountsPersistAcrossStorageReInit() {
        let storage = makeStorage()
        let store = AccountStore(storage: storage)
        let account = makeAccount()

        _ = store.addAccount(account)

        // Create a new AccountStore with the same underlying storage
        let store2 = AccountStore(storage: storage)

        XCTAssertEqual(store2.accounts.count, 1)
        XCTAssertEqual(store2.accounts.first, account)
        XCTAssertEqual(store2.activeAccountId, account.id)
    }

    // MARK: - Display: disambiguatedName (issue #32 — two orgs of the same account)

    @MainActor
    func testDisambiguatedName_uniqueEmailShowsEmail() {
        let store = AccountStore(storage: makeStorage())
        let a = Account(email: "solo@x.com", sessionKey: "sk", organizationId: "org-1", organizationName: "Acme")
        _ = store.addAccount(a)
        XCTAssertEqual(store.disambiguatedName(for: a), "solo@x.com",
                       "a unique email renders plainly even when an org name exists")
    }

    @MainActor
    func testDisambiguatedName_sameEmailAppendsOrgName() {
        let store = AccountStore(storage: makeStorage())
        let a = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-a", organizationName: "Acme")
        let b = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-b", organizationName: "Beta")
        _ = store.addAccount(a)
        _ = store.addAccount(b)
        XCTAssertEqual(store.disambiguatedName(for: a), "me@x.com (Acme)")
        XCTAssertEqual(store.disambiguatedName(for: b), "me@x.com (Beta)")
    }

    @MainActor
    func testDisambiguatedName_nicknameAlwaysWins() {
        let store = AccountStore(storage: makeStorage())
        let a = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-a", organizationName: "Acme", nickname: "Work")
        let b = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-b", organizationName: "Beta")
        _ = store.addAccount(a)
        _ = store.addAccount(b)
        XCTAssertEqual(store.disambiguatedName(for: a), "Work", "a nickname overrides email/org disambiguation")
    }

    @MainActor
    func testDisambiguatedName_sameEmailButNoOrgNameFallsBackToEmail() {
        let store = AccountStore(storage: makeStorage())
        // Accounts migrated from before issue #32 have nil organizationName; they cannot
        // disambiguate and must fall back to the email, unchanged from before.
        let a = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-a")
        let b = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-b")
        _ = store.addAccount(a)
        _ = store.addAccount(b)
        XCTAssertEqual(store.disambiguatedName(for: a), "me@x.com")
    }

    // MARK: - R8 (#41): a bare-key refresh must not leave the stale key serving requests
    // Before this fix, updateSessionKey with a nil cookieHeader wrote the fresh key onto the
    // account but left allCookieHeader holding the DEAD `sessionKey=` pair, and
    // ClaudeAPI.activateCookies prefers a non-empty header over its sessionKey argument. So the
    // jar kept serving the old key: a "signed in" confirmation followed by a failing poll. These
    // tests assert the jar, not just the stored fields, because the stored key was already
    // correct before the fix and the jar was not.

    @MainActor
    private func jarCookie(_ name: String) -> String? {
        let url = URL(string: "https://claude.ai")!
        return ClaudeAPI.session.configuration.httpCookieStorage?.cookies(for: url)?
            .first { $0.name == name }?.value
    }

    @MainActor
    func testUpdateSessionKeyWithNilHeaderPrimesJarWithFreshKey() {
        let store = AccountStore(storage: makeStorage())
        let account = Account(email: "me@x.com", sessionKey: "sk-stale", organizationId: "org-a",
                              allCookieHeader: "sessionKey=sk-stale; __cf_bm=cf-1")
        _ = store.addAccount(account)
        XCTAssertEqual(jarCookie("sessionKey"), "sk-stale", "precondition: jar holds the stale key")

        // A bare session-key paste: fresh key, no cookie header.
        store.updateSessionKey(account.id, "sk-fresh")

        XCTAssertEqual(jarCookie("sessionKey"), "sk-fresh",
                       "the active account's jar must serve the pasted key, not the stale header (R8)")
        XCTAssertEqual(jarCookie("__cf_bm"), "cf-1",
                       "the Cloudflare cookie is kept - dropping it trades a stale key for a 403 (#7)")
        XCTAssertEqual(store.accounts.first?.allCookieHeader, "sessionKey=sk-fresh; __cf_bm=cf-1",
                       "the stored header carries the fresh key so a later switchTo primes it too")
    }

    @MainActor
    func testUpdateSessionKeyWithNilHeaderOnBackgroundAccountSurvivesLaterSwitch() {
        let store = AccountStore(storage: makeStorage())
        let a = Account(email: "me@x.com", sessionKey: "sk-a", organizationId: "org-a",
                        allCookieHeader: "sessionKey=sk-a; __cf_bm=cf-a")
        let b = Account(email: "me@x.com", sessionKey: "sk-b-stale", organizationId: "org-b",
                        allCookieHeader: "sessionKey=sk-b-stale; __cf_bm=cf-b")
        _ = store.addAccount(a)
        _ = store.addAccount(b)
        XCTAssertEqual(store.activeAccountId, a.id, "precondition: the first account is active")

        // Refresh the non-active sibling with a bare key, then make it active later.
        store.updateSessionKey(b.id, "sk-b-fresh")
        XCTAssertEqual(jarCookie("sessionKey"), "sk-a", "a background refresh must not touch the live jar")

        store.switchTo(b.id)

        XCTAssertEqual(jarCookie("sessionKey"), "sk-b-fresh",
                       "switching to the refreshed sibling serves its fresh key, not the stale header")
        XCTAssertEqual(jarCookie("__cf_bm"), "cf-b")
    }

    @MainActor
    func testUpdateSessionKeyWithFullHeaderReplacesStoredHeaderWholesale() {
        let store = AccountStore(storage: makeStorage())
        let account = Account(email: "me@x.com", sessionKey: "sk-stale", organizationId: "org-a",
                              allCookieHeader: "sessionKey=sk-stale; __cf_bm=cf-old")
        _ = store.addAccount(account)

        store.updateSessionKey(account.id, "sk-fresh", cookieHeader: "sessionKey=sk-fresh; __cf_bm=cf-new")

        XCTAssertEqual(store.accounts.first?.allCookieHeader, "sessionKey=sk-fresh; __cf_bm=cf-new",
                       "a captured header still replaces the stored one byte for byte, unchanged by R8")
        XCTAssertEqual(jarCookie("sessionKey"), "sk-fresh")
        XCTAssertEqual(jarCookie("__cf_bm"), "cf-new")
    }

    @MainActor
    func testAddAccountWithFullHeaderIsUnaffected() {
        let store = AccountStore(storage: makeStorage())
        let account = Account(email: "me@x.com", sessionKey: "sk-1", organizationId: "org-a",
                              allCookieHeader: "sessionKey=sk-1; __cf_bm=cf-1; anthropic-csrf-token=csrf")
        _ = store.addAccount(account)

        XCTAssertEqual(store.accounts.first?.allCookieHeader,
                       "sessionKey=sk-1; __cf_bm=cf-1; anthropic-csrf-token=csrf",
                       "the add path stores the pasted header verbatim; R8 only touches refreshes")
        XCTAssertEqual(jarCookie("sessionKey"), "sk-1")
        XCTAssertEqual(jarCookie("anthropic-csrf-token"), "csrf")
    }

    // MARK: - R8 (#41): the pure header-rewrite rule

    func testHeaderReplacingSessionKeyKeepsOtherCookies() {
        let result = AccountStore.headerReplacingSessionKey(
            in: "sessionKey=old; __cf_bm=cf; anthropic-csrf-token=csrf", with: "new")
        XCTAssertEqual(result, "sessionKey=new; __cf_bm=cf; anthropic-csrf-token=csrf")
    }

    func testHeaderReplacingSessionKeyAppendsWhenAbsent() {
        // A stored header with no sessionKey pair would otherwise prime an unauthenticated jar.
        let result = AccountStore.headerReplacingSessionKey(in: "__cf_bm=cf", with: "new")
        XCTAssertEqual(result, "__cf_bm=cf; sessionKey=new")
    }

    func testHeaderReplacingSessionKeyHandlesBareSemicolons() {
        // RFC 6265 allows ";" with no trailing space, the same case ClaudeAPI.injectCookies handles.
        let result = AccountStore.headerReplacingSessionKey(in: "__cf_bm=cf;sessionKey=old", with: "new")
        XCTAssertEqual(result, "__cf_bm=cf; sessionKey=new")
    }

    func testHeaderReplacingSessionKeyLeavesSimilarlyNamedCookiesAlone() {
        let result = AccountStore.headerReplacingSessionKey(
            in: "sessionKeyBackup=keepme; sessionKey=old", with: "new")
        XCTAssertEqual(result, "sessionKeyBackup=keepme; sessionKey=new")
    }

    func testHeaderReplacingSessionKeyPreservesValuesContainingEquals() {
        // Base64 session keys carry "=" padding; splitting on "=" must not truncate other cookies.
        let result = AccountStore.headerReplacingSessionKey(in: "sessionKey=old==; __cf_bm=a=b", with: "new==")
        XCTAssertEqual(result, "sessionKey=new==; __cf_bm=a=b")
    }

    // MARK: - Codable migration: legacy Account JSON without organizationName (R7, #32)

    func testAccountDecodesLegacyJSONWithoutOrganizationName() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","email":"old@x.com","sessionKey":"sk","organizationId":"org-1","addedDate":0,"notificationThreshold":20,"didNotifyBelowThreshold":false}
        """.data(using: .utf8)!
        let account = try JSONDecoder().decode(Account.self, from: legacy)
        XCTAssertNil(account.organizationName, "a missing organizationName key decodes as nil")
        XCTAssertEqual(account.displayName, "old@x.com", "legacy account still renders by email")
    }

    // MARK: - Codable migration: stored Account JSON without the plan fields (S1, R4, AE7)

    func testAccountDecodesStoredJSONWithoutPlanFields() throws {
        // Everyone upgrading to this release has accounts on disk written before the plan fields
        // existed. They must load, not throw, and read as "plan unknown" so the dial falls back to
        // the true session number instead of converting on something invented (R3).
        let stored = """
        {"id":"\(UUID().uuidString)","email":"old@x.com","sessionKey":"sk","organizationId":"org-1","addedDate":0,"notificationThreshold":20,"didNotifyBelowThreshold":false}
        """.data(using: .utf8)!
        let account = try JSONDecoder().decode(Account.self, from: stored)
        XCTAssertNil(account.rateLimitTier, "a missing rateLimitTier key decodes as nil")
        XCTAssertNil(account.capabilities, "a missing capabilities key decodes as nil")
    }

    func testAccountPlanFieldsSurviveAStorageRoundTrip() {
        let storage = makeStorage()
        let account = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-1",
                              rateLimitTier: "default_claude_max_20x", capabilities: ["claude_max", "chat"])

        storage.saveAccounts([account])

        let read = storage.readAccounts()
        XCTAssertEqual(read.first?.rateLimitTier, "default_claude_max_20x",
                       "the plan has to survive a relaunch, or the dial converts only until the app quits")
        XCTAssertEqual(read.first?.capabilities, ["claude_max", "chat"])
    }

    // MARK: - updatePlan (S1, R4)

    @MainActor
    func testUpdatePlanWritesAndPersistsTheNewPlan() {
        let storage = makeStorage()
        let store = AccountStore(storage: storage)
        let account = makeAccount()
        _ = store.addAccount(account)

        store.updatePlan(account.id, rateLimitTier: "default_claude_max_5x", capabilities: ["claude_max"])

        XCTAssertEqual(store.accounts.first?.rateLimitTier, "default_claude_max_5x")
        XCTAssertEqual(storage.readAccounts().first?.rateLimitTier, "default_claude_max_5x",
                       "written through to storage, not only to the in-memory copy")
    }

    @MainActor
    func testUpdatePlanWithNilClearsAStoredPlan() {
        // D4: absence is information. A tier we can no longer see must stop converting the dial
        // rather than leave the last known plan in place.
        let storage = makeStorage()
        let store = AccountStore(storage: storage)
        let account = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-1",
                              rateLimitTier: "default_claude_max_20x", capabilities: ["claude_max"])
        _ = store.addAccount(account)

        store.updatePlan(account.id, rateLimitTier: nil, capabilities: nil)

        XCTAssertNil(store.accounts.first?.rateLimitTier, "nil overwrites; it is not read as no news")
        XCTAssertNil(store.accounts.first?.capabilities)
    }

    @MainActor
    func testUpdatePlanForAnUnknownIdChangesNothing() {
        let storage = makeStorage()
        let store = AccountStore(storage: storage)
        let account = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-1",
                              rateLimitTier: "default_claude_pro")
        _ = store.addAccount(account)

        store.updatePlan(UUID(), rateLimitTier: "default_claude_max_20x", capabilities: nil)

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.rateLimitTier, "default_claude_pro",
                       "a write aimed at an account that is not stored must not land on another one")
    }

    @MainActor
    func testUpdatePlanLeavesCredentialsAlone() {
        let storage = makeStorage()
        let store = AccountStore(storage: storage)
        let account = Account(email: "me@x.com", sessionKey: "sk-real", organizationId: "org-1",
                              allCookieHeader: "sessionKey=sk-real; __cf_bm=cf")
        _ = store.addAccount(account)

        store.updatePlan(account.id, rateLimitTier: "default_claude_max_20x", capabilities: ["claude_max"])

        XCTAssertEqual(store.accounts.first?.sessionKey, "sk-real")
        XCTAssertEqual(store.accounts.first?.allCookieHeader, "sessionKey=sk-real; __cf_bm=cf",
                       "a plan write touches two display fields and no credentials")
    }

    // MARK: - updatePlan and the running measurement (R4, R5, D3)

    /// An account already carrying a mature measurement, so a plan write has something to destroy.
    private func accountWithAMeasurement(tier: String?) -> Account {
        var account = Account(email: "me@x.com", sessionKey: "sk", organizationId: "org-1",
                              rateLimitTier: tier)
        account.ratioMeasurement = RatioMeasurement(lastSessionRemaining: 100,
                                                    lastSessionResetsAt: Date(timeIntervalSince1970: 1),
                                                    lastWeeklyRemaining: 68,
                                                    lastWeeklyResetsAt: Date(timeIntervalSince1970: 2),
                                                    sessionPointsConsumed: 400,
                                                    weeklyPointsConsumed: 32)
        return account
    }

    @MainActor
    func testUpdatePlanToADifferentTier_clearsTheMeasurement() {
        // The measurement outranks the tier being written, so an upgrade that kept it would keep
        // converting the dial on capacities the account no longer has - the exact thing updatePlan
        // exists to stop.
        let storage = makeStorage()
        let store = AccountStore(storage: storage)
        let account = accountWithAMeasurement(tier: "default_claude_max_5x")
        _ = store.addAccount(account)

        store.updatePlan(account.id, rateLimitTier: "default_claude_max_20x", capabilities: nil)

        XCTAssertNil(store.accounts.first?.ratioMeasurement)
        XCTAssertNil(storage.readAccounts().first?.ratioMeasurement,
                     "cleared in storage too, or the next launch reads the old plan's arithmetic back")
    }

    @MainActor
    func testUpdatePlanWithTheSameTier_leavesTheMeasurementAlone() {
        // The common case by far: every re-auth refreshes the plan, and re-writing the same string
        // must not restart a measurement that took days to build.
        let store = AccountStore(storage: makeStorage())
        let account = accountWithAMeasurement(tier: "default_claude_max_5x")
        _ = store.addAccount(account)

        store.updatePlan(account.id, rateLimitTier: "default_claude_max_5x", capabilities: ["claude_max"])

        XCTAssertEqual(store.accounts.first?.ratioMeasurement?.weeklyPointsConsumed, 32)
    }

    @MainActor
    func testLearningTheTierForTheFirstTime_leavesTheMeasurementAlone() {
        // nil to a string is not a plan change, it is the first time the app saw the plan at all.
        // That is every account carried over from v1.60, and some of them have measured a correct
        // ratio in the meantime.
        let store = AccountStore(storage: makeStorage())
        let account = accountWithAMeasurement(tier: nil)
        _ = store.addAccount(account)

        store.updatePlan(account.id, rateLimitTier: "default_claude_max_20x", capabilities: nil)

        XCTAssertEqual(store.accounts.first?.ratioMeasurement?.weeklyPointsConsumed, 32)
        XCTAssertEqual(store.accounts.first?.rateLimitTier, "default_claude_max_20x")
    }

    @MainActor
    func testATierGoingMissing_leavesTheMeasurementAlone() {
        // A string to nil is just as likely to mean the field stopped arriving as a real change,
        // and it would wipe every account's measurement at once - taking with it the one thing
        // that still converts the dial once the table cannot (D3).
        let store = AccountStore(storage: makeStorage())
        let account = accountWithAMeasurement(tier: "default_claude_max_5x")
        _ = store.addAccount(account)

        store.updatePlan(account.id, rateLimitTier: nil, capabilities: nil)

        XCTAssertNil(store.accounts.first?.rateLimitTier, "the tier still clears")
        XCTAssertEqual(store.accounts.first?.ratioMeasurement?.weeklyPointsConsumed, 32)
    }

    @MainActor
    func testRepeatingTheSameMeasurement_doesNotRepublishTheStore() {
        // A poll that reads back the same percentages folds to a value equal to the stored one, so
        // writing it would re-encode every account and invalidate every view watching the store,
        // every two minutes, with nothing new to show for it (issue #11).
        let store = AccountStore(storage: makeStorage())
        let account = accountWithAMeasurement(tier: "default_claude_max_5x")
        _ = store.addAccount(account)
        let stored = account.ratioMeasurement!

        var publishes = 0
        let cancellable = store.objectWillChange.sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        store.updateRatioMeasurement(account.id, stored)
        XCTAssertEqual(publishes, 0, "an unchanged measurement is not news")

        var moved = stored
        moved.weeklyPointsConsumed += 1
        store.updateRatioMeasurement(account.id, moved)
        XCTAssertEqual(publishes, 1, "a measurement that moved still writes")
        XCTAssertEqual(store.accounts.first?.ratioMeasurement?.weeklyPointsConsumed, 33)
    }
}
