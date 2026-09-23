import AppKit
import SwiftUI

// MARK: - Popover text scale (R12)

/// The popover's one text-size control (R12, grew out of #53): every text size in the usage popover
/// moves together by a point offset the user picks in Settings. Popover only by decision - the
/// menu bar countdown cell and the Settings window's own text keep the sizes they have.
///
/// Six positions, 1 to 6, for offsets -3 to +2. The popover is a fixed 300pt panel and its cards
/// have a fixed height, so there is no position above 6.
///
/// The four semantic styles this file used are pinned, at their 9 call sites, to the point sizes
/// macOS actually renders them at, measured on this system rather than assumed: `.caption` is
/// 10 regular, `.caption2` is 10 medium, `.subheadline` is 11 regular and `.headline` is 13 bold.
/// The trade is deliberate: those 9 sites, plus the three bordered button titles that had been
/// on the style's own body font, give up Dynamic Type, and in return one slider moves all 43
/// text sites in the panel together.
enum PopoverTextSize {
    /// The UserDefaults key behind the Settings slider. Renaming it would silently reset every
    /// user's choice back to the default, so a test pins the literal.
    static let positionKey = "popoverTextSizePosition"
    static let defaultPosition = 4
    static let positions = 1...6

    /// The reset countdown's size at position 4 (R11), the line #53 was about, so the Settings
    /// caption reports the size of the line the user most wants to read.
    static let labelReferenceSize: CGFloat = 11

    /// Point offset for a slider position: 1 to 6 gives -3 to +2. A position outside the range
    /// clamps into it, because a stale or hand-edited UserDefaults value (0, 7, 99, -1) has to
    /// land on a size the layout was measured against, not off the end of the table.
    static func offset(for position: Int) -> CGFloat {
        let clamped = min(max(position, positions.lowerBound), positions.upperBound)
        return CGFloat(clamped - defaultPosition)
    }

    /// A base point size with the offset applied, floored at 1: the smallest bases here are the
    /// 7pt centre clock glyph and the 9pt footer hint, and zero or negative is not a font size.
    static func size(_ base: CGFloat, offset: CGFloat) -> CGFloat {
        max(1, base + offset)
    }

    /// The scaled font for one site. Weight and design pass straight through, so every call site
    /// keeps the exact face it had before the offset existed.
    static func font(_ base: CGFloat, weight: Font.Weight = .regular,
                     design: Font.Design = .default, offset: CGFloat) -> Font {
        .system(size: size(base, offset: offset), weight: weight, design: design)
    }

    /// Caption above the Settings slider, reporting the live result: "Text size: 11pt" at the
    /// default position, 8pt at position 1 and 13pt at position 6.
    static func settingsLabel(for position: Int) -> String {
        "Text size: \(Int(size(labelReferenceSize, offset: offset(for: position))))pt"
    }
}

/// The point offset every popover text site adds to its base size. It travels through the
/// environment rather than each subview reading UserDefaults for itself, because SwiftUI observes
/// an environment value and re-renders the views that read it, where a hidden global read would
/// leave stale sizes on screen until something else happened to invalidate the view. Reading it
/// adds no `PopoverClock` observer, so the minute-tick scope (KTD10) is unchanged.
private struct PopoverTextOffsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var popoverTextOffset: CGFloat {
        get { self[PopoverTextOffsetKey.self] }
        set { self[PopoverTextOffsetKey.self] = newValue }
    }
}

struct UsagePopoverView: View {
    @ObservedObject var accountStore: AccountStore
    @ObservedObject var authManager: AuthManager
    @ObservedObject var usageService: UsageService
    @ObservedObject var updateChecker: UpdateChecker
    /// The minute clock `MenuBarController` starts on popover show and stops on close (KTD10).
    /// Held as a plain `let`, NOT `@ObservedObject`: this root view must never re-evaluate on a
    /// tick. Only `DialLinesView` and `FooterStatusLineView` observe it, so a tick re-draws the
    /// three text lines and nothing else (the arcs are siblings of that scope, never children).
    let clock: PopoverClock
    let onSignIn: () -> Void
    /// The text-size position the Settings slider writes (R12, grew out of #53). Read here and
    /// published into the environment, so one value drives all 43 text sites in the popover.
    @AppStorage(PopoverTextSize.positionKey) private var textSizePosition = PopoverTextSize.defaultPosition

