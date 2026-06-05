import AppKit
import Foundation
@preconcurrency import UserNotifications
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "Usage")

@MainActor
class UsageService: NSObject, ObservableObject {
    @Published var latestUsage: UsageData?
    @Published var lastSuccessfulFetch: Date?
    @Published private(set) var consecutiveFailures: Int = 0
    @Published private(set) var authFailed: Bool = false

    private enum Constants {
        static let staleThresholdSeconds: TimeInterval = 660
        static let baseInterval: TimeInterval = 120
        static let backoffInterval1: TimeInterval = 300
        static let backoffInterval2: TimeInterval = 600
        static let maxBackoffInterval: TimeInterval = 1800
        static let staleFailureThreshold = 3
        static let backoffThreshold2 = 6
        static let errorFailureThreshold = 10
        static let defaultNotificationThreshold: Double = 20.0
    }

    var isStale: Bool {
        guard let last = lastSuccessfulFetch else { return true }
        return Date().timeIntervalSince(last) > Constants.staleThresholdSeconds
    }

    var pollInterval: TimeInterval {
        if consecutiveFailures < Constants.staleFailureThreshold { return Constants.baseInterval }
        if consecutiveFailures < Constants.backoffThreshold2 { return Constants.backoffInterval1 }
        if consecutiveFailures < Constants.errorFailureThreshold { return Constants.backoffInterval2 }
        return Constants.maxBackoffInterval
    }

    private let storage: StorageService
    private let accountStore: AccountStore
    private let session: any HTTPDataFetching
    private var timer: Timer?
    private var isPolling = false
    private var currentPollTask: Task<Void, Never>?

