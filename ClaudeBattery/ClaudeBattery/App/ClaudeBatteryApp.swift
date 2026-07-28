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

        // Wire auth success callback — restarts polling after any successful
        // authentication, including re-auth to the same org where $activeAccountId
        // doesn't change and the Combine subscriber below won't fire.
        authManager.onAuthSuccess = { [weak self] in
            self?.usageService.switchAccount()
        }

        // Pause polling across the network windows of a manual sign-in (R11, issue #41). Two narrow
        // callbacks rather than handing AuthManager the polling service, which it has never held
        // and does not need to know about (KTD7). A poll answered mid-sign-in picks up whichever
        // cookies are in the shared jar when the request goes out, so it can be answered with the
        // pasted account's credentials and 403 a healthy account into an expired state.
        authManager.onSuspendPolling = { [weak self] in
            self?.usageService.suspendPolling()
        }
        authManager.onResumePolling = { [weak self] in
            self?.usageService.resumePolling()
        }

        // Say how many organizations a browser sign-in repaired (R6, issue #41). The manual paste
        // path returns its confirmation and Settings prints it inline; this path closes its window
        // and returns nothing, so an alert is the only place the count can land. Presented on the
        // next main-actor turn so the sign-in window has finished closing first - the message is
        // about a finished sign-in, not a step inside one.
        authManager.onSignInConfirmation = { message in
            Task { @MainActor in
                // LSUIElement app: without this the alert can open behind whatever the user is
                // looking at, the same reason every other window here activates first.
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Sign-in complete"
                alert.informativeText = message
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }

        updateChecker = UpdateChecker()
        updateChecker.startChecking()

        menuBarController = MenuBarController(
            accountStore: accountStore,
            authManager: authManager,
            usageService: usageService,
            updateChecker: updateChecker
        )

        // Route the login error overlay's "Sign in manually" button to the Settings paste
        // section (U5) so a user whose account can't complete the embedded flow has a floor.
        authManager.onManualSignInRequested = { [weak self] in
            self?.menuBarController.showSettings()
        }

        // Set notification delegate early
        UNUserNotificationCenter.current().delegate = usageService

        // Start polling if we have an active account, or auto-present
        // sign-in if this is a fresh install with no accounts
        if accountStore.activeAccount != nil {
            usageService.startPolling()
        } else if accountStore.accounts.isEmpty {
            authManager.presentLogin()
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

    func applicationWillTerminate(_ notification: Notification) {
        // Write the diagnostic session-end marker + final synchronize on quit. No-op when
        // diagnostic logging is disabled (the gate inside flush handles it).
        DiagnosticsLogger.shared.flush()
    }
}
