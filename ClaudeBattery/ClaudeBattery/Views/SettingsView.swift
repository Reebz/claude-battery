import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

struct SettingsView: View {
    let isAuthenticated: Bool
    let signOut: () -> Void
    let signIn: () -> Void
    let closeWindow: () -> Void

    @State private var launchAtLogin = false
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("notificationThreshold") private var notificationThreshold: Double = 20

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
                Toggle("Low usage notification", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { newValue in
                        if newValue {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        }
                    }

                if notificationsEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alert when weekly quota drops below \(Int(notificationThreshold))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $notificationThreshold, in: 5...50, step: 5)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    if isAuthenticated {
                        Button("Sign Out") {
                            signOut()
                            closeWindow()
                        }
                        .foregroundColor(.red)
                    } else {
                        Button("Sign In") {
                            signIn()
                            closeWindow()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
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
        .frame(width: 350, height: 380)
    }
}