    /// The offset this view's own text sites use. The root cannot read `\.popoverTextOffset`
    /// back: `.environment(_:_:)` feeds the children of the view it is applied to, not that view,
    /// so an `@Environment` property here would always read the default 0.
    private var textOffset: CGFloat { PopoverTextSize.offset(for: textSizePosition) }

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
        // One place the whole popover reads its text scale from (R12). Applied here, on the
        // root, so every card, row and line below moves together when the Settings slider moves.
        .environment(\.popoverTextOffset, textOffset)
    }

    // MARK: - Authenticated

    @ViewBuilder
    private func authenticatedContent(usage: UsageData) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]

        VStack(spacing: 8) {
            // Update notice leads the popover instead of sitting in the footer: down there it was
            // caption2 gray under the Settings hint and easy to miss, and it also REPLACED the
            // freshness line, so noticing an update cost you that line.
            // Renders nothing when no update is available, leaving the usual layout untouched.
            updateBanner()

            LazyVGrid(columns: columns, spacing: 8) {
                sessionCard(usage: usage)
                weeklyCard(usage: usage)
            }

            if let credits = usage.usageCredits {
                usageCreditsSection(credits: credits)
            }

            // Models card spans the full width, and is omitted entirely when no per-model data is
            // present (KTD3). The Resets card that used to share this row is gone: each dial now
            // carries its own reset countdown under the pace word (#44, KTD3).
            if !usage.modelUsages.isEmpty {
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
                            .font(PopoverTextSize.font(10, weight: .medium, offset: textOffset))
                        Text("Add Account")
                            .font(PopoverTextSize.font(11, weight: .medium, offset: textOffset))
                    }
                    .foregroundColor(Color(white: 0.5))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            VStack(spacing: 2) {
                // Freshness line is now unconditional: the update notice lives in the top banner,
                // so the two no longer compete for this slot. The version rides after it (#48): it
                // used to sit in front of "Updated" and the line read as an app-update status.
                // A leaf view, so the minute clock can move "Usage updated N minutes ago" without a
                // poll and without re-evaluating anything above it (KTD10).
                FooterStatusLineView(clock: clock, lastFetch: usageService.lastSuccessfulFetch)
                Text("Right-click the battery icon in your menu bar for Settings.")
                    .font(PopoverTextSize.font(9, offset: textOffset))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 2)
        }
        .padding(12)
    }

    // MARK: - Cards

    // Gauge cards (Session/Weekly) give the concentric dial and the three lines under it room
    // (#31, #44). Taller than the arc alone needs: the enlarged dial (frame height 80) plus the pace
    // word (10pt) and the reset countdown and run-out (11pt medium, R11) sit with vertical slack so
    // nothing clips. 160 fitted one line; the three-line content measured 171 in the render harness
    // at 10pt and grows 2.4 at 11pt, so 185 still leaves about 12 of the original 14 of slack and
    // keeps the two cards in a row equal. At slider position 6 the three-line stack grows from
    // 38.0 to 47.0 and spends 9 of that 12, leaving about 3. Going to 11pt did not need a taller
    // card and must not quietly get one.
    private let gaugeCardHeight: CGFloat = 185
    // The Models card takes no fixed height: it sizes to its content, with content vertically
    // centered, so it hugs the bars (no excess bottom padding) and never clips the 3-bar case the
    // way a fixed height would.

    private func sessionCard(usage: UsageData) -> some View {
        // The gauge shows the weekly-capped value (sessionDisplayRemaining) so a nearly-exhausted
        // weekly can't display a high, unreachable session number. The menu-bar renderers read the
        // same value, so the two surfaces never disagree about "Session". The pace is graded
        // separately from the RAW session (via sessionPace) so the cap never corrupts it, and the
        // lines under the dial project the RAW session too (`rawRemaining`, KD7): the display value
        // reaches ArcGauge and the ring colour only, never `dialLines`. Both come from
        // `sessionDialInputs`, the one place that picks them, so this card cannot be re-wired to
        // the display value by hand.
        let inputs = Self.sessionDialInputs(for: usage)
        return gaugeCard(title: "Session",
                         remaining: usage.sessionDisplayRemaining,
                         rawRemaining: inputs.rawRemaining,
                         resetsAt: usage.sessionResetDate,
                         window: Self.sessionWindow,
                         tickCount: 5,
                         pace: inputs.pace,
                         suppressTimeArc: usage.isSessionWeeklyLimited)
    }

    private func weeklyCard(usage: UsageData) -> some View {
        gaugeCard(title: "Weekly",
                  remaining: usage.weeklyRemaining,
                  rawRemaining: usage.weeklyRemaining,
                  resetsAt: usage.weeklyResetDate,
                  window: Self.weeklyWindow,
                  tickCount: 7,
                  pace: Self.paceStatus(remainingPercent: usage.weeklyRemaining,
                                        resetsAt: usage.weeklyResetDate, window: Self.weeklyWindow))
    }

    /// Shared Session/Weekly card: a concentric dual-arc gauge (outer = usage remaining coloured by
    /// pace with the red floor, KD5; inner = time remaining in neutral grey, KD8) over the pace word,
    /// the reset countdown and the run-out estimate (KTD3). The inner arc and time % self-omit when
    /// the reset time is unknown (KTD4); the lines then collapse to "No reset time".
    ///
    /// `remaining` is the DISPLAY value (what the dial draws, and what colours it); `rawRemaining`
    /// is what the lines project. They differ only on a weekly-limited Session card.
    private func gaugeCard(title: String, remaining: Double, rawRemaining: Double, resetsAt: Date?,
                           window: TimeInterval, tickCount: Int, pace: PaceStatus,
                           suppressTimeArc: Bool = false) -> some View {
        // Suppress the inner time arc when the shown value is not on this card's own clock: a
        // weekly-limited Session displays the weekly quota, so a session-window time arc would pair
        // two different windows and mislead. nil hides the inner arc, its centre clock, and the
        // a11y "time remaining" (KTD4).
        let timeRemaining = suppressTimeArc ? nil : Self.timeRemainingPercent(resetsAt: resetsAt, window: window)
        // The spoken label folds the three lines in, computed here (poll time) rather than on the
        // clock, because this view must not observe the tick (KTD10 rule 1). It refreshes with the
        // next poll re-render; the visible lines under the dial refresh every minute on their own.
        let spokenLines = Self.dialLines(pace: pace, rawRemaining: rawRemaining, resetsAt: resetsAt, window: window)
        return UsageCard(title: title) {
            VStack(spacing: 8) {
                ArcGauge(value: remaining,
                         color: Self.ringColor(remaining: remaining, pace: pace),
                         innerValue: timeRemaining,
                         innerColor: Self.neutralInnerRingColor,
                         tickCount: tickCount)
                    // Height drives the arc radius (ArcShape uses min(width,height)); at ~114pt card
                    // width the height binds, so 80 (was 58) grows the rings enough that even the
                    // widest 100%-over-100% readout (right after a window reset) clears the inner
                    // arc with margin, while the inner inset (9) keeps the two rings visibly apart.
                    // That margin holds at the default text size, and it is thin: the 15pt bold
                    // rounded "100%" measures 41.9pt wide, putting its cap corner 23.7 from the
                    // centre against the inner ring's inner edge at 26. At slider position 6 the
                    // readout is 17pt and 47.0pt wide, corner 26.6 against the same 26, so the
                    // corners touch the inner ring by about half a point. That happens only while
                    // both numbers read 100%, in the moment after a window reset, and it was
                    // accepted: position 6 is the top of the slider precisely because that is
                    // where the panel only roughly fits. Every popover size moves together, so the
                    // readout is not carved out of the scale to buy the margin back.
                    .frame(height: 80)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.gaugeAccessibilityLabel(name: title, usage: remaining,
                                                                     timeRemaining: timeRemaining, pace: pace,
                                                                     lines: spokenLines))
                // The three lines are the only part of the card that observes the minute clock.
                DialLinesView(clock: clock,
                              title: title,
                              pace: pace,
                              rawRemaining: rawRemaining,
                              displayRemaining: remaining,
                              resetsAt: resetsAt,
                              window: window)
            }
            // Fill the fixed card height from the top, so the two cards in a row stay the same
            // size and their dials line up even when one shows three lines and the other one.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: gaugeCardHeight)
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
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: - Components

    /// Model-bar color, sharing the exact thresholds the tested `batteryColor`
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
        if clamped < UsageData.lowRemainingThreshold { return .red }
        if clamped < 45 { return .orange }
        return .green
    }

    /// Shared bar-track gray for the usage-credits bar row.
    private static let trackColor = Color(white: 0.25)
    /// Shared muted-label gray for secondary label/percent text (bar rows, and the "Limited by
    /// weekly" pace word). The lines under the dials left this grey in R11: white at 11pt medium
    /// is the readable contrast, and this grey is what made them hard to read.
    fileprivate static let mutedLabelColor = Color(white: 0.6)

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

    // MARK: - Pace status (#31)

    /// Pace status for one window (session or weekly): how far usage burn is ahead of / behind the
    /// clock, bucketed into a 3-level RAG status (#31). `weeklyLimited` and `unknown` are the two
    /// non-pace states the caption still needs (Session deferring to weekly; no reset/time data).
    enum PaceStatus: Equatable {
        case onTrack        // pace delta < cautionDelta (includes being ahead of pace)
        case caution        // cautionDelta <= delta < dangerDelta
        case danger         // delta >= dangerDelta, or usage already at 0
        case weeklyLimited  // the weekly limit binds; the Session dial defers to it
        case unknown        // resetsAt nil or past/non-finite; caller omits the caption
    }

    /// Pace delta = timeRemaining% - usageRemaining% (percentage points; positive means burning
    /// faster than the clock). It is exactly how much longer the inner time arc is than the outer
    /// usage arc, so the RAG status names the visible gap between the two arcs.
    /// At or above this delta the pace is Caution (amber).
    static let cautionDelta: Double = 10
    /// At or above this delta the pace is Danger (red).
    static let dangerDelta: Double = 25

    /// Pace status for one window, from the current usage snapshot only. Mirrors
    /// `timeRemainingPercent` (window start = `resetsAt - window`; a nil/past/non-finite delta
    /// yields `.unknown` so the caller omits the caption). Buckets the signed pace delta; being
    /// ahead of pace (negative delta) is always `.onTrack`, and 0% usage remaining is `.danger`
    /// (already used up). No early-window or near-reset guard is needed: unlike a projected run-out
    /// time, the delta is stable across the whole window (it never divides by elapsed time).
    static func paceStatus(remainingPercent: Double, resetsAt: Date?, window: TimeInterval, now: Date = Date()) -> PaceStatus {
        guard let resetsAt,
              let r = CountdownFormat.remainingSeconds(until: resetsAt, now: now) else { return .unknown }
        if remainingPercent <= 0 { return .danger }
        let timeRemaining = min(100, r / window * 100)
        let delta = timeRemaining - remainingPercent
        if delta >= dangerDelta { return .danger }
        if delta >= cautionDelta { return .caution }
        return .onTrack
    }

    /// The Session card's pace status (#31). When the weekly limit binds (`isSessionWeeklyLimited`)
    /// the Session defers to it (`.weeklyLimited`) - UNLESS the RAW 5h session is itself in Danger,
    /// a nearer concrete wall that must not be hidden behind "Limited by weekly". The pace always
    /// grades the RAW `sessionRemaining` over the 5h window, never the capped gauge value
    /// (`sessionDisplayRemaining`), which is a weekly percentage over a weekly clock and would
    /// fabricate a bogus pace on the session timeline.
    static func sessionPace(for usage: UsageData, now: Date = Date()) -> PaceStatus {
        let raw = paceStatus(remainingPercent: usage.sessionRemaining,
                             resetsAt: usage.sessionResetDate,
                             window: sessionWindow, now: now)
        if usage.isSessionWeeklyLimited {
            return raw == .danger ? raw : .weeklyLimited
        }
        return raw
    }

    /// Copy for the pace caption under each dial (#31). nil hides the line (`.unknown`, KTD4).
    static func paceCaption(_ status: PaceStatus) -> String? {
        switch status {
        case .onTrack:       return "On Track"
        case .caution:       return "Caution"
        case .danger:        return "Danger"
        case .weeklyLimited: return "Limited by weekly"
        case .unknown:       return nil
        }
    }

    /// RAG colour for the pace caption, reusing the batteryColor palette (green/orange/red) so the
    /// label matches the arc colours. `weeklyLimited` is neutral (no pace to grade); `unknown`
    /// never renders (its caption is nil).
    static func paceColor(_ status: PaceStatus) -> Color {
        switch status {
        case .onTrack:       return .green
        case .caution:       return .orange
        case .danger:        return .red
        case .weeklyLimited: return mutedLabelColor
        case .unknown:       return .clear
        }
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
                    .font(PopoverTextSize.font(11, weight: .semibold, offset: textOffset))
                    .foregroundColor(Self.mutedLabelColor)
                Spacer()
                trailing()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.trackColor)
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
                .font(PopoverTextSize.font(10, offset: textOffset))
                .foregroundColor(spendColor(for: percent))
        case let .disabled(reason, resetDate):
            Text(Self.usageCreditsDisabledText(reason: reason, resetDate: resetDate))
                .font(PopoverTextSize.font(10, offset: textOffset))
                .foregroundColor(Color(white: 0.6))
        case nil:
            EmptyView()
        }
    }

    private func creditsBalanceSegment(balance: UsageCreditsData.Balance) -> some View {
        Text(formatCurrency(balance.major, code: balance.currency))
            .font(PopoverTextSize.font(11, weight: .semibold, design: .rounded, offset: textOffset))
            .foregroundColor(.white)
    }

    private func creditsDetailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(PopoverTextSize.font(10, offset: textOffset))
                .foregroundColor(Color(white: 0.5))
            Spacer()
            Text(value)
                .font(PopoverTextSize.font(10, weight: .medium, offset: textOffset))
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

    /// Resolved content for the top update banner, or nil when there is nothing to announce. Both
    /// fields must be present - the same pair-unwrap the old footer link used, kept because
    /// UpdateChecker publishes version and URL together (a half-set state never reaches the view).
    /// Pure so the show/hide rule and the copy are testable without the SwiftUI view.
    /// spokenLabel spells "v" out as "Version" for speech but keeps the visible word "Download":
    /// the label replaces the button's name outright, so dropping it would leave Voice Control with
    /// no way to activate the banner by the one word on screen that names an action.
    static func updateBannerContent(availableVersion: String?, downloadURL: URL?) -> (title: String, spokenLabel: String, url: URL)? {
        guard let availableVersion, let downloadURL else { return nil }
        return (title: "v\(availableVersion) available - Download",
                spokenLabel: "Version \(availableVersion) available, Download",
                url: downloadURL)
    }

    /// "v1.70" from the bare marketing version, or nil when there is no version to show (missing
    /// or empty, which is the XCTest host). Pure so the footer copy is testable without the view.
    nonisolated static func versionLabel(_ version: String?) -> String? {
        guard let version, !version.isEmpty else { return nil }
        return "v\(version)"
    }

    /// The footer's single status line: "Usage updated just now · v1.72". The usage text leads
    /// because the version used to sit in front of "Updated", and "v1.72 · Updated just now" read
    /// as an app-update status (#48). Without a version it is the freshness text alone, with no
    /// dangling separator.
    static func footerStatusLine(version: String?, updated: String) -> String {
        guard let label = versionLabel(version) else { return updated }
        return "\(updated) \u{00B7} \(label)"
    }

    /// Full-width update banner at the top of the popover. The URL is host- and scheme-validated
    /// inside UpdateChecker before it is published, so opening it straight from the view is safe.
    @ViewBuilder
    private func updateBanner() -> some View {
        if let banner = Self.updateBannerContent(availableVersion: updateChecker.availableVersion,
                                                 downloadURL: updateChecker.downloadURL) {
            Button(action: { NSWorkspace.shared.open(banner.url) }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(PopoverTextSize.font(12, offset: textOffset))
                    Text(banner.title)
                        .font(PopoverTextSize.font(11, weight: .semibold, offset: textOffset))
                    Spacer(minLength: 0)
                }
                // Cyan is the colour the footer update link already used. The tint sits on the same
                // opaque Color(white: 0.15) every other block paints, so the banner reads as a card
                // in the same family as the neutral rows; without the base it would be the only
                // block whose colour comes from whatever is behind the popover's vibrancy material.
                // The active account row does the same thing one step louder (tint plus a border).
                .foregroundColor(.cyan)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.cyan.opacity(0.12))
                .background(Color(white: 0.15))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(banner.spokenLabel)
            .accessibilityHint("Opens the download page for the new version")
        }
    }

    // MARK: - States

    private var signingInContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Signing in...")
                .font(PopoverTextSize.font(13, weight: .bold, offset: textOffset))
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(16)
    }

    private func loginErrorContent(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(PopoverTextSize.font(32, offset: textOffset))
                .foregroundColor(.orange)
            Text(message)
                .font(PopoverTextSize.font(11, offset: textOffset))
                .multilineTextAlignment(.center)
            // A label closure, not `Button("Try Again")`, so the title can carry the R12 offset
            // like every other line here: the bordered styles resolve the title font themselves, so
            // an outer `.font` never reaches a string-initialised label (a 24pt bold one renders
            // byte-identical to no font in the render harness). A font on the `Text` inside does
            // scale the title, and the button chrome grows with it. 13 regular is what the unstyled
            // label already measured as, so position 4 looks exactly as it did before.
            Button {
                authManager.loginState = .idle
                onSignIn()
            } label: {
                Text("Try Again")
                    .font(PopoverTextSize.font(13, offset: textOffset))
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
                .font(PopoverTextSize.font(11, offset: textOffset))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(16)
    }

    private var unauthenticatedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "battery.0percent")
                .font(PopoverTextSize.font(40, offset: textOffset))
                .foregroundColor(.secondary)
            Text("Sign in to see your Claude usage")
                .font(PopoverTextSize.font(11, offset: textOffset))
                .multilineTextAlignment(.center)
            // Label closure for the reason the "Try Again" button above spells out.
            Button { onSignIn() } label: {
                Text("Sign In")
                    .font(PopoverTextSize.font(13, offset: textOffset))
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(16)
    }

    private var reauthContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.slash")
                .font(PopoverTextSize.font(32, offset: textOffset))
                .foregroundColor(.secondary)
            Text("Session expired")
                .font(PopoverTextSize.font(11, offset: textOffset))
            Text("Please sign in again to continue.")
                .font(PopoverTextSize.font(10, offset: textOffset))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            // Label closure for the reason the "Try Again" button above spells out.
            Button { onSignIn() } label: {
                Text("Sign In Again")
                    .font(PopoverTextSize.font(13, offset: textOffset))
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(16)
    }

    private var errorContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(PopoverTextSize.font(32, offset: textOffset))
                .foregroundColor(.secondary)
            Text("Unable to reach Claude")
                .font(PopoverTextSize.font(11, offset: textOffset))
            Text("The app may need an update.")
                .font(PopoverTextSize.font(10, offset: textOffset))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding(16)
    }

    // MARK: - Formatting

    /// The footer freshness text, such as "Usage updated just now": the age of the last successful
    /// usage fetch. It names "Usage" because a bare "Updated" beside the version read as an
    /// app-update status (#48). Static and clock-driven so `FooterStatusLineView` can re-print
    /// it on each minute tick without a poll (KTD10), and so the copy is testable.
    static func lastUpdatedText(lastFetch: Date?, now: Date = Date()) -> String {
        guard let lastFetch else { return "Usage not yet updated" }
        let seconds = Int(now.timeIntervalSince(lastFetch))
        if seconds < 60 { return "Usage updated just now" }
        let minutes = seconds / 60
        if minutes == 1 { return "Usage updated 1 minute ago" }
        return "Usage updated \(minutes) minutes ago"
    }
}

