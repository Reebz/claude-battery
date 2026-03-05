import AppKit
import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "UpdateChecker")

@MainActor
class UpdateChecker: NSObject, ObservableObject {
    @Published var availableVersion: String?
    @Published var downloadURL: URL?

    private var timer: Timer?
    private var currentCheckTask: Task<Void, Never>?

    private enum Constants {
        static let checkInterval: TimeInterval = 86400  // 24 hours
        static let timerTolerance: TimeInterval = 300    // 5 minutes
        static let releasesURL = "https://api.github.com/repos/Reebz/claude-battery/releases/latest"
        static let allowedHosts: Set<String> = ["github.com", "www.github.com"]
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    override init() {
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

    func startChecking() {
        currentCheckTask?.cancel()
        currentCheckTask = Task { await checkForUpdate() }
        scheduleNextCheck()
    }

    func stopChecking() {
        timer?.invalidate()
        timer = nil
        currentCheckTask?.cancel()
        currentCheckTask = nil
    }

    private func scheduleNextCheck() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Constants.checkInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentCheckTask = Task { await self.checkForUpdate() }
                self.scheduleNextCheck()
            }
        }
        timer?.tolerance = Constants.timerTolerance
    }

    private func checkForUpdate() async {
        guard let url = URL(string: Constants.releasesURL) else { return }

        var request = URLRequest(url: url)
        request.setValue("claude-battery", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await Self.session.data(for: request)

            guard !Task.isCancelled else { return }

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.debug("Update check returned HTTP \(status)")
                return
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(GitHubRelease.self, from: data)

            let remoteVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            guard isValidVersion(remoteVersion) else {
                logger.warning("Invalid version format: \(remoteVersion)")
                return
            }

            guard let parsedURL = URL(string: release.htmlUrl),
                  let host = parsedURL.host?.lowercased(),
                  Constants.allowedHosts.contains(host),
                  parsedURL.scheme == "https" else {
                logger.warning("Update URL rejected: \(release.htmlUrl)")
                return
            }

            if remoteVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                availableVersion = remoteVersion
                downloadURL = parsedURL
                logger.info("Update available: v\(remoteVersion)")
            } else {
                availableVersion = nil
                downloadURL = nil
            }
        } catch {
            logger.debug("Update check failed: \(error.localizedDescription)")
        }
    }

    private func isValidVersion(_ version: String) -> Bool {
        version.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil
    }

    // MARK: - Wake

    @objc private func handleWake() {
        currentCheckTask?.cancel()
        currentCheckTask = Task { await checkForUpdate() }
        scheduleNextCheck()
    }
}

private struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
}
