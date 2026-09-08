#if DEBUG
import Foundation
import os

/// Body-evaluation counters for the KTD10 refresh-scope proof, absent from Release builds by
/// construction (the whole type and every call site sit under `#if DEBUG`). Each evaluation logs
/// at debug level (Console.app, subsystem of the app, category "PopoverBody"). The expected shape
/// with the popover open: one line-view evaluation per instance per minute, plus one per poll that
/// lands, and `ArcGauge` evaluations equal to the polls only, never the ticks. Closed: zero.
///
/// The trip-wire fails (log at fault, then `assertionFailure`) when one line view evaluates more
/// than `tripWireLimit` times inside `tripWireWindow`: that is the popover re-rendering its text
/// on something other than the minute clock and a poll, the loop shape both CPU incidents had.
/// Rapid user actions that legitimately re-render (switching accounts twice inside ten seconds
/// right after opening) can trip it too; it is a debug diagnostic, not a product check.
@MainActor
enum PopoverBodyCounters {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app",
        category: "PopoverBody"
    )
    private static var counts: [String: Int] = [:]
    private static var lineViewStamps: [String: [Date]] = [:]
    static let tripWireWindow: TimeInterval = 10
    static let tripWireLimit = 2

    static func record(_ name: String) {
        let count = (counts[name] ?? 0) + 1
        counts[name] = count
        logger.debug("body=\(name, privacy: .public) count=\(count)")
    }

    /// Clears the trip-wire stamps. Called when the popover shows, so the trip-wire measures
    /// re-evaluations within one open and never counts the opens themselves.
    static func reset() {
        lineViewStamps = [:]
    }

    static func recordLineView(_ name: String, now: Date = Date()) {
        record(name)
        var stamps = (lineViewStamps[name] ?? []).filter { now.timeIntervalSince($0) < tripWireWindow }
        stamps.append(now)
        lineViewStamps[name] = stamps
        if stamps.count > tripWireLimit {
            logger.fault("trip-wire: line view \(name, privacy: .public) evaluated \(stamps.count) times in \(Int(tripWireWindow))s")
            assertionFailure("KTD10 trip-wire: line view \(name) evaluated \(stamps.count) times in \(Int(tripWireWindow))s")
        }
    }
}
#endif