// MARK: - Account List Section

private struct AccountListSection: View {
    @ObservedObject var accountStore: AccountStore
    let onAddAccount: () -> Void
    @State private var editingAccountId: UUID?
    @State private var editText: String = ""

    /// R12 text scale: the point offset every text size in this view adds to its base.
    @Environment(\.popoverTextOffset) private var textOffset

    /// How many account rows show before the list starts scrolling, and what a row costs: a 24pt
    /// control with 5pt of padding either side, plus the 1pt divider under it.
    ///
    /// The entry limit doubled to 10 with issue #41 and nothing here capped the list or scrolled
    /// it, so filling the new limit made this section about 150pt taller than a full old one: five
    /// more rows, less the Add Account row that disappears once no slot is free. An NSPopover
    /// clamps to the screen, so on a short display the last rows and the footer under them go off
    /// the bottom with no way to reach them (P3, review finding). The cap engages only past
    /// `visibleRows`, so the ordinary two-or-three-account popover lays out exactly as before.
    private static let visibleRows = 5
    private static let rowHeight: CGFloat = 35

    var body: some View {
        VStack(spacing: 0) {
            if accountStore.accounts.count > Self.visibleRows {
                ScrollView(.vertical) {
                    accountRows
                }
                .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight)
            } else {
                accountRows
            }

            // "+Add Account" row at the bottom, outside the scroller on purpose: it is the one
            // control here that must not need a scroll to reach.
            if accountStore.canAddAccount {
                Divider()
                    .background(Color(white: 0.25))

                Button(action: onAddAccount) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(PopoverTextSize.font(12, offset: textOffset))
                            .foregroundColor(.green)
                        Text("Add Account")
                            .font(PopoverTextSize.font(11, weight: .medium, offset: textOffset))
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

    /// The rows themselves, kept separate so the same list can be laid out plainly or inside the
    /// scroller without the two copies drifting.
    private var accountRows: some View {
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
        }
    }

    private func accountRow(account: Account, isActive: Bool) -> some View {
        Button {
            accountStore.switchTo(account.id)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isActive ? Color.green : Color(white: 0.4))
                    .frame(width: 7, height: 7)

                Text(accountStore.disambiguatedName(for: account))
                    .font(PopoverTextSize.font(11, offset: textOffset))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button {
                    editText = account.nickname ?? account.email
                    editingAccountId = account.id
                } label: {
                    Image(systemName: "pencil")
                        .font(PopoverTextSize.font(12, weight: .semibold, offset: textOffset))
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
            .font(PopoverTextSize.font(11, offset: textOffset))
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
                    .font(PopoverTextSize.font(11, weight: .semibold, offset: textOffset))
                    .foregroundColor(.green)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                editingAccountId = nil
            } label: {
                Image(systemName: "xmark")
                    .font(PopoverTextSize.font(10, weight: .medium, offset: textOffset))
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

    /// R12 text scale: the point offset every text size in this view adds to its base.
    @Environment(\.popoverTextOffset) private var textOffset

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(PopoverTextSize.font(13, weight: .semibold, offset: textOffset))
                .foregroundColor(.white)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.15))
        .cornerRadius(12)
    }
}

