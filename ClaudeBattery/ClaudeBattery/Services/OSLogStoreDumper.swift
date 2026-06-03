import Foundation
import OSLog

/// Safety-net dump of the process's OSLog entries to a redacted text file (Phase 2, U6).
///
/// Shipped because production also emits plain `os.Logger` lines (AuthManager/AccountStore)
/// that are in-memory only and gone by the time a reporter checks Console.app. This dump
/// puts them on disk so the export carries them.
///
/// **Gated.** Runs only when `DiagnosticsLogger.shared.diagnosticLoggingEnabled` is true, so
/// no `oslogstore-*.txt` is written while the toggle is off (the producer-disabled invariant).
///
/// **P0 redaction**: every rendered line passes through `SecretRedactor.redact(_:)` before
/// write. `OSLogStore.getEntries` returns literal composed messages for own-process logs —
/// the `<private>` mask in Console.app is a display-layer filter, not storage redaction — so
/// any pre-Round-10 raw cookie/email line would otherwise leak; the redactor (now including
/// the bare-email pass) is the defense-in-depth catch.
enum OSLogStoreDumper {
    /// Render one OSLog entry's fields into a single redacted line. Pure + internal so the
    /// render+redact step (the P0 redaction guarantee) is unit-testable without constructing a
    /// real `OSLogEntryLog` (which has no public initializer). Every caller of the dump path
    /// goes through here, so a test that plants a secret in `composedMessage` and asserts the
    /// output is redacted directly proves the dumper's redaction fires.
    static func renderRedacted(date: Date, category: String, level: String, composedMessage: String,
                               dateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()) -> String {
        let dateStr = dateFormatter.string(from: date)
        let rendered = "\(dateStr) [\(category)] \(level) \(composedMessage)"
        return SecretRedactor.redact(rendered)
    }

    /// Dump the last `hoursBack` hours of own-process OSLog entries to disk. Default 6 hours —
    /// reporters may wait through multiple sign-in attempts before reproduction.
    /// No-op when diagnostics are disabled. `enabledOverride` lets tests force the gate without
    /// touching the shared UserDefaults domain.
    static func dump(hoursBack: Int = 6, directoryOverride: URL? = nil, enabledOverride: Bool? = nil) {
        let enabled = enabledOverride ?? DiagnosticsLogger.shared.diagnosticLoggingEnabled
        guard enabled else { return }

        let outputDir = directoryOverride ?? defaultLogDirectory()
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            DiagnosticsLogger.shared.emitMilestone(kind: "oslog-dump-mkdir-failed", payload: [
                "errorDescription": error.localizedDescription
            ])
            return
        }

        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            DiagnosticsLogger.shared.emitMilestone(kind: "oslog-dump-store-init-failed", payload: [:])
            return
        }

        let position = store.position(date: Date().addingTimeInterval(-Double(hoursBack) * 3600))
        let predicateString = "subsystem == '\(Bundle.main.bundleIdentifier ?? "com.claudebattery.app")'"
        let predicate = NSPredicate(format: predicateString)

        let rawEntries: [OSLogEntry]
        do {
            rawEntries = try Array(store.getEntries(at: position, matching: predicate))
        } catch {
            DiagnosticsLogger.shared.emitMilestone(kind: "oslog-dump-getEntries-failed", payload: [
                "errorDescription": error.localizedDescription
            ])
            return
        }
        let entries = rawEntries.compactMap { $0 as? OSLogEntryLog }

        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = outputDir.appendingPathComponent("oslogstore-\(ts).txt")

        let dateFormatter = ISO8601DateFormatter()
        var lineCount = 0
        var redactedCount = 0

        do {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }

            for entry in entries {
                let rawRendered = "\(dateFormatter.string(from: entry.date)) [\(entry.category)] \(String(describing: entry.level)) \(entry.composedMessage)"
                let redacted = renderRedacted(date: entry.date, category: entry.category,
                                              level: String(describing: entry.level),
                                              composedMessage: entry.composedMessage,
                                              dateFormatter: dateFormatter)
                if redacted != rawRendered { redactedCount += 1 }
                if let data = (redacted + "\n").data(using: .utf8) {
                    try handle.write(contentsOf: data)
                    lineCount += 1
                }
            }
            try handle.synchronize()
        } catch {
            DiagnosticsLogger.shared.emitMilestone(kind: "oslog-dump-write-failed", payload: [
                "errorDescription": error.localizedDescription,
                "linesWritten": lineCount
            ])
            return
        }

        DiagnosticsLogger.shared.emitMilestone(kind: "oslog-dump-written", payload: [
            "path": url.path,
            "lines": lineCount,
            "linesRedacted": redactedCount,
            "hoursBack": hoursBack
        ])
    }

    /// Container Library, NEVER `homeDirectoryForCurrentUser` (matches DiagnosticsLogger).
    private static func defaultLogDirectory() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ClaudeBattery", isDirectory: true)
    }
}
