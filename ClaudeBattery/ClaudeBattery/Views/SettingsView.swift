import SwiftUI
import ServiceManagement
import UserNotifications

struct SettingsView: View {
    let signOut: () -> Void

    @State private var launchAtLogin = false
    @State private var notificationsEnabled = false
    @State private var notificationThreshold: Double = 20

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
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                                if !granted {
                                    Task { @MainActor in
                                        notificationsEnabled = false
                                    }
                                }
                            }
                        }
                        UserDefaults.standard.set(newValue, forKey: "notificationsEnabled")
                    }
                    .onAppear {
                        notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
                        notificationThreshold = UserDefaults.standard.double(forKey: "notificationThreshold")
                        if notificationThreshold == 0 { notificationThreshold = 20 }
                    }

                if notificationsEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Alert when weekly quota drops below \(Int(notificationThreshold))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $notificationThreshold, in: 5...50, step: 5)
                            .onChange(of: notificationThreshold) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "notificationThreshold")
                            }
                    }
                }
            }

            Section {
                Button("Sign Out") {
                    signOut()
                }
                .foregroundColor(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 280)
    }
}