// MARK: - Minute-clock scope (KTD10)

/// The three text lines under a dial, in drawn order: pace word (10pt), reset countdown, run-out
/// (both 11pt medium and white, R11) (#44, KTD3).
/// This is the whole tick scope for a card: it is the only view here that observes `PopoverClock`,
/// so a minute tick re-prints these lines and nothing else. `ArcGauge` is its sibling in
/// `gaugeCard`, never its child. Hidden from the accessibility tree because the dial's combined
/// label already speaks all three; without that the pace word was read twice.
private struct DialLinesView: View {
    @ObservedObject var clock: PopoverClock
    let title: String
    let pace: UsagePopoverView.PaceStatus
    let rawRemaining: Double
    let displayRemaining: Double
    let resetsAt: Date?
    let window: TimeInterval

    /// R12 text scale: the point offset every text size in this view adds to its base.
    @Environment(\.popoverTextOffset) private var textOffset

    var body: some View {
        #if DEBUG
        PopoverBodyCounters.recordLineView(title)
        #endif
        let lines = UsagePopoverView.dialLines(pace: pace, rawRemaining: rawRemaining,
                                               resetsAt: resetsAt, window: window, now: clock.now)
        return VStack(spacing: 2) {
            if let caption = lines.caption {
                // The word shares the ring's red floor, on the DISPLAY value the ring uses (KD13).
                Text(caption)
                    .font(PopoverTextSize.font(10, weight: .medium, offset: textOffset))
                    .foregroundColor(UsagePopoverView.paceCaptionColor(remaining: displayRemaining, pace: pace))
            }
            // The countdown comes second and the forecast last, so the countdown sits in the same
            // place whether or not a forecast is there, and both lines are white at 11pt medium:
            // at 10pt regular in the muted grey they measured 5.3:1 against the card background
            // where the removed full-width Resets row measured 15:1, which is the R11 complaint.
            Text(lines.countdown)
                .font(PopoverTextSize.font(11, weight: .medium, offset: textOffset))
                .monospacedDigit()
                .foregroundColor(.white)
            if let runOut = lines.runOut {
                Text(runOut)
                    .font(PopoverTextSize.font(11, weight: .medium, offset: textOffset))
                    .foregroundColor(.white)
            }
        }
        // The countdown is now the widest line: inside the last day of a window it prints hours and
        // minutes, so the widest it gets is "Resets in 23h 59m", about 100pt of the 114pt card
        // content width at 11pt medium; one line with a little shrink stays as insurance against a
        // wider system font. At slider position 6 the shrink stops being insurance and does its
        // job: that same string at 13pt medium measures 115.6pt against the 114pt card and scales
        // to 0.986, the squeeze that was accepted in return for capping the slider at 6.
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityHidden(true)
    }
}

