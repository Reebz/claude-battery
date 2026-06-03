import AppKit
import AppleArchive
import Compression
import Foundation
import System

/// Sandbox-correct, redaction-respecting diagnostic export (Phase 2, U7).
///
/// Rebuilt from the worktree's subprocess version, which is illegal under the app sandbox +
/// hardened runtime (it spawned `/usr/bin/zip` and wrote to `~/Desktop`). This version:
///
/// - Archives the **container** Logs dir IN-PROCESS via AppleArchive (LZFSE `.aar`), no
///   subprocess. AppleArchive is available macOS 11+ (within the 13.5 floor).
/// - Includes ONLY the controlled redacted producer artifact `diag-*.jsonl` (DiagnosticsLogger,
///   every line through `SecretRedactor`) created at/after the production install. Uncontrolled
///   OSLog content (`oslogstore-*.txt`) is NEVER included — a denylist redactor cannot prove
///   absence-of-secrets over arbitrary log text. Every other file — stray files, or a prior,
///   weaker build's records (older than the install date) — is excluded, so a pre-production
///   artifact cannot ride along. `eligibleLogFiles` is a pure function so this is unit-testable.
/// - Lets the user save the archive via `NSSavePanel` (sandbox-safe with the
///   `com.apple.security.files.user-selected.read-write` entitlement).
/// - On success, surfaces the saved location **and** a link to the GitHub issues page so the
///   reporter knows the next step.
enum LogsExporter {
    static let issuesURL = URL(string: "https://github.com/Reebz/claude-battery/issues")!

    enum Result: Equatable {
        /// Archive written to `savedURL`. `issuesURL` is the next-step link for the reporter.
        case success(savedURL: URL, issuesURL: URL)
        /// User dismissed the save panel.
        case cancelled
        /// Nothing eligible to export (no `diag-*.jsonl` since install). Not an error.
        case nothingToExport
        /// The bundle install date was unreadable, so the fail-closed floor (`.distantFuture`)
        /// excluded everything. Distinct from `nothingToExport` so the UI can explain the cause
        /// (reinstall from the DMG) instead of a misleading "no logs yet".
        case installDateUnreadable
        /// Archiving or copy failed.
        case failure(String)
    }

    // MARK: - Public entry point

