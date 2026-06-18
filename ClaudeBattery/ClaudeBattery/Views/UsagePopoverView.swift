import AppKit
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var accountStore: AccountStore
    @ObservedObject var authManager: AuthManager
    @ObservedObject var usageService: UsageService
    @ObservedObject var updateChecker: UpdateChecker
    let onSignIn: () -> Void

    var body: some View {
        Group {
            if authManager.loginState == .signingIn {
                signingInContent
            } else if case .error(let message) = authManager.loginState {
                loginErrorContent(message)
            } else if !accountStore.isAuthenticated {
                unauthenticatedContent
            } else if let usage = usageService.latestUsage {
                authenticatedContent(usage: usage)
            } else if usageService.authFailed {
                reauthContent
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
        let columns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]

        VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 8) {
                sessionCard(usage: usage)
                weeklyCard(usage: usage)
            }

            if let credits = usage.usageCredits {
                usageCreditsSection(credits: credits)
            }

            // Models card is omitted entirely when no per-model data is present (KTD3);
            // Resets then spans the full width rather than leaving a lonely half-card.
            if usage.modelUsages.isEmpty {
                resetsCard(usage: usage)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    resetsCard(usage: usage)
                    modelsCard(usage: usage)
                }
            }

            claudeDesignRow()

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
                if let version = updateChecker.availableVersion,
                   let url = updateChecker.downloadURL {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        Text("v\(version) available — Download")
                            .font(.caption2)
                            .foregroundColor(.cyan)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(lastUpdatedText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
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

    // Gauge cards (Session/Weekly) are taller to give the arc and pace bar breathing room (U3).
    private let gaugeCardHeight: CGFloat = 142
    // Info cards (Resets/Models) top-align their content under the title (no centered gap).
    // Height fits up to three model bars (legacy Opus+Sonnet plus All Models) without clipping.
    private let infoCardHeight: CGFloat = 120

    private func sessionCard(usage: UsageData) -> some View {
        UsageCard(title: "Session") {
            VStack(spacing: 12) {
                ArcGauge(value: usage.sessionRemaining,
                         color: gaugeColor(for: usage.sessionRemaining),
                         tickCount: 5)
                    .frame(height: 58)
                paceBar(resetsAt: usage.sessionResetDate,
                        window: Self.sessionWindow)
            }
        }
        .frame(height: gaugeCardHeight)
    }

    private func weeklyCard(usage: UsageData) -> some View {
        UsageCard(title: "Weekly") {
            VStack(spacing: 12) {
                ArcGauge(value: usage.weeklyRemaining,
                         color: gaugeColor(for: usage.weeklyRemaining),
                         tickCount: 7)
                    .frame(height: 58)
                paceBar(resetsAt: usage.weeklyResetDate,
                        window: Self.weeklyWindow)
            }
        }
        .frame(height: gaugeCardHeight)
    }

    /// Thin time-remaining bar under an arc (U3): fills to the time-remaining percent and shares
    /// the arc's remaining-% color scale (batteryColor: <20 red, <45 orange, else green), with a
    /// small trailing clock glyph + percent label marking it as TIME (the non-color cue, KTD9).
    /// When the reset date is unknown the percent is nil and the bar is omitted entirely (KTD4)
    /// rather than shown as a misleading empty or full track.
    // Test expectation: none - SwiftUI layout; the fill (timeRemainingPercent) is covered by
    // PaceBarTests (U2) and the color reuses the tested batteryColor scale.
    @ViewBuilder
    private func paceBar(resetsAt: Date?, window: TimeInterval) -> some View {
        if let timeRemaining = Self.timeRemainingPercent(resetsAt: resetsAt, window: window) {
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(white: 0.25))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Self.batteryColor(remainingPercent: timeRemaining))
                            .frame(width: max(0, geo.size.width * timeRemaining / 100))
                    }
                }
                .frame(height: 6)
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(Color(white: 0.6))
                    Text("\(Int(timeRemaining.rounded()))%")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(white: 0.6))
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Time remaining, \(Int(timeRemaining.rounded())) percent")
        }
    }

    private func resetsCard(usage: UsageData) -> some View {
        UsageCard(title: "Resets") {
            VStack(alignment: .leading, spacing: 8) {
                if usage.sessionResetDate == nil && usage.weeklyResetDate == nil {
                    // Both reset times missing: show one explicit line rather than two
                    // bare "--" rows that read as a broken/blank section (issue #23).
                    Text("Reset times unavailable")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    resetRow(label: "Session", date: usage.sessionResetDate)
                    resetRow(label: "Weekly", date: usage.weeklyResetDate)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: infoCardHeight)
    }

    /// Bars for the Models card (U4): an "All Models" bar from the real weekly aggregate
    /// (`weeklyRemaining`, never fabricated - KTD6) above the per-model bars, in order. Each
    /// bar carries `ModelUsage.id` so two scoped limits sharing a display_name (and any model
    /// literally named "All Models") stay distinct ForEach keys rather than colliding.
    static func modelBars(for usage: UsageData) -> [(id: String, name: String, value: Double)] {
        [(id: "__all_models__", name: "All Models", value: usage.weeklyRemaining)]
            + usage.modelUsages.map { (id: $0.id, name: $0.displayName, value: $0.remainingPercent) }
    }

    private func modelsCard(usage: UsageData) -> some View {
        UsageCard(title: "Models") {
            VStack(spacing: 8) {
                ForEach(Self.modelBars(for: usage), id: \.id) { bar in
                    ModelBar(name: bar.name,
                             value: bar.value,
                             color: gaugeColor(for: bar.value))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: infoCardHeight)
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

    /// Gauge/arc/model-bar color, sharing the exact thresholds the tested `batteryColor`
    /// twin uses (red <20, orange <45) so one test set locks both (U7).
    private func gaugeColor(for value: Double) -> Color {
        Self.batteryColor(remainingPercent: value)
    }

    private func spendColor(for percent: Double) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return .cyan
    }

    static func batteryColor(remainingPercent: Double) -> Color {
        let clamped = max(0, min(100, remainingPercent))
        if clamped < 20 { return .red }
        if clamped < 45 { return .orange }
        return .green
    }

    // MARK: - Pace (U2)

    /// Session window length: 5h, consistent with the 5-tick session gauge (A3).
    static let sessionWindow: TimeInterval = 5 * 3600
    /// Weekly window length: 7 days.
    static let weeklyWindow: TimeInterval = 7 * 24 * 3600

    /// Time remaining in the window as a percent (counts down 100 -> 0), clamped 0-100.
    /// The API supplies only `resetsAt` (the window end); the start is derived as
    /// `resetsAt - window` (KTD10). Returns nil when `resetsAt` is nil or the guarded delta
    /// is nil (past, non-finite, or out of range, KTD1) so callers can omit the bar (KTD4).
    static func timeRemainingPercent(resetsAt: Date?, window: TimeInterval, now: Date = Date()) -> Double? {
        guard let resetsAt,
              let remaining = CountdownFormat.remainingSeconds(until: resetsAt, now: now) else { return nil }
        let percent = remaining / window * 100
        // The `max(0, ...)` lower clamp is defense-in-depth, made unreachable by remainingSeconds'
        // positive-delta guard (a non-positive delta returns nil above); kept regardless.
        return max(0, min(100, percent))
    }

    @ViewBuilder
    private func unifiedBarRow<Trailing: View>(
        label: String,
        remainingPercent: Double?,
        fillColor: Color? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                trailing()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(white: 0.25))
                    if let remaining = remainingPercent {
                        let clamped = max(0, min(100, remaining))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(fillColor ?? Self.batteryColor(remainingPercent: clamped))
                            .frame(width: max(0, geo.size.width * clamped / 100))
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(10)
        .background(Color(white: 0.15))
        .cornerRadius(12)
    }

    /// Currency formatter parameterized by the API-supplied currency code (KTD6); falls
    /// back to USD when the code is missing or empty. Setting `currencyCode` explicitly
    /// keeps a non-USD account (e.g. AUD) from rendering as USD under a US locale.
    static func makeCurrencyFormatter(code: String = "USD", locale: Locale = .current) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = code.isEmpty ? "USD" : code
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }

    /// Currency formatters are comparatively heavy to build, so cache one per code
    /// (NSCache is thread-safe). Keyed by code only - callers always use the current locale.
    private static let currencyFormatterCache = NSCache<NSString, NumberFormatter>()

    private func formatCurrency(_ value: Double, code: String = "USD") -> String {
        let resolved = code.isEmpty ? "USD" : code
        let formatter: NumberFormatter
        if let cached = Self.currencyFormatterCache.object(forKey: resolved as NSString) {
            formatter = cached
        } else {
            formatter = Self.makeCurrencyFormatter(code: resolved)
            Self.currencyFormatterCache.setObject(formatter, forKey: resolved as NSString)
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    /// Unified Usage-credits section (U5, KTD5/KTD7): one "Credits" row carries the spend state
    /// and the prepaid balance on a single line. The status segment flexes and truncates; the
    /// balance is right-pinned and never truncates. Each value formats in its own currency.
    @ViewBuilder
    private func usageCreditsSection(credits: UsageCreditsData) -> some View {
        VStack(spacing: 6) {
            // Bar fill shows spend percent only in the enabled state; nil (empty track) otherwise.
            let barPercent: Double? = {
                if case let .enabled(_, _, percent, _, _) = credits.state {
                    return max(0, min(100, percent))
                }
                return nil
            }()

            // The bar carries SPEND semantics (high = closer to the limit), so color it by
            // spendColor (high = red) rather than the remaining-semantics batteryColor (high =
            // green); otherwise a near-limit bar would read green and contradict the status text.
            let barFillColor: Color? = {
                if case let .enabled(_, _, percent, _, _) = credits.state {
                    return spendColor(for: percent)
                }
                return nil
            }()

            unifiedBarRow(label: "Credits", remainingPercent: barPercent, fillColor: barFillColor) {
                HStack(spacing: 6) {
                    creditsStatusSegment(state: credits.state)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let balance = credits.balance {
                        Spacer(minLength: 6)
                        creditsBalanceSegment(balance: balance)
                            // Balance is the right-pinned anchor and must never truncate (KTD7).
                            .layoutPriority(1)
                            .fixedSize()
                    }
                }
            }

            // Enabled state keeps its detail lines below the combined row.
            if case let .enabled(_, limit, _, currency, resetDate) = credits.state {
                VStack(spacing: 2) {
                    if let limit {
                        creditsDetailRow(label: "Monthly spend limit",
                                         value: formatCurrency(limit, code: currency))
                    }
                    // Reset is provisional until a credits-ENABLED capture confirms the field
                    // (A3): show first-of-next-month when the API carries no reset.
                    creditsDetailRow(label: "Resets",
                                     value: Self.shortDate(resetDate ?? Self.firstOfNextMonth(after: Date())))
                }
            }
        }
    }

    /// The flexing status segment: enabled spend line (colored by spendColor) or the mapped
    /// disabled reason. Renders empty when there is no spend state (balance-only).
    @ViewBuilder
    private func creditsStatusSegment(state: UsageCreditsData.State?) -> some View {
        switch state {
        case let .enabled(spent, _, percent, currency, _):
            // percent is uncapped (KTD7); over-limit colors red via spendColor.
            Text(Self.usageCreditsEnabledStatus(spentFormatted: formatCurrency(spent, code: currency),
                                                percent: percent))
                .font(.system(size: 10))
                .foregroundColor(spendColor(for: percent))
        case let .disabled(reason, resetDate):
            Text(Self.usageCreditsDisabledText(reason: reason, resetDate: resetDate))
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.6))
        case nil:
            EmptyView()
        }
    }

    private func creditsBalanceSegment(balance: UsageCreditsData.Balance) -> some View {
        Text(formatCurrency(balance.major, code: balance.currency))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
    }

    private func creditsDetailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(white: 0.7))
        }
        .padding(.horizontal, 10)
    }

    /// Enabled-credits status text for the combined row (U5), e.g. "$12.00 spent · 60% used".
    /// `spent` is pre-formatted in its own currency; `percent` is uncapped (KTD7) and rounded
    /// for display. Pure so the composition is testable without the SwiftUI view.
    static func usageCreditsEnabledStatus(spentFormatted: String, percent: Double) -> String {
        "\(spentFormatted) spent · \(Int(percent.rounded()))% used"
    }

    /// Maps a `spend.disabled_reason` to human text. `org_level_disabled_until` means the
    /// monthly spend limit was reached and credits pause until the next cycle.
    static func usageCreditsDisabledText(reason: String, resetDate: Date?) -> String {
        let base = reason == "org_level_disabled_until" ? "Paused - monthly limit reached" : "Paused"
        if let resetDate {
            return "\(base), resets \(shortDate(resetDate))"
        }
        return base
    }

    /// First day of the month following `date` - the provisional monthly-credits reset used
    /// for display until a credits-ENABLED capture confirms the real field (A3).
    static func firstOfNextMonth(after date: Date, calendar: Calendar = .current) -> Date {
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? date
    }

    private static let creditsResetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static func shortDate(_ date: Date) -> String {
        creditsResetDateFormatter.string(from: date)
    }

    private func claudeDesignRow() -> some View {
        unifiedBarRow(label: "Claude Design", remainingPercent: nil) {
            Text("Shares standard usage limits")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(Color(white: 0.45))
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude Design, shares standard usage limits")
        .accessibilityHint("Claude Design counts against your standard session and weekly usage")
    }

    // MARK: - States

    private var signingInContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Signing in...")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(16)
    }

    private func loginErrorContent(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                authManager.loginState = .idle
                onSignIn()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(16)
    }

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

    private var reauthContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.slash")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Session expired")
                .font(.subheadline)
            Text("Please sign in again to continue.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign In Again") { onSignIn() }
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
        // Route through the shared guarded core (U1, KTD1) so the popover and menu-bar
        // countdowns inherit the same issue-#23 trap protection.
        guard let remaining = CountdownFormat.remainingSeconds(until: date) else { return "00m 00s" }

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

