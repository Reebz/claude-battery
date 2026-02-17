import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

struct SettingsView: View {
    @ObservedObject var accountStore: AccountStore
    let authManager: AuthManager
    let closeWindow: () -> Void

    @State private var launchAtLogin = false
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @State private var confirmRemoveId: UUID?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onAppear {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section {
                Toggle("Low usage notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { newValue in
                        if newValue {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        }
                    }
            }

            // Account management section
            Section(header: Text("Accounts")) {
                if accountStore.accounts.isEmpty {
                    HStack {
                        Spacer()
                        Text("No accounts")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    ForEach(accountStore.accounts) { account in
                        accountRow(account: account)
                    }
                }

                if accountStore.canAddAccount {
                    Button("Add Account") {
                        authManager.presentLogin()
                    }
                }
            }

            Section {
                Button(action: {
                    if let url = URL(string: "https://www.buymeacoffee.com/reebz") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "cup.and.saucer.fill")
                            .foregroundColor(.black)
                        Text("Buy me a coffee!")
                            .font(.custom("Cookie-Regular", size: 20))
                            .foregroundColor(.black)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(Color(red: 1.0, green: 0.867, blue: 0.0))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.black, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: settingsHeight)
    }

    private var settingsHeight: CGFloat {
        // Base height covers toggles + coffee button + section padding
        let base: CGFloat = 310
        // Each account row: ~40pt, plus ~45pt for threshold slider when notifications on
        let perAccount: CGFloat = notificationsEnabled ? 85 : 40
        let accountCount = CGFloat(max(accountStore.accounts.count, 1))
        // Add Account button + section header
        let accountSection: CGFloat = 60 + (accountCount * perAccount)
        let ideal = base + accountSection
        // Cap at 90% of screen height so it never overflows
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return min(ideal, screenHeight * 0.9)
    }

    @ViewBuilder
    private func accountRow(account: Account) -> some View {
        let isActive = account.id == accountStore.activeAccountId

        HStack {
            Circle()
                .fill(isActive ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .font(.body)
                if account.nickname != nil {
                    Text(account.email)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if confirmRemoveId == account.id {
                Button("Cancel") {
                    confirmRemoveId = nil
                }
                .font(.caption)

                Button("Confirm") {
                    authManager.signOut(accountId: account.id)
                    confirmRemoveId = nil
                }
                .font(.caption)
                .foregroundColor(.red)
            } else {
                Button("Remove") {
                    confirmRemoveId = account.id
                }
                .font(.caption)
                .foregroundColor(.red)
            }
        }

        if notificationsEnabled {
            VStack(alignment: .leading, spacing: 2) {
                Text("Alert below \(Int(account.notificationThreshold))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Slider(
                    value: Binding(
                        get: { account.notificationThreshold },
                        set: { accountStore.updateThreshold(account.id, $0) }
                    ),
                    in: 5...50,
                    step: 5
                )
            }
            .padding(.leading, 16)
        }
    }
}
