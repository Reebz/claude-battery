import AppKit
import Foundation
import UserNotifications

@MainActor
class UsageService: NSObject, ObservableObject {
    @Published var latestUsage: UsageData?
    @Published var lastSuccessfulFetch: Date?
    @Published private(set) var consecutiveFailures: Int = 0

    var isStale: Bool {
        guard let last = lastSuccessfulFetch else { return true }
        return Date().timeIntervalSince(last) > 660
    }

    var pollInterval: TimeInterval {
        if consecutiveFailures < 3 { return 120 }
        if consecutiveFailures < 6 { return 300 }
        if consecutiveFailures < 10 { return 600 }
        return 1800
    }

    private let keychain: KeychainService
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var isPolling = false
    private var didNotifyBelowThreshold = false

    var notificationThreshold: Double {
        get { UserDefaults.standard.double(forKey: "notificationThreshold").isZero ? 20.0 : UserDefaults.standard.double(forKey: "notificationThreshold") }
        set { UserDefaults.standard.set(newValue, forKey: "notificationThreshold") }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    init(keychain: KeychainService) {
        self.keychain = keychain
        super.init()

        // Subscribe to wake notifications
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
        activity = ProcessInfo.processInfo.beginActivity(
            options: [],
            reason: "Menu bar usage polling"
        )
        Task { await pollUsage() }
        scheduleNextPoll()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
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

        // Check if keychain is locked (screen locked)
        if keychain.isKeychainLocked {
            return // Skip without incrementing failures
        }

        guard let sessionKey = keychain.read(forKey: "sessionKey"),
              let orgId = keychain.read(forKey: "organizationId") else {
            return
        }

        let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("1.0.0", forHTTPHeaderField: "anthropic-client-version")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("https://claude.ai", forHTTPHeaderField: "origin")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "referer")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                consecutiveFailures += 1
                return
            }

            // Auth failure
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                onAuthFailure?()
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                consecutiveFailures += 1
                return
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            let usage = try decoder.decode(UsageResponse.self, from: data)

            latestUsage = UsageData(from: usage)
            lastSuccessfulFetch = Date()
            consecutiveFailures = 0

            // Check notification threshold
            if let weeklyRemaining = latestUsage?.weeklyRemaining {
                checkAndNotify(remaining: weeklyRemaining, threshold: notificationThreshold)
            }
        } catch {
            consecutiveFailures += 1
        }
    }

    // Called by AppDelegate to wire auth failure
    var onAuthFailure: (() -> Void)?

    // MARK: - Notifications

    private func checkAndNotify(remaining: Double, threshold: Double) {
        if remaining < threshold && !didNotifyBelowThreshold {
            didNotifyBelowThreshold = true
            scheduleNotification(remaining: remaining)
        } else if remaining >= threshold {
            didNotifyBelowThreshold = false
        }
    }

    private func scheduleNotification(remaining: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Claude Usage Low"
        content.body = String(format: "Weekly quota is at %.0f%% remaining.", remaining)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "low-usage",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
    let fiveHour: UsageTier
    let sevenDay: UsageTier
    let sevenDayOpus: UsageTier
    let sevenDaySonnet: UsageTier
}

struct UsageTier: Codable {
    let utilization: Double
    let resetsAt: Date?
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
        weeklyRemaining = max(0, min(100, 100 - response.sevenDay.utilization))
        weeklyResetDate = response.sevenDay.resetsAt
        sessionRemaining = max(0, min(100, 100 - response.fiveHour.utilization))
        sessionResetDate = response.fiveHour.resetsAt
        opusRemaining = max(0, min(100, 100 - response.sevenDayOpus.utilization))
        opusResetDate = response.sevenDayOpus.resetsAt
        sonnetRemaining = max(0, min(100, 100 - response.sevenDaySonnet.utilization))
        sonnetResetDate = response.sevenDaySonnet.resetsAt
    }
}