// MARK: - Countdown Formatting

/// Shared, testable countdown helpers (U1, KTD1). Both the popover `formatCountdown` and the
/// menu-bar compact countdown route through `remainingSeconds` so they inherit the same
/// issue-#23 trap protection: a past, non-finite, or absurdly large date yields nil rather
/// than reaching `Int(...)`, which traps fatally.
enum CountdownFormat {
    /// Seconds until `date`, or nil when there is no positive, finite, in-range countdown.
    static func remainingSeconds(until date: Date, now: Date = Date()) -> TimeInterval? {
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0, remaining.isFinite, remaining < Double(Int.max) else { return nil }
        return remaining
    }

    /// Compact menu-bar countdown, never more than 3 characters (enforced for ALL inputs):
    /// `>= 10h` -> `"9h+"` (saturates; still truthful as "at least 9h" and guarantees <= 3 chars
    /// under clock skew / stale reset dates), `>= 1h` -> `"Nh+"` (e.g. "4h+"), `>= 1m` -> `"Nm"`
    /// (e.g. "32m"), `> 0 but < 1m` -> `"<1m"`. Returns nil when there is nothing to count down.
    static func compactCountdown(until date: Date, now: Date = Date()) -> String? {
        guard let remaining = remainingSeconds(until: date, now: now) else { return nil }
        let total = Int(remaining)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours >= 10 { return "9h+" }
        if hours >= 1 { return "\(hours)h+" }
        if minutes >= 1 { return "\(minutes)m" }
        return "<1m"
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
    /// Number of evenly-spaced quota segments; `count - 1` interior ticks are drawn.
    /// 0 disables ticks (e.g. the menu-bar gauge, which is excluded - U6).
    var tickCount: Int = 0

    var body: some View {
        ZStack {
            ArcShape()
                .stroke(Color(white: 0.25), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            ArcShape()
                .trim(from: 0, to: value / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            if tickCount > 1 {
                ArcTicks(count: tickCount)
                    .stroke(Color(white: 0.12), lineWidth: 1.5)
            }
            Text(String(format: "%.0f%%", value))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .offset(y: 2)
        }
    }
}

/// Pure geometry for the popover gauge notches (U6), extracted from the views so the
/// tick math is unit-testable. The arc starts at 135 deg and sweeps 270 deg.
enum GaugeTicks {
    /// Interior tick fractions for an N-segment gauge: `i / N` for `i` in `1..<N`.
    /// Returns an empty array for counts below 2 (no interior ticks).
    static func fractions(count: Int) -> [Double] {
        guard count > 1 else { return [] }
        return (1..<count).map { Double($0) / Double(count) }
    }

    /// Angle in degrees for a fraction along the arc geometry (`135 + 270 * fraction`).
    static func angle(fraction: Double) -> Double {
        135 + 270 * fraction
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

/// Short radial marks across the gauge stroke at each interior quota fraction, on the same
/// geometry as `ArcShape` (U6).
private struct ArcTicks: Shape {
    let count: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY + 6)
        let radius = min(rect.width, rect.height) / 2 - 3
        let inner = radius - 3.5
        let outer = radius + 3.5
        for fraction in GaugeTicks.fractions(count: count) {
            let radians = GaugeTicks.angle(fraction: fraction) * .pi / 180
            let dx = cos(radians), dy = sin(radians)
            path.move(to: CGPoint(x: center.x + inner * dx, y: center.y + inner * dy))
            path.addLine(to: CGPoint(x: center.x + outer * dx, y: center.y + outer * dy))
        }
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