    /// Build the curated archive and present an `NSSavePanel` for the user to save it.
    /// Must run on the main actor (AppKit panel).
    @MainActor
    static func exportWithSavePanel(
        logsDirectory: URL = defaultLogDirectory(),
        installDate: Date = productionInstallDate()
    ) -> Result {
        // Export ships ONLY the controlled, redacted `diag-*.jsonl`. Uncontrolled OSLog content
        // is deliberately NOT recovered into the archive: a denylist redactor cannot prove
        // absence-of-secrets over arbitrary log text, so the invariant is that no OSLog dump can
        // ever reach the export. (See plan KTD-6 / posture decision.)

        // Fail-closed install date unreadable: distinguish from a genuine empty history so the UI
        // explains the cause (reinstall from the DMG) rather than showing "no logs yet".
        if installDate == .distantFuture {
            return .installDateUnreadable
        }
        let eligible = eligibleLogFiles(in: logsDirectory, installedAfter: installDate)
        guard !eligible.isEmpty else { return .nothingToExport }

        let archiveURL: URL
        do {
            archiveURL = try buildArchive(from: eligible)
        } catch {
            return .failure("Could not build the diagnostic archive: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let panel = NSSavePanel()
        panel.title = "Save Diagnostic Logs"
        panel.nameFieldStringValue = archiveURL.lastPathComponent
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else {
            return .cancelled
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: archiveURL, to: destination)
        } catch {
            return .failure("Could not save the archive: \(error.localizedDescription)")
        }

        return .success(savedURL: destination, issuesURL: issuesURL)
    }

    // MARK: - Eligibility (pure, unit-testable)

    /// True ONLY for the controlled redacted producer artifact: `diag-*.jsonl` (DiagnosticsLogger,
    /// every line through `SecretRedactor`). Crucially this EXCLUDES `oslogstore-*.txt` and every
    /// other name — uncontrolled OSLog content must never reach the export archive, because a
    /// denylist redactor cannot prove absence-of-secrets over arbitrary log text.
    static func isEligibleName(_ name: String) -> Bool {
        name.hasPrefix("diag-") && name.hasSuffix(".jsonl")
    }

    /// The curated file list: `diag-*.jsonl` files whose modification date is at/after
    /// `installedAfter`. Older files from a prior build, and EVERY non-`diag-*.jsonl` file
    /// (including any OSLog dump), are excluded — so neither a pre-production artifact nor any
    /// uncontrolled OSLog content can ride along. The post-install date floor is the wall that
    /// keeps a weaker prior build's records out.
    static func eligibleLogFiles(in directory: URL, installedAfter installDate: Date) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.filter { url in
            guard isEligibleName(url.lastPathComponent) else { return false }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return false }
            guard let mtime = values?.contentModificationDate else { return false }
            // `>=` with a tiny tolerance: the file is created moments after the bundle is laid
            // down, but clock granularity / copy timing can make them equal.
            return mtime >= installDate.addingTimeInterval(-1)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - In-process archive (AppleArchive, LZFSE)

    /// Stage the eligible files into a temp dir and archive THAT dir, so the archive contains
    /// exactly the curated set (and no sibling artifacts the directory walk might otherwise pick
    /// up). Returns the temp `.aar` URL; caller deletes it after saving.
    static func buildArchive(from files: [URL]) throws -> URL {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("claudebattery-diag-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        for file in files {
            try fm.copyItem(at: file, to: stagingDir.appendingPathComponent(file.lastPathComponent))
        }

        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let archiveURL = fm.temporaryDirectory.appendingPathComponent("claudebattery-diag-\(ts).aar")
        try fm.removeItemIfExists(at: archiveURL)

        guard let archivePath = FilePath(archiveURL),
              let sourcePath = FilePath(stagingDir) else {
            throw ExportError.pathConstruction
        }

        guard let writeStream = ArchiveByteStream.fileStream(
            path: archivePath,
            mode: .writeOnly,
            options: [.create],
            permissions: FilePermissions(rawValue: 0o644)
        ) else {
            throw ExportError.streamOpen
        }
        defer { try? writeStream.close() }

        guard let compressStream = ArchiveByteStream.compressionStream(
            using: .lzfse,
            writingTo: writeStream
        ) else {
            throw ExportError.streamOpen
        }
        defer { try? compressStream.close() }

        guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream) else {
            throw ExportError.streamOpen
        }
        defer { try? encodeStream.close() }

        guard let keySet = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DAT,UID,GID,MOD,MTM,CTM") else {
            throw ExportError.keySet
        }

        try encodeStream.writeDirectoryContents(archiveFrom: sourcePath, keySet: keySet)
        return archiveURL
    }

    enum ExportError: Error, CustomStringConvertible {
        case pathConstruction, streamOpen, keySet
        var description: String {
            switch self {
            case .pathConstruction: return "could not construct archive paths"
            case .streamOpen: return "could not open the archive stream"
            case .keySet: return "could not build the archive header key set"
            }
        }
    }

    // MARK: - Locations

    /// Container Library Logs dir. Single source of truth shared with the producer
    /// (`DiagnosticsDefaults.logDirectory`) so the exporter archives exactly the directory the
    /// producer wrote into — agreement is a compile-time fact, not a comment.
    static func defaultLogDirectory() -> URL {
        DiagnosticsDefaults.logDirectory
    }

    /// Best-effort "when was this build installed": the app bundle's creation date. Files
    /// older than this are pre-production artifacts and are excluded.
    ///
    /// FAILS CLOSED: if the bundle creation date is unreadable (App Translocation, `cp -p`,
    /// quarantine relocation), return `.distantFuture` so EVERY name-eligible file is excluded
    /// and the export yields `.nothingToExport`. For a P0 redaction exporter the safe failure
    /// direction is to ship nothing rather than risk admitting a prior, weaker-redacting build's
    /// records. (The previous `.distantPast` fallback failed open — it admitted all history.)
    static func productionInstallDate() -> Date {
        guard let bundleURL = Bundle.main.bundleURL as URL?,
              let values = try? bundleURL.resourceValues(forKeys: [.creationDateKey]),
              let created = values.creationDate else {
            return .distantFuture
        }
        return created
    }
}

private extension FileManager {
    func removeItemIfExists(at url: URL) throws {
        if fileExists(atPath: url.path) {
            try removeItem(at: url)
        }
    }
}
