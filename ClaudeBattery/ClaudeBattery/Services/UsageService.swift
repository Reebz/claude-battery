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
    /// True between `suspendPolling()` and `resumePolling()` (R11, issue #41). Bookkeeping only -
    /// nothing gates on it, so an explicit `startPolling`/`switchAccount` during the window still
    /// polls, which is what lets a sign-in that repaired the active account fetch immediately.
    private var isSuspended = false
    /// Whether `resumePolling` puts polling back: true when a timer was armed or a poll task
    /// existed at suspend time, so a resume restores what the suspend interrupted rather than
    /// starting polling that was not running (no account yet, or a stop that stuck).
    ///
    /// This is timer state, not intent, and the difference is real: when a poll driven by
    /// `scheduleNextPoll` gets a 401/403, `onAuthFailure` runs `stopPolling`, and then the closure
    /// still awaiting that poll reaches its trailing `scheduleNextPoll()` and arms a fresh timer.
    /// So an account already known expired reads as "was running" here, and a resume fires one more
    /// poll at it. That poll 403s and stops the chain for real, so it costs one request. The stated
    /// guarantee is the other direction and it holds: a resume never leaves polling dead, which is
    /// what R11 is for (review finding: the earlier wording claimed the flag knew about intent).
    private var resumeShouldRestart = false

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

    /// Pause polling for the network window of a sign-in (R11, issue #41). `AuthManager` calls this
    /// through a callback and holds no reference to this service (KTD7).
    ///
    /// A usage request picks up its cookies from the shared jar when it goes OUT, not when it was
    /// created, so a sign-in that re-primes that jar mid-flight can have an already-running poll
    /// answered with the pasted account's credentials. The answer is a 403, which marks a healthy
    /// account expired and stops polling - and on the sign-in route that fires no success callback,
    /// nothing starts it again. Cancelling the in-flight poll here makes it return at its
    /// `Task.isCancelled` check instead of reading that response as its own account's.
    func suspendPolling() {
        // Already suspended: keep the FIRST snapshot, which is the one describing what was running
        // before the sign-in began.
        guard !isSuspended else { return }
        isSuspended = true
        resumeShouldRestart = (timer != nil || currentPollTask != nil)
        timer?.invalidate()
        timer = nil
        // Cancel but KEEP the handle, unlike `stopPolling`. `restartPolling` chains the next poll
        // behind this task's `defer { isPolling = false }`, and it can only do that while the handle
        // is still around - dropping it here would reintroduce the silently-dropped-poll race that
        // `restartPolling` exists to prevent.
        currentPollTask?.cancel()
    }

    /// Put polling back after `suspendPolling` (R11, issue #41). Every exit of a sign-in passes
    /// through this, the failed ones included, so no path can leave polling dead.
    func resumePolling() {
        guard isSuspended else { return }
        isSuspended = false
        guard resumeShouldRestart else { return }
        resumeShouldRestart = false
        restartPolling()
    }

    /// Chains a new poll after the previous task completes its `defer { isPolling = false }`,
    /// preventing the race where a new poll is silently dropped by the isPolling guard.
    private func restartPolling() {
        // An explicit restart supersedes a pending resume. A sign-in that repaired the ACTIVE
        // account fires its success callback (-> switchAccount -> here) BEFORE it resumes, and
        // without this the resume that follows would cancel the poll started here and chain a
        // replacement behind it (R11, issue #41). No poll is lost either way: both tasks are made
        // and cancelled inside one synchronous main-actor block, so the replacement fetches at the
        // same moment. What this saves is doing the work twice, which is also why no test can see
        // the difference (review finding).
        isSuspended = false
        resumeShouldRestart = false
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

            // The reading first, with no ratio attached: the measured ratio is derived from this
            // reading's own numbers (R5), so the reading has to exist before the ratio does.
            var reading = UsageData(from: usage, prepaidCredits: prepaidCredits)

            // Fold this sample into the account's running measurement, and store it whether or not
            // anything accumulated - a rollover still has to replace the previous sample, or the
            // next poll would be differenced against a reading from the window before last (KTD4).
            // Persisted rather than held in memory because the totals are built up over many polls
            // and a version that restarted at every app launch would hand a user who quits the app
            // daily a measurement that never gets anywhere.
            //
            // A percentage that was not in the response reads as "nothing used yet" for display
            // (`sessionPercentWasRead`), which is a fabricated reading rather than an observed one.
            // The measurement is handed no window identity for that side, so the check that already
            // discards a rollover discards both the interval ending at this poll and the one
            // starting from it, instead of differencing a real reading against an invented full
            // window. The reading itself keeps its real reset date, which the countdown and the
            // run-out forecast read.
            let measurement = RatioMeasurement.updated(
                from: account.ratioMeasurement,
                sessionRemaining: reading.sessionRemaining,
                sessionResetsAt: reading.sessionPercentWasRead ? reading.sessionResetDate : nil,
                weeklyRemaining: reading.weeklyRemaining,
                weeklyResetsAt: reading.weeklyPercentWasRead ? reading.weeklyResetDate : nil)
            accountStore.updateRatioMeasurement(account.id, measurement)

            // The plan ratio is what lets the Session dial state the weekly remainder on the
            // session's own scale (R1, KTD3). Everything it is built from comes from `account`, the
            // snapshot taken at the top of this poll, so the ratio and the measurement always belong
            // to the same account whose credentials fetched this response - re-reading the store
            // here would pair one account's usage with another's plan if the user switched
            // mid-flight. Read per poll rather than cached, so a re-auth that rewrites the stored
            // tier (`AccountStore.updatePlan`) and an account switch both take effect on the next
            // poll with nothing to invalidate.
            //
            // The measurement wins whenever it has one to give and it does not flatly contradict a
            // tier we recognise (R5, D3) - see `PlanRatio.resolve`. The table is the fallback, and
            // the table falls back to nil for an account added before this release or on a plan we
            // cannot identify. Nil turns the conversion off entirely: the dial then shows the true
            // session number rather than a figure derived from a guessed ratio (R3, D4).
            let measuredRatio = measurement.ratio
            let appliedRatio = PlanRatio.resolve(measured: measuredRatio, tier: account.rateLimitTier)
            if let measuredRatio, appliedRatio != measuredRatio {
                // Rare and worth seeing without turning diagnostics on: the account has measured a
                // ratio its own plan cannot account for, which means the accumulator or assumption
                // A3 is wrong rather than the table being off.
                logger.warning("Measured ratio \(measuredRatio) disagrees with the stored plan by more than \(PlanRatio.agreementFactor)x, keeping the table value")
            }
            reading.applyPlanRatio(appliedRatio)
            latestUsage = reading

            // Record what this plan reports, for the plans nobody here can see (R6). Emitted after
            // the ratio is applied so the sample carries the number the dial actually used, and
            // from the poll rather than from sign-in because the poll is the only thing guaranteed
            // to run while a reporter has logging turned on - most of them will never sign in
            // during the window they are recording. See `planSamplePayload` for what is and is not
            // in it; `emitMilestone` is a no-op until the user opts in, and takes the payload as an
            // autoclosure, so with logging off this poll does not build the sample either.
            DiagnosticsLogger.shared.emitMilestone(
                kind: Self.planSampleKind,
                payload: Self.planSamplePayload(accountId: account.id,
                                                rateLimitTier: account.rateLimitTier,
                                                capabilities: account.capabilities,
                                                billingType: account.billingType,
                                                usage: reading,
                                                measurement: measurement)
            )

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

/// How much of an account's WEEKLY capacity one 5-hour session window holds, per plan. The Session
/// dial reads a session percentage, so a weekly percentage has to be divided by this number before
/// the two can be compared at all: `weeklyRemaining / ratio` is "how much of a session the week's
/// leftovers could still fill" (R1, KTD1). The reported bug was comparing them directly, which
/// showed a user with a full 5h window and 6% of the week left a Session dial reading 6%.
///
/// WHERE THESE NUMBERS COME FROM, AND WHY THEY ARE NOT TRUSTED. They are read off a third-party
/// reverse-engineering write-up at she-llac.com/claude-limits: Pro 550,000 / 5,000,000, Max 5x
/// 3,300,000 / 41,666,700, Max 20x 11,000,000 / 83,333,300. Anthropic publishes none of this and
/// we have not validated any of it. That same page contradicts itself, and on two of the three
/// tiers, not one: its prose claims about 9.1x for every tier while its own table implies 9.09x
/// for Pro, 12.63x for Max 5x and 7.58x for Max 20x. The prose agrees with the table on Pro alone.
/// Max 20x is worth saying out loud because it is the only tier string anyone here has seen live,
/// so it is the entry most likely to be trusted and shipped on, and it is off the prose figure by
/// about 17%. Read all three as a starting value, never as confirmed capacities.
///
/// The correction path is measurement, not a better guess: once the ratio derived from the user's
/// own observed usage clears its confidence bar it overrides this table (R5, D3), unless it
/// disagrees by so much that it cannot be measuring the same thing - see `resolve` below.
enum PlanRatio {
    static let pro: Double = 0.1100          // 550,000 / 5,000,000
    static let max5x: Double = 0.0792        // 3,300,000 / 41,666,700
    static let max20x: Double = 0.1320       // 11,000,000 / 83,333,300

    /// The ratio for a `rate_limit_tier` string, or nil when we cannot convert.
    ///
    /// Only these three strings map. Everything else is nil on purpose, and nil means the dial
    /// shows the true session number with no conversion (R3, D4): Free because the source
    /// publishes no Free capacities and inventing one would be the exact error this fixes (D2),
    /// `auto_prepaid_tier_3` because it is an API billing tier rather than a plan, and any string
    /// we have not seen because a guess would be a wrong number rather than a missing one. The
    /// match is exact - a tier string that differs even in case is one we have not seen.
    static func forTier(_ tier: String?) -> Double? {
        switch tier {
        case "default_claude_pro":     return pro
        case "default_claude_max_5x":  return max5x
        case "default_claude_max_20x": return max20x
        default:                       return nil
        }
    }

    /// How far a measured ratio may sit from a recognised tier's table value before the table is
    /// kept instead, as a factor either way.
    ///
    /// Wide on purpose. The whole reason for measuring is that this table can be wrong (D1, D3), so
    /// the band has to admit every correction the table plausibly needs. The widest disagreement
    /// inside the material the table came from is its own prose against its own numbers, 12.63x
    /// against 9.09x, a factor of 1.39, and the three published ratios span 1.67x end to end. A
    /// factor of 2 leaves room for a correction larger than anything that source can justify.
    static let agreementFactor: Double = 2

    /// The ratio the dial converts with: the account's own measurement when there is one to
    /// believe, and this table otherwise (R5, D3).
    ///
    /// The measurement wins by default. It comes from the account's own usage rather than from a
    /// third party's unvalidated table, and it needs no plan string at all, so it converts the dial
    /// even on a tier we do not recognise - which is the only conversion those accounts will ever
    /// get.
    ///
    /// The one thing it does not get to do is contradict a tier we DO recognise by more than
    /// `agreementFactor`. Past its confidence bar the measurement resolves the ratio to a few
    /// percent, so a disagreement of 2x is not the measurement being imprecise, it is the
    /// measurement measuring something other than what we think: an accumulator fed a fabricated
    /// reading, or A3 false and session and weekly not sharing a credit unit, in which case no
    /// single ratio exists to find. Preferring the table there is the same call D4 makes elsewhere
    /// - a number with a stated origin beats a number we can show is broken. Nothing is swallowed:
    /// the plan sample carries `measured_ratio` and `applied_ratio` side by side, so a reporter's
    /// file shows the disagreement and what the dial did about it (R6).
    static func resolve(measured: Double?, tier: String?) -> Double? {
        let table = forTier(tier)
        guard let measured else { return table }
        // No table entry means nothing to check against, and refusing here would leave the dial
        // unconverted for exactly the accounts the measurement exists to serve.
        guard let table else { return measured }
        guard measured <= table * agreementFactor, measured * agreementFactor >= table else { return table }
        return measured
    }
}

/// A running measurement of one account's REAL 5h-over-weekly capacity ratio, taken from what that
/// account actually consumes (R5, KTD4, KTD5, D3).
///
/// Why measure at all when `PlanRatio` already has a number: that table is a third party's reverse
/// engineering, none of it is validated, and the page it came from contradicts itself. A wrong
/// constant is silent forever - every account on that plan reads wrong and nothing ever says so.
/// A ratio measured from the user's own account cannot fail that quietly: it either converges or
/// it refuses to produce a number, and the refusal is itself the signal that something is wrong
/// (D3). It also sidesteps plan detection completely, so an account whose `rate_limit_tier` string
/// we have never seen can still get a converted dial once it has been watched for long enough.
///
/// THE MATHS. Both percentages are driven by the same spend, so over any stretch with no window
/// reset, weekly points consumed divided by session points consumed IS the ratio. The two
/// capacities cancel and neither ever has to be known.
struct RatioMeasurement: Codable, Equatable {
    /// The previous poll's reading, kept so the next one has something to difference against.
    /// Percentages are REMAINING, matching `UsageData`, so consumption is previous minus current.
    var lastSessionRemaining: Double
    var lastSessionResetsAt: Date?
    var lastWeeklyRemaining: Double
    var lastWeeklyResetsAt: Date?
    /// Percentage points consumed across every clean interval so far. These grow for the life of
    /// the account and are never reset by a window rollover: a rollover invalidates the ONE
    /// interval that straddles it, not the history in front of it (KTD4).
    var sessionPointsConsumed: Double
    var weeklyPointsConsumed: Double

    /// WEEKLY points that must be accumulated before the measured ratio is allowed near the dial
    /// (KTD5).
    ///
    /// THE ARITHMETIC, so this is a number someone can check rather than a number someone liked.
    /// The API reports both percentages as whole integers, so every reading is a rounded value off
    /// by up to half a point either way, and every accumulated total is a sum of differences of
    /// whole numbers and is therefore itself a whole number.
    ///
    /// That is what sets the resolution. The ratio is weekly-over-session, so with the session
    /// total held fixed the reachable values sit on a grid one weekly point apart, and relative to
    /// the ratio itself that step is
    ///
    ///     (1 / sessionPoints) / (weeklyPoints / sessionPoints) = 1 / weeklyPoints
    ///
    /// The session total cancels out. How precise this measurement can be depends only on how many
    /// weekly points have been watched, whatever the plan, which is why the bar counts weekly
    /// points. Counting session points instead cannot work: 38 session points on Max 5x buys about
    /// 3 weekly points, a grid of one part in three, and no amount of averaging gets a value
    /// inside a grid coarser than the answer needs to be.
    ///
    /// What the resolution has to be good enough for. The ratio is a DIVISOR - the dial shows
    /// weeklyRemaining / ratio - so its relative error passes straight to the number on screen. It
    /// is never used to pick a plan out of the table. At 30 weekly points a whole point of rounding
    /// is 1/30 = 3.3% of the displayed number, and the 0.41-point standard deviation of a rounded
    /// difference (0.5 / sqrt(3) = 0.289 per reading, sqrt(2) of them) is 1.4%. A few percent on a
    /// dial that shows whole numbers is the accuracy worth waiting for. Below the bar the table
    /// value stands (AE9); at or above it the measurement takes over (AE8).
    ///
    /// What 30 weekly points costs the user is the session points that buy them, 30 / ratio: 227 on
    /// Max 20x, 273 on Pro, 379 on Max 5x. That is the "several hundred accumulated session points"
    /// KTD5 asked for, reached from the arithmetic rather than assumed.
    ///
    /// THE CAVEAT, stated rather than waved at. Consecutive clean intervals telescope to first
    /// reading minus last, so one unbroken run really does carry only the two readings' worth of
    /// error above. KTD4 deliberately keeps accumulating across rollovers, and a run broken into
    /// several stretches pays that error once per stretch, so it is noisier by roughly the square
    /// root of the number of stretches. Nothing downstream rescues that: `plausibleRange` below is
    /// about forty times wider than the whole published table and cannot see an error of a few
    /// percent. What contains it is that the totals keep growing after the bar is crossed while the
    /// error grows only as sqrt(stretches), so the measurement keeps converging and the crossing
    /// itself is the noisiest moment it will have.
    static let confidenceBar: Double = 30

    /// The band a measured ratio has to land in to be believed at all, easiest to read as how many
    /// full 5-hour windows a week's capacity would hold: 0.5 is two windows a week, 0.01 is a
    /// hundred. The published table sits between 7.6 windows (Max 20x) and 12.6 (Max 5x), so this
    /// is deliberately loose. It is not a second opinion on the table - it is there to catch a
    /// measurement that is not measuring anything.
    ///
    /// The way that happens is A3 being false: if session and weekly weight models differently
    /// there is no single ratio to find, and what comes out is arbitrary rather than merely
    /// imprecise - a weekly that barely moves against an enormous session total divides the weekly
    /// remainder into a huge number, and one that moves far too fast divides it into nothing. The
    /// case where the weekly never moved at all no longer arrives here: the bar counts weekly
    /// points, so a measurement with nothing on that side never produces a ratio in the first
    /// place.
    static let plausibleRange: ClosedRange<Double> = 0.01...0.5

    /// The measured ratio, or nil while there is no reason to trust one. Nil is the normal state
    /// for a long time after install, and the caller falls back to `PlanRatio` (D1).
    var ratio: Double? {
        // The session total is guarded only because this is a division: the same spend drives both
        // percentages, so a weekly total past the bar with nothing on the session side is not a
        // state real usage produces, and an infinity should not need the band below to stop it.
        guard weeklyPointsConsumed >= Self.confidenceBar, sessionPointsConsumed > 0 else { return nil }
        let measured = weeklyPointsConsumed / sessionPointsConsumed
        guard Self.plausibleRange.contains(measured) else { return nil }
        return measured
    }

    /// Fold one poll's reading into the measurement and hand back the new state.
    ///
    /// The interval between two polls only counts when it is CLEAN: both windows are the same
    /// windows as last time, judged by `resets_at`, and neither remainder has gone up. Anything
    /// else replaces the stored sample and adds nothing (KTD4). A rollover recorded as consumption
    /// would look like a whole window drained at once, and a rollover recorded as a negative would
    /// subtract usage that really happened - both corrupt the totals permanently, which is why the
    /// interval is discarded rather than repaired.
    ///
    /// Replacing the sample matters as much as not accumulating: without it the next poll would be
    /// differenced against a reading from the window before last.
    static func updated(from previous: RatioMeasurement?,
                        sessionRemaining: Double,
                        sessionResetsAt: Date?,
                        weeklyRemaining: Double,
                        weeklyResetsAt: Date?) -> RatioMeasurement {
        let sample = RatioMeasurement(lastSessionRemaining: sessionRemaining,
                                      lastSessionResetsAt: sessionResetsAt,
                                      lastWeeklyRemaining: weeklyRemaining,
                                      lastWeeklyResetsAt: weeklyResetsAt,
                                      sessionPointsConsumed: previous?.sessionPointsConsumed ?? 0,
                                      weeklyPointsConsumed: previous?.weeklyPointsConsumed ?? 0)

        guard let previous,
              sameWindow(previous.lastSessionResetsAt, sessionResetsAt),
              sameWindow(previous.lastWeeklyResetsAt, weeklyResetsAt) else { return sample }

        let sessionConsumed = previous.lastSessionRemaining - sessionRemaining
        let weeklyConsumed = previous.lastWeeklyRemaining - weeklyRemaining
        guard sessionConsumed >= 0, weeklyConsumed >= 0 else { return sample }

        var accumulated = sample
        accumulated.sessionPointsConsumed += sessionConsumed
        accumulated.weeklyPointsConsumed += weeklyConsumed
        return accumulated
    }

    /// Whether two reset times describe the same window.
    ///
    /// A missing time is never a match. That is the conservative reading and the necessary one:
    /// with no `resets_at` there is no way to tell a rollover from ordinary use, so an account
    /// whose API returns null reset times accumulates nothing at all and keeps the table value.
    ///
    /// Compared with a one-second tolerance rather than exact equality because the same instant
    /// reaches us in four shapes (bare ISO, fractional ISO, epoch seconds, epoch milliseconds -
    /// see `ResetDate`) and a sub-second difference between two of them is not a new window. A real
    /// rollover moves this by hours, so the tolerance can never hide one.
    private static func sameWindow(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) < 1
    }
}

