import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var accountStore: AccountStore
    @ObservedObject var usageService: UsageService
    let onSignIn: () -> Void

    var body: some View {
        Group {
            if !accountStore.isAuthenticated {
                unauthenticatedContent
            } else if let usage = usageService.latestUsage {
                authenticatedContent(usage: usage)
            } else if usageService.consecutiveFailures >= 10 {
                errorContent
            } else {
                loadingContent
            }
        }
        .frame(width: 300)
        .preferredColorScheme(.dark)
    }

    // MARK: - Authenticated

    @ViewBuilder
    private func authenticatedContent(usage: UsageData) -> some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                sessionCard(usage: usage)
                weeklyCard(usage: usage)
                resetsCard(usage: usage)
                modelsCard(usage: usage)
            }

            // Account list (hidden when only 1 account)
            if accountStore.accounts.count > 1 {
                AccountListSection(
                    accountStore: accountStore,
                    onAddAccount: onSignIn
                )
            }

            // "+Add Account" when only 1 account — show as subtle link
            if accountStore.accounts.count == 1 && accountStore.canAddAccount {
                Button(action: onSignIn) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                        Text("Add Account")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Color(white: 0.5))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            VStack(spacing: 2) {
                Text(lastUpdatedText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Right-click the battery icon in your menu bar for Settings.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 2)
        }
        .padding(12)
    }

    // MARK: - Cards

    private let cardHeight: CGFloat = 110

    private func sessionCard(usage: UsageData) -> some View {
        UsageCard(title: "Session") {
            ArcGauge(value: usage.sessionRemaining, color: gaugeColor(for: usage.sessionRemaining))
                .frame(height: 58)
        }
        .frame(height: cardHeight)
    }

    private func weeklyCard(usage: UsageData) -> some View {
        UsageCard(title: "Weekly") {
            ArcGauge(value: usage.weeklyRemaining, color: gaugeColor(for: usage.weeklyRemaining))
                .frame(height: 58)
        }
        .frame(height: cardHeight)
    }

    private func resetsCard(usage: UsageData) -> some View {
        UsageCard(title: "Resets") {
            VStack(alignment: .leading, spacing: 8) {
                resetRow(label: "Session", date: usage.sessionResetDate)
                resetRow(label: "Weekly", date: usage.weeklyResetDate)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: cardHeight)
    }

    private func modelsCard(usage: UsageData) -> some View {
        UsageCard(title: "Models") {
            VStack(spacing: 8) {
                ModelBar(name: "Opus", value: usage.opusRemaining, color: gaugeColor(for: usage.opusRemaining))
                ModelBar(name: "Sonnet", value: usage.sonnetRemaining, color: gaugeColor(for: usage.sonnetRemaining))
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: cardHeight)
    }

    // MARK: - Components

    private func resetRow(label: String, date: Date?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white)
            Spacer()
            if let date = date {
                Text(formatCountdown(date))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            } else {
                Text("--")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.5))
            }
        }
    }

    private func gaugeColor(for value: Double) -> Color {
        if value < 20 { return .red }
        if value < 50 { return .orange }
        return .green
    }

    // MARK: - States

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Fetching usage...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(16)
    }

    private var unauthenticatedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "battery.0percent")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Sign in to see your Claude usage")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Sign In") { onSignIn() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(16)
    }

    private var errorContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Unable to reach Claude")
                .font(.subheadline)
            Text("The app may need an update.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(16)
    }

    // MARK: - Formatting

    private var lastUpdatedText: String {
        guard let lastFetch = usageService.lastSuccessfulFetch else { return "Not yet updated" }
        let seconds = Int(Date().timeIntervalSince(lastFetch))
        if seconds < 60 { return "Updated just now" }
        let minutes = seconds / 60
        if minutes == 1 { return "Updated 1 minute ago" }
        return "Updated \(minutes) minutes ago"
    }

    private func formatCountdown(_ date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "00m 00s" }

        let total = Int(remaining)
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        let s = total % 60

        if d > 0 {
            return String(format: "%dd %02dh", d, h)
        } else if h > 0 {
            return String(format: "%dh %02dm", h, m)
        } else {
            return String(format: "%dm %02ds", m, s)
        }
    }
}

// MARK: - Account List Section

private struct AccountListSection: View {
    @ObservedObject var accountStore: AccountStore
    let onAddAccount: () -> Void
    @State private var editingAccountId: UUID?
    @State private var editText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ForEach(accountStore.accounts) { account in
                let isActive = account.id == accountStore.activeAccountId

                if editingAccountId == account.id {
                    editRow(account: account, isActive: isActive)
                } else {
                    accountRow(account: account, isActive: isActive)
                }

                if account.id != accountStore.accounts.last?.id {
                    Divider()
                        .background(Color(white: 0.25))
                }
            }

            // "+Add Account" row at the bottom
            if accountStore.canAddAccount {
                Divider()
                    .background(Color(white: 0.25))

                Button(action: onAddAccount) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                        Text("Add Account")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(white: 0.7))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(white: 0.15))
        .cornerRadius(8)
    }

    private func accountRow(account: Account, isActive: Bool) -> some View {
        Button {
            accountStore.switchTo(account.id)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isActive ? Color.green : Color(white: 0.4))
                    .frame(width: 7, height: 7)

                Text(account.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button {
                    editText = account.nickname ?? account.email
                    editingAccountId = account.id
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(white: 0.5))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.green.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isActive ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func editRow(account: Account, isActive: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.green : Color(white: 0.4))
                .frame(width: 7, height: 7)

            TextField("Nickname", text: $editText, onCommit: {
                accountStore.updateNickname(account.id, editText)
                editingAccountId = nil
            })
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(white: 0.22))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.blue.opacity(0.6), lineWidth: 1)
            )

            Button {
                accountStore.updateNickname(account.id, editText)
                editingAccountId = nil
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                editingAccountId = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: 0.5))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.2))
    }
}

// MARK: - Card Container

private struct UsageCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.15))
        .cornerRadius(12)
    }
}

// MARK: - Arc Gauge

private struct ArcGauge: View {
    let value: Double
    let color: Color

    var body: some View {
        ZStack {
            ArcShape()
                .stroke(Color(white: 0.25), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            ArcShape()
                .trim(from: 0, to: value / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            Text(String(format: "%.0f%%", value))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .offset(y: 2)
        }
    }
}

private struct ArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY + 6)
        let radius = min(rect.width, rect.height) / 2 - 3
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(135), endAngle: .degrees(405),
                    clockwise: false)
        return path
    }
}

// MARK: - Model Bar

private struct ModelBar: View {
    let name: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                Text(String(format: "%.0f%%", value))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 0.25))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * value / 100))
                }
            }
            .frame(height: 4)
        }
    }
}
