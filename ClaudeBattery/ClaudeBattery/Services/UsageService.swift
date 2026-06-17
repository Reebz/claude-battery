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

            latestUsage = UsageData(from: usage, prepaidCredits: prepaidCredits)
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
    // Newer /usage shape — optional so the existing non-optional decode keeps working on
    // either response (KTD1). Absent on legacy bodies; the resolver prefers these.
    let limits: [UsageLimit]?
    let spend: SpendInfo?
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
        resetsAt = ResetDate.parse(from: container, key: .resetsAt)
    }
}

/// Tolerant `resets_at` parsing shared by `UsageTier` and `UsageLimit` (issue #23, KTD2).
///
/// `resets_at` arrives in shapes a single `JSONDecoder` date strategy cannot all cover:
/// ISO8601 with or without fractional seconds, AND a UNIX epoch as a JSON number or a
/// numeric string. The old `try? decode(Date.self)` under the decoder's `.iso8601`
/// strategy silently nil-ed every non-bare-ISO value - including any epoch number, which
/// `.iso8601` can never parse into a Date - so the Resets card rendered blank "--" while
/// `utilization` still decoded. Parse tolerantly here, and when a value is present but
/// unmappable, log it instead of failing silently. Generic over the key type so any
/// struct with a `resets_at`-style field reuses the exact same tolerance.
enum ResetDate {
    static func parse<K: CodingKey>(from container: KeyedDecodingContainer<K>, key: K) -> Date? {
        // Absent or explicit null is normal - a plan/tier/limit may simply have no reset window.
        guard container.contains(key),
              (try? container.decodeNil(forKey: key)) != true else { return nil }

        // UNIX epoch as a JSON number (seconds or milliseconds).
        if let epoch = try? container.decode(Double.self, forKey: key) {
            if let date = dateFromEpoch(epoch) { return date }
            logger.warning("resets_at numeric value out of range")
            return nil
        }

        // String form: epoch-as-string, or ISO8601 with/without fractional seconds.
        if let raw = try? container.decode(String.self, forKey: key) {
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
    static func dateFromEpoch(_ value: Double) -> Date? {
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

// MARK: - limits[] / spend (newer /usage shape)

/// One entry in the newer `/usage` `limits[]` array. `kind` distinguishes `session`,
/// `weekly_all`, and `weekly_scoped` (per-model) windows; `scope.model.displayName`
/// labels a per-model bar. All fields optional/lenient so a shape drift degrades to nil
/// rather than throwing the whole `/usage` decode.
struct UsageLimit: Codable, Equatable {
    let kind: String?
    let group: String?
    let percent: Double?
    let severity: String?
    let resetsAt: Date?
    let scope: LimitScope?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, resetsAt, scope, isActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try? container.decode(String.self, forKey: .kind)
        group = try? container.decode(String.self, forKey: .group)
        percent = try? container.decode(Double.self, forKey: .percent)
        severity = try? container.decode(String.self, forKey: .severity)
        resetsAt = ResetDate.parse(from: container, key: .resetsAt)
        scope = try? container.decode(LimitScope.self, forKey: .scope)
        isActive = try? container.decode(Bool.self, forKey: .isActive)
    }
}

struct LimitScope: Codable, Equatable {
    let model: ModelScope?
    let surface: String?

    enum CodingKeys: String, CodingKey { case model, surface }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try? container.decode(ModelScope.self, forKey: .model)
        surface = try? container.decode(String.self, forKey: .surface)
    }
}

struct ModelScope: Codable, Equatable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey { case id, displayName }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        displayName = try? container.decode(String.self, forKey: .displayName)
    }
}

/// A monetary amount in minor units (KTD4). Convert to major units exactly once at the
/// derivation boundary (`amountMinor / 10^exponent`), never at display, to guard the
/// documented 100x cents-vs-dollars bug.
struct Money: Codable, Equatable {
    let amountMinor: Double?
    let currency: String?
    let exponent: Int?

    enum CodingKeys: String, CodingKey { case amountMinor, currency, exponent }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amountMinor = try? container.decode(Double.self, forKey: .amountMinor)
        currency = try? container.decode(String.self, forKey: .currency)
        exponent = try? container.decode(Int.self, forKey: .exponent)
    }
}