struct UsageData: Equatable {
    let weeklyRemaining: Double
    let weeklyResetDate: Date?
    let sessionRemaining: Double
    let sessionResetDate: Date?
    let modelUsages: [ModelUsage]
    let usageCredits: UsageCreditsData?
    /// Whether each percentage above was actually read from the response, or defaulted.
    ///
    /// A missing percentage falls back to "nothing used yet" for DISPLAY, which is the least
    /// alarming thing to show for one poll. It is not an observation, though, and the measurement
    /// must never difference a real reading against an invented full window: that one interval
    /// books a whole window of points nobody spent and drags the measured ratio down until real
    /// usage outweighs it. Every decoder in this file is deliberately lenient (`try?`), so a null,
    /// a missing key or a changed type all arrive as nil rather than as an error, which is why this
    /// has to be recorded rather than assumed. `pollUsage` is what acts on it.
    let sessionPercentWasRead: Bool
    let weeklyPercentWasRead: Bool
    /// The active account's 5h-over-weekly capacity ratio, measured (`RatioMeasurement`) or off the
    /// table (`PlanRatio`), or nil when the plan is unknown and nothing has been measured yet. Nil
    /// disables the conversion entirely rather than substituting a guess (R3).
    private(set) var planRatio: Double?

    init(from response: UsageResponse, prepaidCredits: PrepaidCreditsResponse? = nil, planRatio: Double? = nil) {
        self.planRatio = planRatio
        let limits = response.limits

        // Session / weekly: prefer limits[] (newer shape), else the legacy per-field tiers.
        if let limit = limits?.first(where: { $0.kind == "session" }), let percent = limit.percent {
            sessionRemaining = UsageData.clamp(100 - percent)
            sessionResetDate = limit.resetsAt
            sessionPercentWasRead = true
        } else {
            let utilization = response.fiveHour?.utilization
            sessionRemaining = UsageData.clamp(100 - (utilization ?? 0))
            sessionResetDate = response.fiveHour?.resetsAt
            sessionPercentWasRead = utilization != nil
        }

        if let limit = limits?.first(where: { $0.kind == "weekly_all" }), let percent = limit.percent {
            weeklyRemaining = UsageData.clamp(100 - percent)
            weeklyResetDate = limit.resetsAt
            weeklyPercentWasRead = true
        } else {
            let utilization = response.sevenDay?.utilization
            weeklyRemaining = UsageData.clamp(100 - (utilization ?? 0))
            weeklyResetDate = response.sevenDay?.resetsAt
            weeklyPercentWasRead = utilization != nil
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

        usageCredits = UsageCreditsData.derive(spend: response.spend, prepaidCredits: prepaidCredits)
    }

    /// Attach the ratio this reading will be displayed with, after the fact.
    ///
    /// Separate from `init` because the MEASURED ratio is derived from this very reading's own
    /// numbers (R5): the reading has to exist before the ratio it gets shown with does. `init`
    /// keeps its parameter for the table-only path and for tests that state a ratio outright.
    mutating func applyPlanRatio(_ ratio: Double?) {
        planRatio = ratio
    }

    /// The weekly remainder expressed in SESSION units: how much of one 5-hour window the week's
    /// leftovers could still fill, 0...100. nil when the plan ratio is unknown and the weekly still
    /// has something left in it, because there is then no honest way to state the weekly on the
    /// session's scale.
    ///
    /// This replaces a 20-point floor (`weeklyGateFloor`) that used to gate the old comparison.
    /// Removing that floor is the point of this change, not a side effect: it only ever existed
    /// because the old code compared a weekly PERCENTAGE against a session PERCENTAGE, which
    /// means nothing, so it needed an arbitrary threshold to keep the nonsense contained. Once
    /// both sides are in the same units the plain minimum is correct at every level and there is
    /// nothing left for a threshold to protect against (R2).
    var weeklyRemainingInSessionUnits: Double? {
        // An exhausted week is the one weekly value that needs no ratio: 0 divided by any positive
        // ratio is 0, so the converted answer is the same on every plan and nothing is invented.
        // Answering "unknown" here would call the one certain case uncertain, and it would do it to
        // nearly everyone: `AccountStore.updatePlan` runs only on the sign-in and re-auth routes,
        // never from the poll, so every account carried over from v1.60 has no stored tier until it
        // signs in again, and a blocked user cannot spend, so the measurement never grows either.
        // Without this line that account reads a full green Session dial captioned "On Track" next
        // to a Weekly card at 0%, which is what v1.60 correctly showed as 0 and "Limited by weekly".
        if weeklyRemaining <= 0 { return 0 }
        // A non-positive ratio is not a ratio; guarding here also means a measured value that
        // collapses to zero can never divide into an infinity that reaches the dial.
        guard let planRatio, planRatio > 0 else { return nil }
        return UsageData.clamp(weeklyRemaining / planRatio)
    }

    /// True when the converted weekly is the tighter of the two limits, so the weekly - not the
    /// 5h session - is the wall the user hits next. The popover reads this for its "Limited by
    /// weekly" caption and to suppress the session time arc.
    ///
    /// With no plan ratio this is false everywhere except an exhausted week, and that silence in
    /// between is the honest answer rather than a dropped warning. One fact holds without a ratio:
    /// a 5-hour window is a fraction of a week, so the ratio is always below 1 and the converted
    /// weekly is therefore never SMALLER than the raw weekly percentage. That settles both ends and
    /// only the ends. At `weeklyRemaining == 0` the converted value is 0 on every plan, so the
    /// weekly binds for certain (handled in the conversion above). At `weeklyRemaining >=
    /// sessionRemaining` the converted weekly is at least the session, so the weekly certainly does
    /// NOT bind. In between - a low but non-zero weekly on an unknown plan - it genuinely cannot be
    /// told: 6% of a week is 76% of a Max 5x session and 45% of a Max 20x one, so whether it
    /// undercuts the session depends entirely on which plan the account is on. Saying "Limited by
    /// weekly" there is the guess D4 forbids, and the v1.60 test that said it
    /// (`weeklyRemaining < sessionRemaining && weeklyRemaining < 20`) is the cross-unit comparison
    /// R2 deleted, which claimed the weekly bound at weekly 19 on Max 20x where it does not. The low
    /// week is not hidden meanwhile: the Weekly card sits beside this one and every menu-bar
    /// renderer draws the weekly red below 20.
    var isSessionWeeklyLimited: Bool {
        guard let converted = weeklyRemainingInSessionUnits else { return false }
        return converted < sessionRemaining
    }

    /// The Session value every surface DISPLAYS: the true 5h-session remaining, capped to what
    /// the week's leftovers can actually fill, `min(sessionRemaining, weeklyRemaining / ratio)`
    /// clamped to 0...100 (R1). With no ratio it is the raw session value, unconverted (R3) - except
    /// on an exhausted week, which converts to 0 on every plan and so needs no ratio.
    /// Used by both the popover dial and the menu-bar icons - they must never disagree about a
    /// number both label "Session". Display-only: raw `sessionRemaining` stays untouched for the
    /// #31 session run-out forecast and pace, which grade the real 5h window.
    var sessionDisplayRemaining: Double {
        guard let converted = weeklyRemainingInSessionUnits else { return sessionRemaining }
        return min(sessionRemaining, converted)
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

/// Raw API response from /api/organizations/{orgId}/prepaid/credits. `currency` drives
/// currency-aware formatting (KTD6); `amount` is the balance in minor units. Unknown keys
/// (auto-reload settings, pending invoice, etc.) are ignored by the lenient decode.
struct PrepaidCreditsResponse: Codable {
    let amount: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case amount, currency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        amount = try? container.decode(Double.self, forKey: .amount)
        currency = try? container.decode(String.self, forKey: .currency)
    }
}

// MARK: - Diagnostics: the plan sample

extension UsageService {
    /// The milestone kind for one poll's plan reading (R6).
    ///
    /// WHY THIS EXISTS. The only `rate_limit_tier` string anyone here has ever seen is
    /// `default_claude_max_20x`, because that is the plan the developer is on. The Pro and Max 5x
    /// strings in `PlanRatio.forTier` are copied from third-party code describing a DIFFERENT API,
    /// and the ratios for those two plans are the least validated numbers in the app. A reporter on
    /// one of those plans is the only way to confirm either: they turn on diagnostic logging, use
    /// the app normally, export, and send back a file whose plan samples carry their real tier
    /// string and enough readings to derive their real ratio.
    ///
    /// It rides the existing opt-in export and adds no second mechanism: `emitMilestone` does
    /// nothing until the user turns diagnostic logging on, and every line it writes goes through
    /// `SecretRedactor` before it is written or exported.
    ///
    /// `nonisolated` for the same reason as `planSamplePayload` below: a constant with nothing
    /// behind it, read from tests that have no main actor.
    nonisolated static let planSampleKind = "plan-sample"

    /// One poll's reading, as the payload for `planSampleKind`.
    ///
    /// WHAT IS DELIBERATELY NOT HERE: the org name, the org uuid, and the account's address. The
    /// question this answers is "what does this plan report and what is its real ratio", and none
    /// of those three help answer it. The org name matters most: the organizations response returns
    /// names shaped like "someone@gmail.com's Organization", so emitting it would put an address in
    /// an exported file for every account that has never been renamed. `SecretRedactor` does catch
    /// an address embedded mid-string - confirmed, and pinned by a test in `NoSecretsExportGateTests`
    /// - but not emitting it at all is the guarantee, and the redactor is the backstop behind it.
    ///
    /// `account` is a one-way 8-character tag of the account's locally generated id, not the id
    /// itself. Without something to tell readings apart, a user who switches between two accounts
    /// exports one interleaved sequence and nobody can take a ratio from it. The tag identifies
    /// nothing outside the install that wrote it: the id it hashes exists only in that install's
    /// UserDefaults and is never sent anywhere.
    ///
    /// Both ratios are carried because they answer different questions. `applied_ratio` is what the
    /// dial actually divided by, so a reporter's screenshot can be reproduced from the file.
    /// `measured_ratio` is what this account's own usage says the ratio is, which is the number
    /// that would correct the table (R5, D3), and it stays null until the measurement clears its
    /// confidence bar.
    ///
    /// `nonisolated` because it reads nothing but its arguments, the same shape as
    /// `AuthManager.selectOrg` and `isPlaceholderEmail`: a pure rule that can be tested without a
    /// service, a store or a main actor behind it.
    nonisolated static func planSamplePayload(accountId: UUID,
                                              rateLimitTier: String?,
                                              capabilities: [String]?,
                                              billingType: String?,
                                              usage: UsageData,
                                              measurement: RatioMeasurement) -> [String: Any] {
        // Reset times go out as ISO 8601 strings, which is how a reader spots the window rollovers
        // that make an interval unusable (KTD4) - the same rule the measurement itself applies.
        // Built here rather than shared as a static: `ISO8601DateFormatter` is not Sendable, this
        // runs once every couple of minutes, and a local costs nothing next to the HTTP round trip
        // that produced the reading.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return [
            "account": SecretRedactor.sha256Prefix(accountId.uuidString),
            "rate_limit_tier": jsonOrNull(rateLimitTier),
            "capabilities": jsonOrNull(capabilities),
            "billing_type": jsonOrNull(billingType),
            "session_remaining": usage.sessionRemaining,
            "session_resets_at": jsonOrNull(usage.sessionResetDate.map(iso.string(from:))),
            "weekly_remaining": usage.weeklyRemaining,
            "weekly_resets_at": jsonOrNull(usage.weeklyResetDate.map(iso.string(from:))),
            "session_points_consumed": measurement.sessionPointsConsumed,
            "weekly_points_consumed": measurement.weeklyPointsConsumed,
            "measured_ratio": jsonOrNull(measurement.ratio),
            "applied_ratio": jsonOrNull(usage.planRatio)
        ]
    }

    /// JSON `null` for an absent value, rather than leaving the key out.
    ///
    /// Absence has to be written down. A reader deriving a ratio from these lines needs to tell
    /// "this account has no measured ratio yet" apart from "this build did not emit the field",
    /// and a missing key cannot say which. `JSONSerialization` rejects a Swift nil and accepts
    /// `NSNull`, and `DiagnosticsLogger.serialize` degrades the WHOLE line to `serialize-failed`
    /// if any value in the payload is one it cannot encode - so a Date or a bare nil here would
    /// silently throw away the sample rather than fail loudly.
    nonisolated private static func jsonOrNull<T>(_ value: T?) -> Any {
        if let value { return value }
        return NSNull()
    }
}
