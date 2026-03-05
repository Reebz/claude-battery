import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "UpdateChecker")

@MainActor
class UpdateChecker: ObservableObject {
    @Published var availableVersion: String?
    @Published var downloadURL: URL?

    private var timer: Timer?

    private enum Constants {
        static let checkInterval: TimeInterval = 86400  // 24 hours
        static let timerTolerance: TimeInterval = 300    // 5 minutes
        static let releasesURL = "https://api.github.com/repos/Reebz/claude-battery/releases/latest"
    }

    func startChecking() {
        Task { await checkForUpdate() }
        scheduleNextCheck()
    }

    func stopChecking() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleNextCheck() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Constants.checkInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.checkForUpdate()
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
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                #if DEBUG
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.debug("Update check returned HTTP \(status)")
                #endif
                return
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(GitHubRelease.self, from: data)

            let remoteVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            if remoteVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                availableVersion = remoteVersion
                downloadURL = URL(string: release.htmlUrl)
                logger.info("Update available: v\(remoteVersion)")
            } else {
                availableVersion = nil
                downloadURL = nil
            }
        } catch {
            #if DEBUG
            logger.debug("Update check failed: \(error.localizedDescription)")
            #endif
        }
    }
}

private struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
}