/// The newer `/usage` `spend` object: monthly extra-usage spend plus enabled/disabled
/// state. `percent` can exceed 100 (KTD7). All optional/lenient.
struct SpendInfo: Codable, Equatable {
    let used: Money?
    let limit: Money?
    let percent: Double?
    let severity: String?
    let enabled: Bool?
    let disabledReason: String?

    enum CodingKeys: String, CodingKey {
        case used, limit, percent, severity, enabled, disabledReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        used = try? container.decode(Money.self, forKey: .used)
        limit = try? container.decode(Money.self, forKey: .limit)
        percent = try? container.decode(Double.self, forKey: .percent)
        severity = try? container.decode(String.self, forKey: .severity)
        enabled = try? container.decode(Bool.self, forKey: .enabled)
        disabledReason = try? container.decode(String.self, forKey: .disabledReason)
    }
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

/// One model's weekly usage, derived from a `weekly_scoped` limit (or the legacy
/// `seven_day_*` fields). Absence of data means no entry - never a fabricated 100% bar (KTD3).
struct ModelUsage: Equatable, Identifiable {
    let displayName: String
    let remainingPercent: Double
    let resetDate: Date?
    /// API model id when present; identity prefers it over the human label so two
    /// scoped limits sharing a display_name do not collide in a SwiftUI ForEach.
    let modelId: String?
    var id: String { modelId ?? displayName }
}

/// Unified Usage-credits display model (KTD5). `state` reflects the `spend` object
/// (an enabled spend line, or a disabled/paused reason); `balance` is the prepaid balance,
/// shown whenever it is positive, independent of `state`.
struct UsageCreditsData: Equatable {
    enum State: Equatable {
        /// `percent` is uncapped (can exceed 100, KTD7); the bar fill clamps at display.
        case enabled(spent: Double, limit: Double?, percent: Double, currency: String, resetDate: Date?)
        case disabled(reason: String, resetDate: Date?)
    }

    struct Balance: Equatable {
        let major: Double
        let currency: String
    }

    let state: State?
    let balance: Balance?

    /// Convert a `Money` (minor units) to major units exactly once (KTD4).
    private static func major(_ money: Money) -> Double {
        let exponent = money.exponent ?? 2
        return (money.amountMinor ?? 0) / pow(10.0, Double(exponent))
    }

    static func derive(spend: SpendInfo?, prepaidCredits: PrepaidCreditsResponse?) -> UsageCreditsData? {
        let balance: Balance? = {
            guard let cents = prepaidCredits?.amount, cents > 0 else { return nil }
            return Balance(major: cents / 100.0, currency: prepaidCredits?.currency ?? "USD")
        }()

        let state: State? = {
            guard let spend else { return nil }
            if spend.enabled == true {
                let currency = spend.used?.currency ?? "USD"
                let spent = spend.used.map(major) ?? 0
                let limit = spend.limit.map(major)
                // The spend object carries no reset field in the captured (disabled) shape;
                // the enabled monthly reset is provisional (A3) and derived at display until
                // a credits-ENABLED capture confirms the real field.
                return .enabled(spent: spent, limit: limit, percent: spend.percent ?? 0, currency: currency, resetDate: nil)
            }
            return .disabled(reason: spend.disabledReason ?? "disabled", resetDate: nil)
        }()

        if state == nil, balance == nil { return nil }
        return UsageCreditsData(state: state, balance: balance)
    }
}

struct UsageData: Equatable {
    let weeklyRemaining: Double
    let weeklyResetDate: Date?
    let sessionRemaining: Double
    let sessionResetDate: Date?
    let modelUsages: [ModelUsage]
    let extraUsage: ExtraUsageData?
    let prepaidBalance: PrepaidBalance?
    let usageCredits: UsageCreditsData?

