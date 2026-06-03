import AppKit
import Foundation
import os

/// Opt-in, redacting diagnostic logger for production sign-in troubleshooting (Phase 2, U6).
///
/// **Inert until enabled.** The logger does NOTHING — no file, no os_log, no directory —
/// until `diagnosticLoggingEnabled` is true (sourced from `UserDefaults` under the shared
/// `DiagnosticsDefaults.loggingEnabledKey`, the `@AppStorage` toggle in Settings, default
/// false). The file handle is opened lazily on the first gated
/// emit, and `path-resolved` / `session-start` are written there once. This is the
/// no-regression invariant: with the toggle off, the producer leaves no artifact on disk.
///
/// Single path: every gated event (nav decisions, cookie NAMES, capture trigger, loginState
/// transitions, org-discovery HTTP status, session-start/end) is written to the on-disk
/// `diag-*.jsonl` synchronously with `synchronize()` so a crash near the failure point preserves
/// the line, AND mirrored to `os.Logger.notice` for live Console.app debugging. Only the
/// `diag-*.jsonl` file is ever exported (uncontrolled OSLog content is never harvested into the
/// archive — a denylist redactor cannot prove absence-of-secrets over arbitrary log text).
///
/// **Redaction (P0).** Every emitted line is run through `SecretRedactor.redact(_:)` before
/// BOTH the os_log write and the file write. Producers must still pass only non-secret signal
/// (the contract below); the redactor is the defense-in-depth catch. Never emit
/// `account.displayName` / email.
///
/// Output: container `Library/Logs/ClaudeBattery/diag-<YYYY-MM-DD>-<launch>.jsonl`, one file per
/// launch (never `homeDirectoryForCurrentUser`). Files older than the retention window are pruned
/// on session start.
final class DiagnosticsLogger: @unchecked Sendable {
    static let shared = DiagnosticsLogger()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app",
        category: "Diagnostics"
    )

    private let writeQueue = DispatchQueue(label: "com.claudebattery.diagnostics.write")
    /// `ISO8601DateFormatter.string(from:)` is documented thread-safe for formatting on the 13.5+
    /// floor, so this shared instance is exempt from the writeQueue invariant below even though
    /// `serialize()` may format it on the caller thread (before the async hand-off) as well as on
    /// writeQueue.
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Per-process token mixed into the diag filename so each launch writes its OWN file (see
    /// `openFileHandle`). This keeps the exporter's install-date floor accurate: a prior build's
    /// file is never re-touched, so its mtime stays old and the export excludes it.
    private let launchToken = String(UUID().uuidString.prefix(8))

    private let directoryOverride: URL?
    /// When non-nil, forces the gate on/off regardless of UserDefaults — used by tests so
    /// the gating behavior is deterministic without mutating the shared defaults domain.
    private let enabledOverride: Bool?

    // All mutable state below is serialized on `writeQueue` (open/write/flush) to keep the
    // lazy-open and session-start-once logic race-free.
    private var fileHandle: FileHandle?
    private var resolvedFileURL: URL?
    private var didStartSession = false
    /// Set once after an open failure so the error is logged a single time, not on every retry.
    private var loggedOpenFailure = false

    /// `directoryOverride` redirects the log directory (tests). `enabledOverride` forces the
    /// runtime gate (tests); production passes nil so the gate reads the `@AppStorage` default.
    init(directoryOverride: URL? = nil, enabledOverride: Bool? = nil) {
        self.directoryOverride = directoryOverride
        self.enabledOverride = enabledOverride
        // Deliberately NOTHING else here: no file open, no session-start emit. The logger is
        // inert until the first gated emit (KTD-6).
    }

    /// The runtime gate. Default false. Sourced from the `@AppStorage` toggle via `UserDefaults`
    /// under the shared `DiagnosticsDefaults.loggingEnabledKey` (so the SettingsView writer and this
    /// reader cannot drift), or from `enabledOverride` in tests.
    var diagnosticLoggingEnabled: Bool {
        if let enabledOverride { return enabledOverride }
        return UserDefaults.standard.bool(forKey: DiagnosticsDefaults.loggingEnabledKey)
    }

    // MARK: - Public API

    /// The redaction chokepoint: serialize then `SecretRedactor`. Internal so a test can assert
    /// a planted secret is redacted here.
    func redactedLine(kind: String, payload: [String: Any]) -> String {
        SecretRedactor.redact(serialize(kind: kind, payload: payload))
    }

    /// Emit a gated event: synchronous file write to `diag-*.jsonl` + parallel os.Logger.notice
    /// (live Console only). No-op when the gate is off; opens the file and writes session-start
    /// on the first gated call. Every event uses this path — only the file is exported.
    func emitMilestone(kind: String, payload: [String: Any]) {
        guard diagnosticLoggingEnabled else { return }
        let line = redactedLine(kind: kind, payload: payload)
        logger.notice("[\(kind, privacy: .public)] \(line, privacy: .public)")
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.ensureSessionStartedLocked()
            self.writeLineLocked(line)
        }
    }

    /// Flush any buffered data. Called from applicationWillTerminate. No-op when the gate is
    /// off (and harmless if the file was never opened).
    ///
    /// The final fsync is BOUNDED by a short timeout: it runs on writeQueue (after the queued
    /// session-end write) and we wait at most 2s, so a hung/slow disk at quit cannot stall
    /// termination past the OS watchdog. A missed final synchronize is the safe failure — the
    /// session-end line is already enqueued and the OS flushes the handle on process exit.
    func flush() {
        guard diagnosticLoggingEnabled else { return }
        emitMilestone(kind: "session-end", payload: [:])
        let done = DispatchSemaphore(value: 0)
        writeQueue.async { [weak self] in
            try? self?.fileHandle?.synchronize()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2.0)
    }

    /// Resolved on-disk path of the current session's diag file. TEST AFFORDANCE: production
    /// export re-derives the directory via `DiagnosticsDefaults.logDirectory` and never calls
    /// this (do not wire export through it). Returns nil until the first gated emit opens the file.
    var currentSessionFileURL: URL? {
        writeQueue.sync { resolvedFileURL }
    }

    // MARK: - Internals

    private func serialize(kind: String, payload: [String: Any]) -> String {
        let entry: [String: Any] = [
            "ts": isoFormatter.string(from: Date()),
            "kind": kind,
            "payload": payload
        ]
        // `isValidJSONObject` FIRST: `JSONSerialization.data` raises an ObjC NSException (not a
        // Swift throw) on an invalid nested type such as Date, which `try?` cannot catch — so
        // without this guard a non-serializable payload would crash here instead of falling back.
        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(
                withJSONObject: entry,
                options: [.sortedKeys]
              ), let str = String(data: data, encoding: .utf8) else {
            // Serialization failed (a non-JSON value slipped into the payload). Preserve the
            // original kind and the payload KEY NAMES (non-secret by the producer contract) so the
            // diagnostic still records WHICH event was lost, instead of dropping it silently. No
            // value is emitted; the fallback is sanitized to stay valid JSON and still runs through
            // SecretRedactor at the call site.
            let safeKind = Self.jsonSafe(kind)
            let safeKeys = Self.jsonSafe(payload.keys.sorted().joined(separator: ","))
            return "{\"ts\":\"\(isoFormatter.string(from: Date()))\",\"kind\":\"serialize-failed\",\"payload\":{\"failed_kind\":\"\(safeKind)\",\"keys\":\"\(safeKeys)\"}}"
        }
        return str
    }

    /// Strip characters that would break a hand-built JSON string literal. Used only by the
    /// serialize-failed fallback above, where `JSONSerialization` is unavailable.
    private static func jsonSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Lazily open the file handle and write `path-resolved` + `session-start` exactly once,
    /// on the first gated milestone. Must be called on `writeQueue`.
    private func ensureSessionStartedLocked() {
        guard !didStartSession else { return }

        let dir = directoryOverride ?? DiagnosticsDefaults.logDirectory
        guard let url = Self.openFileHandle(directory: dir, launchToken: launchToken, into: &fileHandle) else {
            // Open failed (unwritable dir, FileHandle error, sandbox/IO hiccup). Do NOT latch
            // didStartSession: a later emit re-attempts the open, so a TRANSIENT failure does not
            // permanently disable file logging for the session. Log once so the condition is
            // visible without spamming each retry. The fail-closed invariant is unaffected — the
            // os_log fallback in writeLineLocked still emits only the already-redacted line.
            if !loggedOpenFailure {
                loggedOpenFailure = true
                logger.error("[open-failed] diagnostic log file could not be opened under \(dir.path, privacy: .public)")
            }
            return
        }

        didStartSession = true
        loggedOpenFailure = false
        resolvedFileURL = url
        Self.pruneOldLogs(in: dir, keeping: url)

        writeLineLocked(SecretRedactor.redact(serialize(kind: "path-resolved", payload: [
            "path": url.path,
            "directoryOverride": directoryOverride?.path ?? "(none)"
        ])))
        writeLineLocked(SecretRedactor.redact(serialize(kind: "session-start", payload: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "(unknown)",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "(unknown)",
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "locale": Locale.current.identifier,
            "bundleId": Bundle.main.bundleIdentifier ?? "(unknown)"
        ])))
    }

    /// Write a single already-serialized, already-redacted line. Must be called on `writeQueue`.
    private func writeLineLocked(_ line: String) {
        guard let handle = fileHandle else {
            logger.notice("[file-unavailable] \(line, privacy: .public)")
            return
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            logger.notice("[write-failed] \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func openFileHandle(directory: URL, launchToken: String, into handle: inout FileHandle?) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        // Per-LAUNCH filename (`diag-<UTC date>-<launch token>.jsonl`): each process gets its own
        // file. A build/upgrade or a same-day relaunch starts a fresh file rather than appending to
        // a shared per-day file — which is what keeps the exporter's install-date floor accurate
        // (a prior build's file is never re-touched, so its mtime stays old and it is excluded).
        let dateString = DateFormatter.diagDate.string(from: Date())
        let url = directory.appendingPathComponent("diag-\(dateString)-\(launchToken).jsonl", isDirectory: false)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let h = try? FileHandle(forWritingTo: url) else {
            return nil
        }
        _ = try? h.seekToEnd() // best-effort; a per-launch file is fresh, so this is a no-op
        handle = h
        return url
    }

    /// Best-effort retention: remove `diag-*.jsonl` files older than `retentionDays` so the
    /// per-launch files do not accumulate without bound. Never removes the current session's file.
    /// Runs on writeQueue (called from `ensureSessionStartedLocked`); failures are ignored.
    private static func pruneOldLogs(in directory: URL, keeping current: URL, retentionDays: Int = 7) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("diag-"), name.hasSuffix(".jsonl"),
                  url.standardizedFileURL != current.standardizedFileURL else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}

/// Shared constants for the diagnostics subsystem. Single source of truth so the producer
/// (`DiagnosticsLogger`), the exporter (`LogsExporter`), and the Settings toggle cannot drift.
enum DiagnosticsDefaults {
    /// `UserDefaults` / `@AppStorage` key for the opt-in diagnostic-logging toggle (default false).
    /// Read by `DiagnosticsLogger` and written by the SettingsView `@AppStorage`, both via this
    /// constant, so a rename cannot silently desync the gate.
    static let loggingEnabledKey = "diagnosticLoggingEnabled"

    /// Container `Library/Logs/ClaudeBattery/`, NEVER `homeDirectoryForCurrentUser`. Under the app
    /// sandbox this resolves to `…/Containers/<bundleId>/Data/Library/Logs/ClaudeBattery/`. The
    /// producer writes here and the exporter archives exactly this directory — one definition so
    /// they always agree (previously duplicated byte-for-byte across both files).
    static var logDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ClaudeBattery", isDirectory: true)
    }
}

private extension DateFormatter {
    static let diagDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