    init(storage: StorageService, accountStore: AccountStore, session: any HTTPDataFetching = ClaudeAPI.session) {
        self.storage = storage
        self.accountStore = accountStore
        self.session = session
        super.init()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Polling

    func startPolling() {
        currentPollTask?.cancel()
        currentPollTask = Task { await pollUsage() }
        scheduleNextPoll()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        currentPollTask?.cancel()
        currentPollTask = nil
    }

    func switchAccount() {
        latestUsage = nil
        lastSuccessfulFetch = nil
        consecutiveFailures = 0
        authFailed = false
        restartPolling()
    }

    /// Chains a new poll after the previous task completes its `defer { isPolling = false }`,
    /// preventing the race where a new poll is silently dropped by the isPolling guard.
    private func restartPolling() {
        let previousTask = currentPollTask
        stopPolling()
        currentPollTask = Task {
            _ = await previousTask?.value
            guard !Task.isCancelled else { return }
            await pollUsage()
        }
        scheduleNextPoll()
    }

    private func scheduleNextPoll() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentPollTask = Task {
                    await self.pollUsage()
                }
                _ = await self.currentPollTask?.value
                self.scheduleNextPoll()
            }
        }
        timer?.tolerance = 30
    }

    func pollUsage() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        guard let account = accountStore.activeAccount else {
            logger.warning("Poll skipped — no active account")
            return
        }

        guard let request = ClaudeAPI.makeRequest(path: "/api/organizations/\(account.organizationId)/usage", sessionKey: account.sessionKey) else {
            consecutiveFailures += 1
            logger.error("Failed to construct usage API URL")
            return
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard !Task.isCancelled else { return }

            guard let httpResponse = response as? HTTPURLResponse else {
                consecutiveFailures += 1
                logger.error("Non-HTTP response received")
                return
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                consecutiveFailures += 1
                authFailed = true
                latestUsage = nil
                // Non-PII account id, not displayName (= email by default): os_log lines can be
                // read off-device, so never emit an email here.
                logger.warning("Auth failure (HTTP \(httpResponse.statusCode)) for \(account.id.uuidString)")
                onAuthFailure?()
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                consecutiveFailures += 1
                #if DEBUG
                let body = String(data: data, encoding: .utf8) ?? "(non-utf8)"
                logger.warning("Unexpected HTTP status: \(httpResponse.statusCode) body: \(body.prefix(500))")
                #else
                logger.warning("Unexpected HTTP status: \(httpResponse.statusCode)")
                #endif
                return
            }

            #if DEBUG
            let rawBody = String(data: data, encoding: .utf8) ?? "(non-utf8)"
            logger.info("Usage API response (\(data.count) bytes): \(rawBody.prefix(1000))")
            #endif

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            let usage = try decoder.decode(UsageResponse.self, from: data)

            guard !Task.isCancelled else { return }

            // Fetch prepaid credit balance (separate endpoint, optional — silently nil if unavailable)
            var prepaidCredits: PrepaidCreditsResponse?
            let creditsPath = "/api/organizations/\(account.organizationId)/prepaid/credits"
            if let creditsRequest = ClaudeAPI.makeRequest(path: creditsPath, sessionKey: account.sessionKey) {
                if let (creditsData, creditsResponse) = try? await session.data(for: creditsRequest),
                   let creditsHttp = creditsResponse as? HTTPURLResponse,
                   (200...299).contains(creditsHttp.statusCode) {
                    #if DEBUG
                    let creditsBody = String(data: creditsData, encoding: .utf8) ?? "(non-utf8)"
                    logger.info("Prepaid credits response (\(creditsData.count) bytes): \(creditsBody.prefix(500))")
                    #endif
                    prepaidCredits = try? decoder.decode(PrepaidCreditsResponse.self, from: creditsData)
                }
            }

            guard !Task.isCancelled else { return }

            // Record the observation for the 100-day high-water-mark window; read back the HWM
            // so the popover bar has a meaningful "remaining of N" denominator.
            var prepaidMaximum: Double?
            if let amountCents = prepaidCredits?.amount, amountCents > 0 {
                let dollars = amountCents / 100.0
                storage.recordPrepaidObservation(accountId: account.id, balance: dollars)
                prepaidMaximum = storage.prepaidHighWaterMark(accountId: account.id)
            }

            latestUsage = UsageData(from: usage, prepaidCredits: prepaidCredits, prepaidMaximum: prepaidMaximum)
            lastSuccessfulFetch = Date()
            if consecutiveFailures != 0 { consecutiveFailures = 0 }
            if authFailed { authFailed = false }

            if let weeklyRemaining = latestUsage?.weeklyRemaining {
                checkAndNotify(account: account, remaining: weeklyRemaining)
            }
        } catch {
            if !Task.isCancelled {
                consecutiveFailures += 1
                logger.error("Poll failed: \(error)")
            }
        }
    }

    var onAuthFailure: (() -> Void)?

    // MARK: - Notifications

    private func checkAndNotify(account: Account, remaining: Double) {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }

        let threshold = account.notificationThreshold

        if remaining < threshold && !account.didNotifyBelowThreshold {
            accountStore.updateDidNotify(account.id, true)
            scheduleNotification(account: account, remaining: remaining)
        } else if remaining >= threshold {
            accountStore.updateDidNotify(account.id, false)
        }
    }

    private func scheduleNotification(account: Account, remaining: Double) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                logger.info("Notifications not authorized (status: \(String(describing: settings.authorizationStatus)))")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Claude Usage Low — \(account.displayName)"
            content.body = String(format: "Weekly quota is at %.0f%% remaining.", remaining)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "low-usage-\(account.id.uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    logger.error("Failed to schedule notification: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Wake

    @objc private func handleWake() {
        guard accountStore.activeAccount != nil, !authFailed else { return }
        restartPolling()
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension UsageService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Models

struct UsageResponse: Codable {
    let fiveHour: UsageTier?
    let sevenDay: UsageTier?
    let sevenDayOpus: UsageTier?
    let sevenDaySonnet: UsageTier?
    let extraUsage: ExtraUsageTier?
}

struct ExtraUsageTier: Codable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled, monthlyLimit, usedCredits, utilization
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try? container.decode(Bool.self, forKey: .isEnabled)
        monthlyLimit = try? container.decode(Double.self, forKey: .monthlyLimit)
        usedCredits = try? container.decode(Double.self, forKey: .usedCredits)
        utilization = try? container.decode(Double.self, forKey: .utilization)
    }
}