    init(from response: UsageResponse, prepaidCredits: PrepaidCreditsResponse? = nil) {
        let limits = response.limits

        // Session / weekly: prefer limits[] (newer shape), else the legacy per-field tiers.
        if let limit = limits?.first(where: { $0.kind == "session" }), let percent = limit.percent {
            sessionRemaining = UsageData.clamp(100 - percent)
            sessionResetDate = limit.resetsAt
        } else {
            sessionRemaining = UsageData.clamp(100 - (response.fiveHour?.utilization ?? 0))
            sessionResetDate = response.fiveHour?.resetsAt
        }

        if let limit = limits?.first(where: { $0.kind == "weekly_all" }), let percent = limit.percent {
            weeklyRemaining = UsageData.clamp(100 - percent)
            weeklyResetDate = limit.resetsAt
        } else {
            weeklyRemaining = UsageData.clamp(100 - (response.sevenDay?.utilization ?? 0))
            weeklyResetDate = response.sevenDay?.resetsAt
        }

        // Per-model: from weekly_scoped when limits[] present, else legacy seven_day_* gated
        // on non-null so an absent model hides its bar rather than faking 100% (KTD3).
        if let limits {
            modelUsages = limits
                .filter { $0.kind == "weekly_scoped" }
                .compactMap { limit in
                    guard let name = limit.scope?.model?.displayName, let percent = limit.percent else { return nil }
                    return ModelUsage(displayName: name,
                                      remainingPercent: UsageData.clamp(100 - percent),
                                      resetDate: limit.resetsAt,
                                      modelId: limit.scope?.model?.id)
                }
        } else {
            modelUsages = UsageData.legacyModelUsages(from: response)
        }

        extraUsage = ExtraUsageData(from: response.extraUsage)
        prepaidBalance = PrepaidBalance(from: prepaidCredits)
        usageCredits = UsageCreditsData.derive(spend: response.spend, prepaidCredits: prepaidCredits)
    }

    private static func clamp(_ value: Double) -> Double { max(0, min(100, value)) }

    private static func legacyModelUsages(from response: UsageResponse) -> [ModelUsage] {
        var models: [ModelUsage] = []
        if let opus = response.sevenDayOpus, let utilization = opus.utilization {
            models.append(ModelUsage(displayName: "Opus", remainingPercent: clamp(100 - utilization), resetDate: opus.resetsAt, modelId: nil))
        }
        if let sonnet = response.sevenDaySonnet, let utilization = sonnet.utilization {
            models.append(ModelUsage(displayName: "Sonnet", remainingPercent: clamp(100 - utilization), resetDate: sonnet.resetsAt, modelId: nil))
        }
        return models
    }
}

// MARK: - Prepaid Credits

/// Raw API response from /api/organizations/{orgId}/prepaid/credits.
/// Optional fields decode to nil automatically for accounts without prepaid.
/// `currency` drives currency-aware formatting (KTD6); the remaining fields round-trip
/// the response shape without the widget consuming them.
struct PrepaidCreditsResponse: Codable {
    let amount: Double?
    let currency: String?
    let autoReloadSettings: AutoReloadSettings?
    let pendingInvoiceAmountCents: Double?
    let lastPaidPurchaseCents: Double?

    enum CodingKeys: String, CodingKey {
        case amount, currency, autoReloadSettings, pendingInvoiceAmountCents, lastPaidPurchaseCents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount = try? container.decode(Double.self, forKey: .amount)
        currency = try? container.decode(String.self, forKey: .currency)
        // decodeIfPresent so an explicit JSON `null` (the captured shape) yields nil rather
        // than a present empty struct - an empty Decodable struct otherwise decodes from null.
        autoReloadSettings = (try? container.decodeIfPresent(AutoReloadSettings.self, forKey: .autoReloadSettings)) ?? nil
        pendingInvoiceAmountCents = try? container.decode(Double.self, forKey: .pendingInvoiceAmountCents)
        lastPaidPurchaseCents = try? container.decode(Double.self, forKey: .lastPaidPurchaseCents)
    }
}

/// Opaque auto-reload configuration; shape unconfirmed and unused by the widget. Modeled
/// as a presence-only struct so the field round-trips without constraining its contents.
struct AutoReloadSettings: Codable, Equatable {}

/// Display model for prepaid credit balance. Separate from ExtraUsageData
/// because these are different financial concepts — prepaid is a pre-purchased
/// balance that depletes, extra usage is pay-as-you-go overage against a cap.
struct PrepaidBalance: Equatable {
    let dollars: Double

    init?(from response: PrepaidCreditsResponse?) {
        guard let response, let amountCents = response.amount, amountCents > 0 else { return nil }
        self.dollars = amountCents / 100.0
    }
}
