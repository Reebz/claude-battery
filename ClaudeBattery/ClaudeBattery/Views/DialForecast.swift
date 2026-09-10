import SwiftUI

extension UsagePopoverView {
    // MARK: - Ring colour (#46, KD5, KD13)

    /// Outer ring colour: red below `UsageData.lowRemainingThreshold` whatever the pace says (the
    /// menu-bar icons go red at the same number, so icon and popover agree about "nearly empty"),
    /// else the pace colour so ring and word agree, else the level colour when there is no pace to
    /// follow (`.weeklyLimited`, `.unknown`). The Session card passes the DISPLAY value here, the
    /// same number the renderers test (KTD2).
    static func ringColor(remaining: Double, pace: PaceStatus) -> Color {
        if remaining < UsageData.lowRemainingThreshold { return .red }
        switch pace {
        case .onTrack, .caution, .danger: return paceColor(pace)
        case .weeklyLimited, .unknown:    return batteryColor(remainingPercent: remaining)
        }
    }

    /// Colour of the pace word under the dial: the ring's red floor, otherwise `paceColor`, so the
    /// word can never disagree with the ring and "Limited by weekly" keeps its muted colour above
    /// the floor (KD13). Takes the same value the ring does.
    static func paceCaptionColor(remaining: Double, pace: PaceStatus) -> Color {
        if remaining < UsageData.lowRemainingThreshold { return .red }
        return paceColor(pace)
    }

    /// The inner time ring is a fixed neutral grey (KD8): lighter than `trackColor` so it reads as
    /// a ring, and not cyan or blue, which already means "spend is fine" on the credits row.
    static let neutralInnerRingColor = Color(white: 0.5)

    // MARK: - Run-out estimate (#31, KD6, KD7, KTD1)

    /// Below this fraction of the window elapsed no run-out is projected: a burst of use at the
    /// start of a fresh window divides by a tiny elapsed time and projects a run-out minutes away.
    static let minElapsedFraction: Double = 0.10

    /// Seconds until usage runs out at the current burn rate, from the current snapshot only, or
    /// nil when there is nothing sound to project. `pace` is the result of `paceStatus` on the SAME
    /// inputs: the projection reads it instead of re-deriving the delta, so the word and the
    /// estimate can never drift apart, and it returns nil unless the pace is `.caution` or
    /// `.danger`. That gate already implies at least 10% used and at most 90% left, so the only
    /// guards kept are the ones it does not imply: depleted (nothing left to project), under
    /// `minElapsedFraction` of the window elapsed, and a reset beyond one window (clock skew makes
    /// the elapsed time negative). Window start is `resetsAt - window`, as in `timeRemainingPercent`.
    /// The formula `(window - r) * remaining / (100 - remaining)` is below `r` exactly when the
    /// pace delta is positive, so the estimate always lands before the reset.
    static func runOutSeconds(remainingPercent: Double, resetsAt: Date?, window: TimeInterval,
                              pace: PaceStatus, now: Date = Date()) -> TimeInterval? {
        guard pace == .caution || pace == .danger else { return nil }
        guard let resetsAt,
              let r = CountdownFormat.remainingSeconds(until: resetsAt, now: now) else { return nil }
        if remainingPercent <= 0 { return nil }
        if r > window { return nil }
        let elapsedFraction = 1 - r / window
        if elapsedFraction < minElapsedFraction { return nil }
        return (window - r) * remainingPercent / (100 - remainingPercent)
    }

    /// Rounds a run-out to the nearest 5 minutes on the session window and the nearest hour on
    /// the weekly window, never below one quantum, so poll-to-poll jitter in the integer
    /// percentages does not move the shown value.
    static func quantiseRunOut(_ seconds: TimeInterval, window: TimeInterval) -> TimeInterval {
        let quantum: TimeInterval = window == weeklyWindow ? 3600 : 300
        return max(1, (seconds / quantum).rounded()) * quantum
    }

    /// Copy for the run-out line under the pace word, relative so it cannot be mistaken for a
    /// reset time (KD6). Prints the seconds it is given; the caller quantises first. nil hides it.
    static func runOutLine(seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        return "Out in ~" + CountdownFormat.minuteResolution(seconds: seconds)
    }

    // MARK: - Dial lines (#44, KTD3)

    /// The three text lines under a dial, in display order: the pace word (nil hides it), the
    /// run-out estimate (nil hides it), and the reset countdown, which is always present. The two
    /// durations behind the strings ride along for the spoken label; `runOutSeconds` is already
    /// quantised, so the voice and the line agree.
    struct DialLines: Equatable {
        let caption: String?
        let runOut: String?
        let countdown: String
        let resetSeconds: TimeInterval?
        let runOutSeconds: TimeInterval?
    }

    /// The single line a dial shows when its reset time is nil or already past (AE5).
    static let resetUnavailableLine = "Reset time unavailable"