struct UsageTier: Codable {
    let utilization: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization, resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try? container.decode(Double.self, forKey: .utilization)
        resetsAt = Self.decodeResetsAt(from: container)
    }

    /// `resets_at` arrives in shapes a single `JSONDecoder` date strategy cannot all
    /// cover: ISO8601 with or without fractional seconds, AND a UNIX epoch as a JSON
    /// number or a numeric string. The old `try? decode(Date.self)` under the decoder's
    /// `.iso8601` strategy silently nil-ed every non-bare-ISO value - including any
    /// epoch number, which `.iso8601` can never parse into a Date - so the Resets card
    /// rendered blank "--" while `utilization` still decoded (issue #23). Parse
    /// tolerantly here, and when a value is present but unmappable, log it instead of
    /// failing silently.
    private static func decodeResetsAt(from container: KeyedDecodingContainer<CodingKeys>) -> Date? {
        // Absent or explicit null is normal - a plan/tier may simply have no reset window.
        guard container.contains(.resetsAt),
              (try? container.decodeNil(forKey: .resetsAt)) != true else { return nil }

        // UNIX epoch as a JSON number (seconds or milliseconds).
        if let epoch = try? container.decode(Double.self, forKey: .resetsAt) {
            if let date = dateFromEpoch(epoch) { return date }
            logger.warning("resets_at numeric value out of range")
            return nil
        }

        // String form: epoch-as-string, or ISO8601 with/without fractional seconds.
        if let raw = try? container.decode(String.self, forKey: .resetsAt) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let epoch = Double(trimmed) {
                if let date = dateFromEpoch(epoch) { return date }
                logger.warning("resets_at numeric string out of range")
                return nil
            }
            if let date = iso8601Fractional.date(from: trimmed) { return date }
            if let date = iso8601Plain.date(from: trimmed) { return date }
            logger.warning("resets_at present but unparseable (string form)")
            return nil
        }

        logger.warning("resets_at present but unparseable (non-numeric, non-string)")
        return nil
    }

    /// Parses a UNIX epoch, returning nil for non-finite or implausibly out-of-range
    /// values so a malformed numeric `resets_at` degrades to "unavailable" rather than a
    /// Date that traps the downstream `Int(timeIntervalSinceNow)` countdown conversion.
    /// Values at or above 1e11 are milliseconds (epoch seconds do not reach 1e11 until
    /// roughly the year 5138); the result is bounded to roughly years 2001-2100.
    private static func dateFromEpoch(_ value: Double) -> Date? {
        guard value.isFinite else { return nil }
        let seconds = value >= 1e11 ? value / 1000 : value
        guard seconds > 978_307_200, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct ExtraUsageData: Equatable {
    let spent: Double
    let limit: Double
    let percentage: Double

    init?(from tier: ExtraUsageTier?) {
        guard let tier, tier.isEnabled == true,
              let spentCents = tier.usedCredits,
              let limitCents = tier.monthlyLimit,
              limitCents > 0 else { return nil }

        self.spent = spentCents / 100.0
        self.limit = limitCents / 100.0
        self.percentage = min(100, max(0, spentCents / limitCents * 100))
    }
}

struct UsageData: Equatable {
    let weeklyRemaining: Double
    let weeklyResetDate: Date?
    let sessionRemaining: Double
    let sessionResetDate: Date?
    let opusRemaining: Double
    let opusResetDate: Date?
    let sonnetRemaining: Double
    let sonnetResetDate: Date?
    let extraUsage: ExtraUsageData?
    let prepaidBalance: PrepaidBalance?

    init(from response: UsageResponse, prepaidCredits: PrepaidCreditsResponse? = nil, prepaidMaximum: Double? = nil) {
        weeklyRemaining = max(0, min(100, 100 - (response.sevenDay?.utilization ?? 0)))
        weeklyResetDate = response.sevenDay?.resetsAt
        sessionRemaining = max(0, min(100, 100 - (response.fiveHour?.utilization ?? 0)))
        sessionResetDate = response.fiveHour?.resetsAt
        opusRemaining = max(0, min(100, 100 - (response.sevenDayOpus?.utilization ?? 0)))
        opusResetDate = response.sevenDayOpus?.resetsAt
        sonnetRemaining = max(0, min(100, 100 - (response.sevenDaySonnet?.utilization ?? 0)))
        sonnetResetDate = response.sevenDaySonnet?.resetsAt
        extraUsage = ExtraUsageData(from: response.extraUsage)
        prepaidBalance = PrepaidBalance(from: prepaidCredits, maximum: prepaidMaximum)
    }
}

// MARK: - Prepaid Credits

/// Raw API response from /api/organizations/{orgId}/prepaid/credits.
/// Optional fields decode to nil automatically for accounts without prepaid.
struct PrepaidCreditsResponse: Codable {
    let amount: Double?
}

/// Display model for prepaid credit balance. Separate from ExtraUsageData
/// because these are different financial concepts — prepaid is a pre-purchased
/// balance that depletes, extra usage is pay-as-you-go overage against a cap.
struct PrepaidBalance: Equatable {
    let dollars: Double
    /// 100-day rolling high-water-mark of observed balances. Nil before any history is
    /// recorded for the account; otherwise the maximum of `recordPrepaidObservation`
    /// inputs in the trailing window. Drives the popover bar's "remaining of N" denominator.
    let maximum: Double?

    init?(from response: PrepaidCreditsResponse?, maximum: Double? = nil) {
        guard let response, let amountCents = response.amount, amountCents > 0 else { return nil }
        self.dollars = amountCents / 100.0
        self.maximum = maximum
    }
}