/// The footer's "Usage updated N minutes ago · v1.72" line, in the tick scope so the freshness
/// text moves without a poll (KTD10). Usage leads and the version trails because the old order,
/// version in front of "Updated", read as an app-update status (#48). `lastFetch` comes in as a
/// value from the parent, which already observes `UsageService`. This view never does.
private struct FooterStatusLineView: View {
    @ObservedObject var clock: PopoverClock
    let lastFetch: Date?

    /// R12 text scale: the point offset every text size in this view adds to its base.
    @Environment(\.popoverTextOffset) private var textOffset

    var body: some View {
        #if DEBUG
        PopoverBodyCounters.recordLineView("Footer")
        #endif
        return Text(UsagePopoverView.footerStatusLine(
            version: AppVersion.marketing,
            updated: UsagePopoverView.lastUpdatedText(lastFetch: lastFetch, now: clock.now)))
            .font(PopoverTextSize.font(10, weight: .medium, offset: textOffset))
            .foregroundColor(.secondary)
    }
}

// MARK: - Arc Gauge

private struct ArcGauge: View {
    let value: Double
    let color: Color
    /// Optional inner concentric arc for time-remaining (#31). nil renders the single-arc
    /// gauge exactly as before, so an unknown reset omits it (KTD4).
    var innerValue: Double? = nil
    var innerColor: Color = .gray
    /// Number of evenly-spaced quota segments; `count - 1` interior ticks are drawn.
    /// 0 disables ticks (e.g. the menu-bar gauge, which is excluded - U6).
    var tickCount: Int = 0

