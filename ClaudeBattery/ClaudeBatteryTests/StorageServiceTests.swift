import XCTest
@testable import ClaudeBattery

final class StorageServiceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.StorageService.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStorage(prefix: String = "cb_") -> StorageService {
        StorageService(defaults: defaults, prefix: prefix)
    }

    private func makeAccount(
        id: UUID = UUID(),
        email: String = "test@example.com",
        sessionKey: String = "sk-test-123",
        organizationId: String = "org-abc"
    ) -> Account {
        Account(id: id, email: email, sessionKey: sessionKey, organizationId: organizationId)
    }

    // MARK: - Happy Path: saveAccounts / readAccounts round-trip

    func testSaveAndReadAccountsRoundTrip() {
        let storage = makeStorage()
        let account = makeAccount()

        storage.saveAccounts([account])
        let loaded = storage.readAccounts()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, account)
    }

    // MARK: - Happy Path: setActiveAccountId / getActiveAccountId round-trip

    func testSetAndGetActiveAccountId() {
        let storage = makeStorage()
        let id = UUID()

        storage.setActiveAccountId(id)
        let retrieved = storage.getActiveAccountId()

        XCTAssertEqual(retrieved, id)
    }

    // MARK: - Happy Path: Legacy migration

    func testLegacyMigrationCreatesAccountAndDeletesOldKeys() {
        let prefix = "cb_"
        // Pre-populate legacy keys before StorageService init triggers migration
        defaults.set("sk-legacy-key", forKey: "\(prefix)sessionKey")
        defaults.set("org-legacy-123", forKey: "\(prefix)organizationId")

        let storage = makeStorage(prefix: prefix)
        let accounts = storage.readAccounts()

        // Should have created one migrated account
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].sessionKey, "sk-legacy-key")
        XCTAssertEqual(accounts[0].organizationId, "org-legacy-123")
        XCTAssertEqual(accounts[0].email, "Account 1")

        // Active account should be set
        XCTAssertNotNil(storage.getActiveAccountId())
        XCTAssertEqual(storage.getActiveAccountId(), accounts[0].id)

        // Old keys should be deleted
        XCTAssertNil(defaults.string(forKey: "\(prefix)sessionKey"))
        XCTAssertNil(defaults.string(forKey: "\(prefix)organizationId"))

        // Migration flag should be set
        XCTAssertTrue(defaults.bool(forKey: "\(prefix)migrated"))
    }

    // MARK: - Edge Case: readAccounts on empty defaults

    func testReadAccountsOnEmptyDefaultsReturnsEmptyArray() {
        let storage = makeStorage()
        let accounts = storage.readAccounts()

        XCTAssertEqual(accounts, [])
    }

    // MARK: - Edge Case: Legacy migration with only sessionKey (no orgId)

    func testLegacyMigrationWithOnlySessionKeyMarksMigratedReturnsEmpty() {
        let prefix = "cb_"
        defaults.set("sk-orphan-key", forKey: "\(prefix)sessionKey")
        // No organizationId set

        let storage = makeStorage(prefix: prefix)
        let accounts = storage.readAccounts()

        // Should not create any account
        XCTAssertEqual(accounts, [])

        // Should still mark as migrated
        XCTAssertTrue(defaults.bool(forKey: "\(prefix)migrated"))

        // sessionKey should remain (migration only deletes keys on success)
        XCTAssertEqual(defaults.string(forKey: "\(prefix)sessionKey"), "sk-orphan-key")
    }

    // MARK: - Edge Case: Legacy migration already completed

    func testLegacyMigrationAlreadyCompletedIsNoOp() {
        let prefix = "cb_"
        // Mark migration as already done
        defaults.set(true, forKey: "\(prefix)migrated")
        // Place legacy keys that should NOT be touched
        defaults.set("sk-should-stay", forKey: "\(prefix)sessionKey")
        defaults.set("org-should-stay", forKey: "\(prefix)organizationId")

        let storage = makeStorage(prefix: prefix)
        let accounts = storage.readAccounts()

        // No accounts should be created from migration
        XCTAssertEqual(accounts, [])

        // Legacy keys should remain untouched
        XCTAssertEqual(defaults.string(forKey: "\(prefix)sessionKey"), "sk-should-stay")
        XCTAssertEqual(defaults.string(forKey: "\(prefix)organizationId"), "org-should-stay")
    }

    // MARK: - setActiveAccountId(nil) clears stored value

    func testSetActiveAccountIdNilClearsValue() {
        let storage = makeStorage()
        let id = UUID()

        storage.setActiveAccountId(id)
        XCTAssertNotNil(storage.getActiveAccountId())

        storage.setActiveAccountId(nil)
        XCTAssertNil(storage.getActiveAccountId())
    }
}
