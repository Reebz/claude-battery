import Combine
import SwiftUI
import UserNotifications

@main
struct ClaudeBatteryApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Settings {
            SettingsView(signOut: { [weak appDelegate] in appDelegate?.signOut() })
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var keychain: KeychainService!
    private var authManager: AuthManager!
    private var usageService: UsageService!
    private var menuBarController: MenuBarController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        keychain = KeychainService()
        authManager = AuthManager(keychain: keychain)
        usageService = UsageService(keychain: keychain)

        // Wire auth failure callback
        usageService.onAuthFailure = { [weak self] in
            self?.usageService.stopPolling()
            self?.authManager.handleAuthFailure()
        }

        menuBarController = MenuBarController(
            authManager: authManager,
            usageService: usageService
        )

        // Set notification delegate early
        UNUserNotificationCenter.current().delegate = usageService

        // Start polling if already authenticated
        if authManager.isAuthenticated {
            usageService.startPolling()
        }

        // Observe auth state changes to start/stop polling
        authManager.$isAuthenticated
            .dropFirst() // Skip the initial value (already handled above)
            .receive(on: RunLoop.main)
            .sink { [weak self] isAuthenticated in
                guard let self else { return }
                if isAuthenticated {
                    self.usageService.startPolling()
                } else {
                    self.usageService.stopPolling()
                }
            }
            .store(in: &cancellables)
    }

    nonisolated func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            usageService?.stopPolling()
        }
    }

    func signOut() {
        usageService.stopPolling()
        Task {
            await authManager.signOut()
        }
    }
}
