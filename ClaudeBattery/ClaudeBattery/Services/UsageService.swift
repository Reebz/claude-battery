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

    private let keychain: KeychainService
    private var timer: Timer?
    private var isPolling = false
    private var didNotifyBelowThreshold = false

    var notificationThreshold: Double {
        get {
            let value = UserDefaults.standard.double(forKey: "notificationThreshold")
            return value.isZero ? Constants.defaultNotificationThreshold : value
        }
        set { UserDefaults.standard.set(newValue, forKey: "notificationThreshold") }
    }

    init(keychain: KeychainService) {
        self.keychain = keychain
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
        Task { await pollUsage() }
        scheduleNextPoll()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNextPoll() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.pollUsage()
                self?.scheduleNextPoll()
            }
        }
        timer?.tolerance = 30
    }

    func pollUsage() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        guard let sessionKey = keychain.read(forKey: KeychainService.Keys.sessionKey),
              let orgId = keychain.read(forKey: KeychainService.Keys.organizationId) else {
            logger.warning("Poll skipped — missing credentials")
            return
        }

        let expiration = UserDefaults.standard.object(forKey: "sessionKeyExpiration") as? Date
        if let expiration, expiration < Date() {
            logger.info("Session cookie expired, triggering re-auth")
            onAuthFailure?()
            return
        }

        guard let request = ClaudeAPI.makeRequest(path: "/api/organizations/\(orgId)/usage", sessionKey: sessionKey) else {
            logger.error("Failed to construct usage API URL")
            return
        }

        do {
            let (data, response) = try await ClaudeAPI.session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                consecutiveFailures += 1
                logger.error("Non-HTTP response received")
                return
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                logger.info("Auth failure (HTTP \(httpResponse.statusCode))")
                onAuthFailure?()
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                consecutiveFailures += 1
                let body = String(data: data, encoding: .utf8) ?? "(non-utf8)"
                logger.warning("Unexpected HTTP status: \(httpResponse.statusCode) body: \(body.prefix(500))")
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

            latestUsage = UsageData(from: usage)
            lastSuccessfulFetch = Date()
            consecutiveFailures = 0

            if let weeklyRemaining = latestUsage?.weeklyRemaining {
                checkAndNotify(remaining: weeklyRemaining, threshold: notificationThreshold)
            }
        } catch {
            consecutiveFailures += 1
            logger.error("Poll failed: \(error)")
        }
    }

    var onAuthFailure: (() -> Void)?

    // MARK: - Notifications

    private func checkAndNotify(remaining: Double, threshold: Double) {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }

        if remaining < threshold && !didNotifyBelowThreshold {
            didNotifyBelowThreshold = true
            scheduleNotification(remaining: remaining)
        } else if remaining >= threshold {
            didNotifyBelowThreshold = false
        }
    }

    private func scheduleNotification(remaining: Double) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                logger.info("Notifications not authorized (status: \(String(describing: settings.authorizationStatus)))")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Claude Usage Low"
            content.body = String(format: "Weekly quota is at %.0f%% remaining.", remaining)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "low-usage",
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
        timer?.invalidate()
        Task {
            await pollUsage()
            scheduleNextPoll()
        }
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
        resetsAt = try? container.decode(Date.self, forKey: .resetsAt)
    }
}

struct UsageData {
    let weeklyRemaining: Double
    let weeklyResetDate: Date?
    let sessionRemaining: Double
    let sessionResetDate: Date?
    let opusRemaining: Double
    let opusResetDate: Date?
    let sonnetRemaining: Double
    let sonnetResetDate: Date?

    init(from response: UsageResponse) {
        weeklyRemaining = max(0, min(100, 100 - (response.sevenDay?.utilization ?? 0)))
        weeklyResetDate = response.sevenDay?.resetsAt
        sessionRemaining = max(0, min(100, 100 - (response.fiveHour?.utilization ?? 0)))
        sessionResetDate = response.fiveHour?.resetsAt
        opusRemaining = max(0, min(100, 100 - (response.sevenDayOpus?.utilization ?? 0)))
        opusResetDate = response.sevenDayOpus?.resetsAt
        sonnetRemaining = max(0, min(100, 100 - (response.sevenDaySonnet?.utilization ?? 0)))
        sonnetResetDate = response.sevenDaySonnet?.resetsAt
    }
}
