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
    @AppStorage(MenuBarDefaults.showSessionCountdownKey) private var showSessionCountdown = false
    @AppStorage("iconStyle") private var iconStyleRaw: String = IconStyle.dualHorizontal.rawValue
    @State private var confirmRemoveId: UUID?
    /// Scales the decorative coffee-button font with Dynamic Type (the only fixed-size SwiftUI font
    /// in this view); the rest use semantic styles.
    @ScaledMetric(relativeTo: .body) private var coffeeFontSize: CGFloat = 20

    var body: some View {
        Form {
            Section("Icon Style") {
                Picker("Menu bar icon", selection: $iconStyleRaw) {
                    ForEach(IconStyle.allCases, id: \.self) { style in
                        Text(style.rawValue).tag(style.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }

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

            Section {
                Toggle("Show session countdown in menu bar", isOn: $showSessionCountdown)
                Text("Adds a compact session countdown (e.g. \"4h+\", \"32m\") to the left of the menu bar icon. Hidden when there is no active session.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

            // No canAddAccount gate here, deliberately. A refresh consumes no entry slot, so hiding
            // the paste box at the limit locked out the only repair route that still works there
            // (R9, issue #41). It must also stay visible at zero accounts, where Google-federated
            // and passkey users start: they cannot complete the embedded browser window at all, so
            // narrowing this to "some account exists" would break their first sign-in instead.
            ManualSignInSection(authManager: authManager)

            DiagnosticsSection()

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
                            .font(.custom("Cookie-Regular", size: coffeeFontSize))
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
        // Base height covers toggles + coffee button + the manual sign-in and Diagnostics sections,
        // INCLUDING headroom for their post-interaction growth — the diagnostics export status +
        // issues link, and the manual-sign-in status + org picker + button — which are subview
        // @State not visible to this calc. The 90% screen cap below is the backstop on small
        // displays. (The +110/+30 over the prior 570/440 is that headroom.)
        // +50 over the prior 680/470 covers the session-countdown toggle row + its caption.
        // Unconditional now. This used to be `canAddAccount ? 730 : 520`, and the 520 branch was
        // small only because the manual sign-in section vanished at the entry limit. That section
        // always renders (R9, issue #41), so the short branch would under-allocate it by ~210pt.
        let base: CGFloat = 730
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
                Text(accountStore.disambiguatedName(for: account))
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

// MARK: - Manual sign-in (U5 — the universal paste floor)

/// Settings section for pasting a claude.ai cookie header to sign in without the WebView.
/// The true "nobody is ever fully locked out" floor: works for Google-federated and
/// passkey-only accounts that cannot complete the embedded flow.
private struct ManualSignInSection: View {
    let authManager: AuthManager

    @State private var pasted = ""
    @State private var isResolving = false
    @State private var statusText: String?
    @State private var statusIsError = false
    @State private var orgChoices: [Organization] = []
    @State private var selectedOrgIndex = 0

    var body: some View {
        Section(header: Text("Manual sign-in")) {
            Text("Stuck on the sign-in window? Paste your claude.ai cookie header to sign in manually. This works for every account, including Google and passkey.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Paste cookie header", text: $pasted)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .accessibilityLabel("Cookie header")

            HStack(spacing: 8) {
                Button("Validate & Add") { validate() }
                    .disabled(pasted.isEmpty || isResolving)
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Validating")
                }
            }

            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(statusText)
            }

            if !orgChoices.isEmpty {
                Picker("Organization", selection: $selectedOrgIndex) {
                    ForEach(Array(orgChoices.enumerated()), id: \.offset) { index, org in
                        let alreadyAdded = authManager.accountStore.accounts.contains { $0.organizationId == org.uuid }
                        Text(alreadyAdded ? "\(org.displayName) (already added)" : org.displayName).tag(index)
                    }
                }
                Button("Use this organization") { chooseOrg() }
            }

            DisclosureGroup("How do I find my cookie header?") {
                Text("1. Sign in to claude.ai in your browser.\n2. Open Developer Tools (Option-Cmd-I) and select the Network tab.\n3. Refresh the page, then click any request to claude.ai.\n4. Under Request Headers, copy the entire value of the \"Cookie\" header.\n5. Paste it above.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Full instructions", destination: URL(string: "https://github.com/Reebz/claude-battery#manual-sign-in")!)
                    .font(.caption)
            }
        }
    }

    private func validate() {
        isResolving = true
        statusText = nil
        orgChoices = []
        let input = pasted
        Task {
            let result = await authManager.manualSignIn(input)
            isResolving = false
            apply(result)
        }
    }

    private func chooseOrg() {
        guard selectedOrgIndex >= 0, selectedOrgIndex < orgChoices.count else { return }
        let org = orgChoices[selectedOrgIndex]
        orgChoices = []
        apply(authManager.completeManualSignIn(org: org))
    }

    private func apply(_ result: ManualSignInResult) {
        switch result {
        case .success(let name, let refreshedCount):
            statusIsError = false
            // One pick can repair the picked org's stored siblings as well (R2, issue #41), so name
            // the count rather than let that happen silently. The sentence is built by a pure helper
            // next to `repairConfirmation` rather than here, because nothing in this project can
            // test a view body (KTD9) and the composition was the untested half (review finding).
            statusText = AuthManager.signInConfirmation(name: name, refreshedCount: refreshedCount)
            pasted = ""
            orgChoices = []
        case .needsOrgChoice(let orgs):
            orgChoices = orgs
            selectedOrgIndex = 0
            statusIsError = false
            statusText = "Multiple organizations found. Choose one to finish."
        case .alreadySignedInAllOrgs(let refreshedCount, let activeAccountRefreshed):
            // Not an error: the paste worked. But when the account being viewed was deliberately not
            // among those repaired, the shared builder says so and names the next step, instead of a
            // green count printed over a menu bar still showing the failure marker (R6, D6).
            statusIsError = false
            statusText = AuthManager.repairConfirmation(refreshedCount: refreshedCount,
                                                        viewedAccountRepaired: activeAccountRefreshed)
            pasted = ""
            orgChoices = []
        case .invalidInput:
            statusIsError = true
            statusText = "That doesn't look like a cookie header. Paste the full Cookie value, or your sessionKey."
        case .authFailed(let suggestFullHeader):
            statusIsError = true
            statusText = suggestFullHeader
                ? "Couldn't verify. A bare sessionKey is usually blocked by Cloudflare, so paste the full Cookie header instead."
                : "Couldn't verify those cookies. They may have expired. Sign in to claude.ai again and copy a fresh header."
        case .noOrganizations:
            statusIsError = true
            statusText = "No Claude organizations were found for this account. A Pro or Max plan may be required."
        case .accountLimitReached:
            statusIsError = true
            statusText = "You can have up to \(AccountStore.maxAccounts) accounts. Remove one first."
        case .connectionError:
            statusIsError = true
            statusText = "Connection error. Please try again."
        }
    }
}

// MARK: - Diagnostics (U7 — opt-in redacted log export)

/// Settings section for the Phase 2 diagnostic export. The toggle drives the same
/// `DiagnosticsDefaults.loggingEnabledKey` flag the `DiagnosticsLogger` reads at runtime
/// (default false), so the producer stays inert unless the user opts in. Both sides reference the
/// shared constant so the toggle and the reader cannot drift. The export builds a redacted,
/// in-process archive (no secrets, no prior-build artifacts) and saves it via `NSSavePanel`.
private struct DiagnosticsSection: View {
    @AppStorage(DiagnosticsDefaults.loggingEnabledKey) private var diagnosticLoggingEnabled = false

    @State private var statusText: String?
    @State private var statusIsError = false
    @State private var showIssuesLink = false

    var body: some View {
        Section(header: Text("Diagnostics")) {
            Text("Records sign-in events to help diagnose problems. No passwords, tokens, or emails are saved.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Enable diagnostic logging", isOn: $diagnosticLoggingEnabled)

            Button("Export Diagnostic Logs…") { export() }

            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(statusText)
            }

            if showIssuesLink {
                Link("Report on GitHub Issues", destination: LogsExporter.issuesURL)
                    .font(.caption)
            }
        }
    }

    @MainActor
    private func export() {
        let result = LogsExporter.exportWithSavePanel()
        switch result {
        case .success(let savedURL, _):
            statusIsError = false
            statusText = "Saved to \(savedURL.lastPathComponent). Please attach it to a GitHub issue."
            showIssuesLink = true
        case .cancelled:
            // No status change on cancel — the user chose not to save.
            break
        case .nothingToExport:
            statusIsError = false
            statusText = "No diagnostic logs yet. Turn on logging, reproduce the problem, then export."
            showIssuesLink = false
        case .installDateUnreadable:
            statusIsError = true
            statusText = "Couldn't determine the install date, so export is disabled for safety. Reinstall Claude Battery from the DMG, then export again."
            showIssuesLink = false
        case .failure(let message):
            statusIsError = true
            statusText = message
            showIssuesLink = false
        }
    }
}