    /// The lines under one dial from the current snapshot (KTD3). Takes no display value and no
    /// weekly-limited flag: `pace` already encodes weekly-limited-versus-Danger through
    /// `sessionPace(for:)`, and `rawRemaining` is the value the run-out projects. A nil or past
    /// reset self-omits everything but "Reset time unavailable", whatever `pace` says, matching the
    /// dial's own inner-arc rule (KTD4). The run-out is quantised here, before `runOutLine`, which
    /// prints exactly what it is given, and then dropped unless it still lands strictly before the
    /// reset: `pace` is graded at poll time while these lines re-print on the minute clock, so a
    /// stale Caution can otherwise project past a reset the countdown says is nearer.
    static func dialLines(pace: PaceStatus, rawRemaining: Double, resetsAt: Date?, window: TimeInterval,
                          now: Date = Date()) -> DialLines {
        guard let resetsAt,
              let resetSeconds = CountdownFormat.remainingSeconds(until: resetsAt, now: now) else {
            return DialLines(caption: nil, runOut: nil, countdown: resetUnavailableLine,
                             resetSeconds: nil, runOutSeconds: nil)
        }
        let runOut = runOutSeconds(remainingPercent: rawRemaining, resetsAt: resetsAt, window: window,
                                   pace: pace, now: now)
            .map { quantiseRunOut($0, window: window) }
            .flatMap { $0 < resetSeconds ? $0 : nil }
        return DialLines(caption: paceCaption(pace),
                         runOut: runOutLine(seconds: runOut),
                         countdown: "Resets in " + CountdownFormat.minuteResolution(seconds: resetSeconds),
                         resetSeconds: resetSeconds,
                         runOutSeconds: runOut)
    }

    /// The two inputs the Session card's lines project from: the pace from `sessionPace(for:)`
    /// and the RAW `sessionRemaining`, picked here and nowhere else, so neither `sessionCard` nor
    /// any other caller can hand the weekly-capped display value to the run-out (KD7).
    static func sessionDialInputs(for usage: UsageData, now: Date = Date()) -> (pace: PaceStatus, rawRemaining: Double) {
        (pace: sessionPace(for: usage, now: now), rawRemaining: usage.sessionRemaining)
    }

    /// The Session card's lines, from `sessionDialInputs` (KD7).
    static func sessionDialLines(for usage: UsageData, now: Date = Date()) -> DialLines {
        let inputs = sessionDialInputs(for: usage, now: now)
        return dialLines(pace: inputs.pace,
                         rawRemaining: inputs.rawRemaining,
                         resetsAt: usage.sessionResetDate,
                         window: sessionWindow,
                         now: now)
    }

    /// A duration in words for the spoken label ("2 hours 30 minutes", "3 days", "less than a
    /// minute"), truncated to whole units exactly like `CountdownFormat.minuteResolution`, so the
    /// voice never says a number the line does not print. Zero components are dropped.
    static func spokenDuration(seconds: TimeInterval) -> String {
        let c = CountdownFormat.components(seconds: seconds)
        let units: [(Int, String)] = [(c.days, "day"), (c.hours, "hour"), (c.minutes, "minute")]
        let parts = units.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "less than a minute" : parts.joined(separator: " ")
    }

    /// One spoken label per dial combining usage, time-remaining, the pace status (R9) and, when
    /// `lines` is given, the run-out and the reset countdown from under the dial, so each dial is
    /// spoken once and the three text lines can hide from the accessibility tree (KTD3). The pace
    /// is spelled out with its meaning ("over pace") rather than reusing the terse visual caption,
    /// and `.unknown` has nothing to add.
    ///
    /// `.toNearestOrEven` because these are the same two Doubles the gauge draws with "%.0f", and
    /// that is what "%.0f" does at an exact half: plain `.rounded()` would speak 17 against a dial
    /// printing 16. Every menu bar renderer already rounds this way for the same reason. #43 was
    /// this class of bug between two surfaces, and a screen reader is a third one.
    static func gaugeAccessibilityLabel(name: String, usage: Double, timeRemaining: Double?, pace: PaceStatus,
                                        lines: DialLines? = nil) -> String {
        var parts = ["\(name) usage \(Int(usage.rounded(.toNearestOrEven))) percent"]
        if let timeRemaining {
            parts.append("time remaining \(Int(timeRemaining.rounded(.toNearestOrEven))) percent")
        }
        switch pace {
        case .onTrack:       parts.append("on track")
        case .caution:       parts.append("caution, over pace")
        case .danger:        parts.append("danger, over pace")
        case .weeklyLimited: parts.append("limited by weekly")
        case .unknown:       break
        }
        if let lines {
            if let runOut = lines.runOutSeconds {
                parts.append("projected to run out in about \(spokenDuration(seconds: runOut))")
            }
            if let reset = lines.resetSeconds {
                parts.append("resets in \(spokenDuration(seconds: reset))")
            } else {
                parts.append(resetUnavailableLine.lowercased())
            }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Countdown Formatting

/// Shared, testable countdown helpers (U1, KTD1). Both the popover dial countdown and the
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

    /// Whole days, hours and minutes of a duration, truncated (`Int(seconds)`), shared by the
    /// dial countdown and the spoken label so both print the same numbers for the same instant.
    static func components(seconds: TimeInterval) -> (days: Int, hours: Int, minutes: Int) {
        let total = Int(seconds)
        return (total / 86400, (total % 86400) / 3600, (total % 3600) / 60)
    }

    /// Minute-resolution countdown for the dial lines (KD10): `>= 1d` -> `"Nd HHh"` (e.g.
    /// "3d 00h"), `>= 1h` -> `"Nh MMm"` (e.g. "2h 14m"), `>= 1m` -> `"Nm"` (e.g. "5m"), under a
    /// minute `"<1m"` so this and `compactCountdown` print the same thing for the same instant.
    /// Takes seconds so the run-out line can print a duration that has no date.
    static func minuteResolution(seconds: TimeInterval) -> String {
        let (days, hours, minutes) = components(seconds: seconds)
        if days > 0 { return String(format: "%dd %02dh", days, hours) }
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes >= 1 { return "\(minutes)m" }
        return "<1m"
    }
}
