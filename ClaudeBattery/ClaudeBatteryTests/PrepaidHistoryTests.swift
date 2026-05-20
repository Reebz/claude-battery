import XCTest
@testable import ClaudeBattery

@MainActor
final class PrepaidHistoryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let accountId = UUID()
    private let calendar = Calendar.current

    override func setUp() {
        super.setUp()
        suiteName = "test.PrepaidHistory.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStorage() -> StorageService {
        StorageService(defaults: defaults, prefix: "cb_test_")
    }

    private func date(daysAgo: Int) -> Date {
        let now = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -daysAgo, to: now)!
    }

    // MARK: - Empty State

    func testHighWaterMark_emptyHistory_returnsNil() {
        let storage = makeStorage()
        XCTAssertNil(storage.prepaidHighWaterMark(accountId: accountId))
    }

    // MARK: - Happy Path: Multi-Day Window

    func testRecordThreeConsecutiveDays_returnsMaxAcrossWindow() {
        let storage = makeStorage()
        storage.recordPrepaidObservation(accountId: accountId, balance: 150, observedAt: date(daysAgo: 2))
        storage.recordPrepaidObservation(accountId: accountId, balance: 300, observedAt: date(daysAgo: 1))
        storage.recordPrepaidObservation(accountId: accountId, balance: 250, observedAt: date(daysAgo: 0))

        XCTAssertEqual(storage.prepaidHighWaterMark(accountId: accountId) ?? .nan, 300, accuracy: 0.001)
    }

    // MARK: - Same-Day Coalescing

    func testSameDayObservation_keepsHigherValue() {
        let storage = makeStorage()
        let today = Date()
        storage.recordPrepaidObservation(accountId: accountId, balance: 200, observedAt: today)
        storage.recordPrepaidObservation(accountId: accountId, balance: 180, observedAt: today)

        XCTAssertEqual(storage.prepaidHighWaterMark(accountId: accountId) ?? .nan, 200, accuracy: 0.001)
    }

    func testSameDayObservation_raisesIfHigher() {
        let storage = makeStorage()
        let today = Date()
        storage.recordPrepaidObservation(accountId: accountId, balance: 100, observedAt: today)
        storage.recordPrepaidObservation(accountId: accountId, balance: 250, observedAt: today)

        XCTAssertEqual(storage.prepaidHighWaterMark(accountId: accountId) ?? .nan, 250, accuracy: 0.001)
    }

    // MARK: - 100-Day Window Trimming

    func testEntriesOlderThan100Days_areTrimmedOnNextWrite() {
        let storage = makeStorage()
        storage.recordPrepaidObservation(accountId: accountId, balance: 999, observedAt: date(daysAgo: 200))
        storage.recordPrepaidObservation(accountId: accountId, balance: 50, observedAt: date(daysAgo: 0))

        XCTAssertEqual(storage.prepaidHighWaterMark(accountId: accountId) ?? .nan, 50, accuracy: 0.001)
    }

    func testEntryAt99Days_isRetained() {
        let storage = makeStorage()
        storage.recordPrepaidObservation(accountId: accountId, balance: 500, observedAt: date(daysAgo: 99))
        storage.recordPrepaidObservation(accountId: accountId, balance: 100, observedAt: date(daysAgo: 0))

        XCTAssertEqual(storage.prepaidHighWaterMark(accountId: accountId) ?? .nan, 500, accuracy: 0.001)
    }

    // MARK: - Account Isolation

    func testTwoAccounts_doNotShareHistory() {
        let storage = makeStorage()
        let accountA = UUID()
        let accountB = UUID()

        storage.recordPrepaidObservation(accountId: accountA, balance: 100, observedAt: Date())
        storage.recordPrepaidObservation(accountId: accountB, balance: 500, observedAt: Date())

        XCTAssertEqual(storage.prepaidHighWaterMark(accountId: accountA) ?? .nan, 100, accuracy: 0.001)
        XCTAssertEqual(storage.prepaidHighWaterMark(accountId: accountB) ?? .nan, 500, accuracy: 0.001)
    }

    // MARK: - Persistence Round-Trip

    func testPersistence_survivesStorageReinit() {
        do {
            let storage = makeStorage()
            storage.recordPrepaidObservation(accountId: accountId, balance: 425, observedAt: Date())
        }

        let storage2 = makeStorage()
        XCTAssertEqual(storage2.prepaidHighWaterMark(accountId: accountId) ?? .nan, 425, accuracy: 0.001)
    }

    // MARK: - Negative Balance Guard

    func testNegativeBalance_isIgnored() {
        let storage = makeStorage()
        storage.recordPrepaidObservation(accountId: accountId, balance: -50, observedAt: Date())
        XCTAssertNil(storage.prepaidHighWaterMark(accountId: accountId))
    }
}
