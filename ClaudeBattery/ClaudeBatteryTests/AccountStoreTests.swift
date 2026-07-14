import XCTest
@testable import ClaudeBattery

final class AccountStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.AccountStore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
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

    // MARK: - Codable migration: legacy Account JSON without organizationName (R7, #32)

    func testAccountDecodesLegacyJSONWithoutOrganizationName() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","email":"old@x.com","sessionKey":"sk","organizationId":"org-1","addedDate":0,"notificationThreshold":20,"didNotifyBelowThreshold":false}
        """.data(using: .utf8)!
        let account = try JSONDecoder().decode(Account.self, from: legacy)
        XCTAssertNil(account.organizationName, "a missing organizationName key decodes as nil")
        XCTAssertEqual(account.displayName, "old@x.com", "legacy account still renders by email")
    }
}
