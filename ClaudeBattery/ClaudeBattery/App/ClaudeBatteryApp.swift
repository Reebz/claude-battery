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
    private var storage: StorageService!
    var accountStore: AccountStore!
    var authManager: AuthManager!
    private var usageService: UsageService!
    private var updateChecker: UpdateChecker!
    private var menuBarController: MenuBarController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        storage = StorageService()
        accountStore = AccountStore(storage: storage)
        authManager = AuthManager(storage: storage, accountStore: accountStore)
        usageService = UsageService(storage: storage, accountStore: accountStore)

        // Wire auth failure callback
        usageService.onAuthFailure = { [weak self] in
            self?.usageService.stopPolling()
            self?.authManager.handleAuthFailure()
        }

        updateChecker = UpdateChecker()
        updateChecker.startChecking()

        menuBarController = MenuBarController(
            accountStore: accountStore,
            authManager: authManager,
            usageService: usageService,
            updateChecker: updateChecker
        )

        // Set notification delegate early
        UNUserNotificationCenter.current().delegate = usageService

        // Start polling if we have an active account, or show sign-in on first launch
        if accountStore.activeAccount != nil {
            usageService.startPolling()
        } else if accountStore.accounts.isEmpty {
            // First launch with no accounts — show sign-in window so users aren't
            // left with an invisible/unauthenticated menu bar icon and no way to start
            DispatchQueue.main.async { [weak self] in
                self?.authManager.presentLogin()
            }
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
