import AppKit
import Foundation
import os

/// Opt-in, redacting diagnostic logger for production sign-in troubleshooting (Phase 2, U6).
///
/// **Inert until enabled.** The logger does NOTHING — no file, no os_log, no directory —
/// until `diagnosticLoggingEnabled` is true (sourced from
/// `UserDefaults.standard.bool(forKey: "diagnosticLoggingEnabled")`, the `@AppStorage`
/// toggle in Settings, default false). The file handle is opened lazily on the first gated
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
/// Output: container `Library/Logs/ClaudeBattery/diag-<YYYY-MM-DD>.jsonl` (never
/// `homeDirectoryForCurrentUser`).
final class DiagnosticsLogger: @unchecked Sendable {
    static let shared = DiagnosticsLogger()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app",
        category: "Diagnostics"
    )

    private let writeQueue = DispatchQueue(label: "com.claudebattery.diagnostics.write")
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private let directoryOverride: URL?
    /// When non-nil, forces the gate on/off regardless of UserDefaults — used by tests so
    /// the gating behavior is deterministic without mutating the shared defaults domain.
    private let enabledOverride: Bool?

    // All mutable state below is serialized on `writeQueue` (open/write/flush) to keep the
    // lazy-open and session-start-once logic race-free.
    private var fileHandle: FileHandle?
    private var resolvedFileURL: URL?
    private var didStartSession = false

    /// `directoryOverride` redirects the log directory (tests). `enabledOverride` forces the
    /// runtime gate (tests); production passes nil so the gate reads the `@AppStorage` default.
    init(directoryOverride: URL? = nil, enabledOverride: Bool? = nil) {
        self.directoryOverride = directoryOverride
        self.enabledOverride = enabledOverride
        // Deliberately NOTHING else here: no file open, no session-start emit. The logger is
        // inert until the first gated emit (KTD-6).
    }

    /// The runtime gate. Default false. Sourced from the `@AppStorage("diagnosticLoggingEnabled")`
    /// toggle via `UserDefaults`, or from `enabledOverride` in tests.
    var diagnosticLoggingEnabled: Bool {
        if let enabledOverride { return enabledOverride }
        return UserDefaults.standard.bool(forKey: "diagnosticLoggingEnabled")
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
    func flush() {
        guard diagnosticLoggingEnabled else { return }
        emitMilestone(kind: "session-end", payload: [:])
        writeQueue.sync {
            try? self.fileHandle?.synchronize()
        }
    }

    /// Resolved on-disk path of the current session's diag file, for the export step
    /// (`LogsExporter`). Returns nil until the first gated emit lazily opens the file.
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
        guard let data = try? JSONSerialization.data(
            withJSONObject: entry,
            options: [.sortedKeys]
        ), let str = String(data: data, encoding: .utf8) else {
            return "{\"ts\":\"\(isoFormatter.string(from: Date()))\",\"kind\":\"serialize-failed\",\"payload\":{}}"
        }
        return str
    }

    /// Lazily open the file handle and write `path-resolved` + `session-start` exactly once,
    /// on the first gated milestone. Must be called on `writeQueue`.
    private func ensureSessionStartedLocked() {
        guard !didStartSession else { return }
        didStartSession = true

        let dir = directoryOverride ?? Self.defaultLogDirectory()
        resolvedFileURL = Self.openFileHandle(directory: dir, into: &fileHandle)

        let path = resolvedFileURL?.path ?? "(unresolved)"
        writeLineLocked(SecretRedactor.redact(serialize(kind: "path-resolved", payload: [
            "path": path,
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

    /// Container Library, NEVER `homeDirectoryForCurrentUser`. Under the app sandbox this
    /// resolves to `…/Containers/<bundleId>/Data/Library/Logs/ClaudeBattery/`.
    private static func defaultLogDirectory() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ClaudeBattery", isDirectory: true)
    }

    private static func openFileHandle(directory: URL, into handle: inout FileHandle?) -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let dateString = DateFormatter.diagDate.string(from: Date())
        let url = directory.appendingPathComponent("diag-\(dateString).jsonl", isDirectory: false)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let h = try? FileHandle(forWritingTo: url) else {
            return nil
        }
        try? h.seekToEnd()
        handle = h
        return url
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
