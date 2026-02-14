import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var usageService: UsageService
    let onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let usage = usageService.latestUsage {
                authenticatedContent(usage: usage)
            } else if usageService.consecutiveFailures >= 10 {
                errorContent
            } else if usageService.lastSuccessfulFetch == nil && usageService.consecutiveFailures == 0 {
                loadingContent
            } else {
                unauthenticatedContent
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Authenticated

    @ViewBuilder
    private func authenticatedContent(usage: UsageData) -> some View {
        Text("Claude Usage")
            .font(.headline)

        // Weekly quota
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Weekly Quota")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(String(format: "%.0f%% remaining", usage.weeklyRemaining))
                    .font(.subheadline)
                    .foregroundColor(usage.weeklyRemaining < 20 ? .red : .secondary)
            }

            ProgressView(value: usage.weeklyRemaining, total: 100)
                .tint(usage.weeklyRemaining < 20 ? .red : .accentColor)

            if let resetDate = usage.weeklyResetDate {
                Text("Resets \(formatResetDate(resetDate))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        Divider()

        // Session
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Session")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(String(format: "%.0f%% remaining", usage.sessionRemaining))
                    .font(.subheadline)
                    .foregroundColor(usage.sessionRemaining < 20 ? .red : .secondary)
            }

            ProgressView(value: usage.sessionRemaining, total: 100)
                .tint(usage.sessionRemaining < 20 ? .red : .accentColor)

            if let resetDate = usage.sessionResetDate {
                Text("Resets \(formatResetCountdown(resetDate))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        // Per-model breakdown (if data exists)
        if usage.opusRemaining < 100 || usage.sonnetRemaining < 100 {
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Per-Model Breakdown")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if usage.opusRemaining < 100 {
                    HStack {
                        Text("Opus")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.0f%%", usage.opusRemaining))
                            .font(.caption)
                    }
                    ProgressView(value: usage.opusRemaining, total: 100)
                        .scaleEffect(y: 0.7)
                }

                if usage.sonnetRemaining < 100 {
                    HStack {
                        Text("Sonnet")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.0f%%", usage.sonnetRemaining))
                            .font(.caption)
                    }
                    ProgressView(value: usage.sonnetRemaining, total: 100)
                        .scaleEffect(y: 0.7)
                }
            }
        }

        Divider()

        // Last updated
        HStack {
            if usageService.isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.caption)
            }
            Text(lastUpdatedText)
                .font(.caption)
                .foregroundColor(usageService.isStale ? .yellow : .secondary)
            Spacer()
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
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
    }

    private var unauthenticatedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "battery.0percent")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Sign in to see your Claude usage")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Sign In") {
                onSignIn()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
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
    }

    // MARK: - Formatting

    private var lastUpdatedText: String {
        guard let lastFetch = usageService.lastSuccessfulFetch else { return "Not yet updated" }
        let seconds = Int(Date().timeIntervalSince(lastFetch))
        if seconds < 60 { return "Updated just now" }
        let minutes = seconds / 60
        if minutes == 1 { return "Updated 1 min ago" }
        return "Updated \(minutes) min ago"
    }

    private static let resetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mm a"
        return formatter
    }()

    private func formatResetDate(_ date: Date) -> String {
        Self.resetDateFormatter.string(from: date)
    }

    private func formatResetCountdown(_ date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "soon" }

        let hours = Int(remaining / 3600)
        let minutes = Int(remaining / 60) % 60

        if hours > 0 {
            return "in \(hours)h \(minutes)m"
        } else {
            return "in \(max(1, minutes))m"
        }
    }
}