    /// R12 text scale: the point offset every text size in this view adds to its base.
    @Environment(\.popoverTextOffset) private var textOffset

    private let lineWidth: CGFloat = 5
    private let innerLineWidth: CGFloat = 4      // thinner than the outer ring so the neutral grey time ring reads as secondary (KD8)
    private let innerInset: CGFloat = 9          // radial gap between the outer and inner arc (KTD1 separation)

    var body: some View {
        #if DEBUG
        // KTD10 proof: this must count polls, never minute ticks (the gauge is outside the scope).
        PopoverBodyCounters.record("ArcGauge")
        #endif
        return ZStack {
            // Outer arc: usage remaining.
            ArcShape()
                .stroke(Color(white: 0.25), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            ArcShape()
                .trim(from: 0, to: value / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Inner concentric arc: time remaining in the window (only when known).
            if let innerValue {
                // Inner track a touch darker than the outer (0.25) so the fixed grey time ring
                // (KD8) reads as secondary to the coloured outer ring and the two stay separate.
                ArcShape(radiusInset: innerInset)
                    .stroke(Color(white: 0.18), style: StrokeStyle(lineWidth: innerLineWidth, lineCap: .round))
                ArcShape(radiusInset: innerInset)
                    .trim(from: 0, to: innerValue / 100)
                    .stroke(innerColor, style: StrokeStyle(lineWidth: innerLineWidth, lineCap: .round))
            }

            if tickCount > 1 {
                ArcTicks(count: tickCount)
                    .stroke(Color(white: 0.12), lineWidth: 1.5)
            }

            // Centre: big usage %, and a small clock + time % when the inner arc is shown (R5).
            VStack(spacing: 1) {
                Text(String(format: "%.0f%%", value))
                    .font(PopoverTextSize.font(15, weight: .bold, design: .rounded, offset: textOffset))
                    .foregroundColor(.white)
                if let innerValue {
                    HStack(spacing: 2) {
                        Image(systemName: "clock")
                            .font(PopoverTextSize.font(7, weight: .medium, offset: textOffset))
                        Text(String(format: "%.0f%%", innerValue))
                            .font(PopoverTextSize.font(9, weight: .medium, design: .rounded, offset: textOffset))
                            .monospacedDigit()
                    }
                    .foregroundColor(Color(white: 0.6))
                }
            }
            // Two-line centre sits on the ring centre (ArcShape uses midY + 6); the single-line
            // legacy gauge keeps its original +2.
            .offset(y: innerValue == nil ? 2 : 6)
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
    /// Shrinks the radius so a second arc nests inside the first on the same centre/angles.
    var radiusInset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY + 6)
        let radius = min(rect.width, rect.height) / 2 - 3 - radiusInset
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

    /// R12 text scale: the point offset every text size in this view adds to its base.
    @Environment(\.popoverTextOffset) private var textOffset

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                    .font(PopoverTextSize.font(10, offset: textOffset))
                    .foregroundColor(Color(white: 0.6))
                Spacer()
                Text(String(format: "%.0f%%", value))
                    .font(PopoverTextSize.font(10, weight: .medium, offset: textOffset))
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
