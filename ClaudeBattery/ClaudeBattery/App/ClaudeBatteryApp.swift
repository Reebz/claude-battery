import Combine
import SwiftUI
import UserNotifications

@main
struct ClaudeBatteryApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Settings {
            if let accountStore = appDelegate.accountStore,
               let authManager = appDelegate.authManager {
                SettingsView(
                    accountStore: accountStore,
                    authManager: authManager,
                    closeWindow: { NSApp.keyWindow?.close() }
                )
            }
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var keychain: KeychainService!
    var accountStore: AccountStore!
    var authManager: AuthManager!
    private var usageService: UsageService!
    private var menuBarController: MenuBarController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        keychain = KeychainService()
        accountStore = AccountStore(keychain: keychain)
        authManager = AuthManager(keychain: keychain, accountStore: accountStore)
        usageService = UsageService(keychain: keychain, accountStore: accountStore)

        // Wire auth failure callback
        usageService.onAuthFailure = { [weak self] in
            self?.usageService.stopPolling()
            self?.authManager.handleAuthFailure()
        }

        menuBarController = MenuBarController(
            accountStore: accountStore,
            authManager: authManager,
            usageService: usageService
        )

        // Set notification delegate early
        UNUserNotificationCenter.current().delegate = usageService

        // Start polling if we have an active account
        if accountStore.activeAccount != nil {
            usageService.startPolling()
        }

        // Observe active account changes to start/stop polling
        accountStore.$activeAccountId
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] activeId in
                guard let self else { return }
                if activeId != nil {
                    self.usageService.switchAccount()
                } else {
                    self.usageService.stopPolling()
                }
            }
            .store(in: &cancellables)
    }
}
