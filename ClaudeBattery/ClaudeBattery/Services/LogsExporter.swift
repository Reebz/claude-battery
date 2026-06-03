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
/// - Includes ONLY `diag-*.jsonl` files created at/after the production install (records
///   produced by the U6 redacting producer) and **excludes `oslogstore-*.txt` dumps** and any
///   other file — those may carry pre-production `#if DEBUG` debug output (e.g. a raw-cookie
///   `logger.debug` line). The eligibility filter is a pure function (`eligibleLogFiles`) so the
///   exclusion is unit-testable without invoking AppleArchive.
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

    /// The curated file list: only `diag-*.jsonl` whose modification date is at/after
    /// `installedAfter`. Everything else — `oslogstore-*.txt`, stray files, older diag files
    /// from a prior build — is excluded, so a pre-production debug artifact can never ride along.
    static func eligibleLogFiles(in directory: URL, installedAfter installDate: Date) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("diag-"), name.hasSuffix(".jsonl") else { return false }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return false }
            guard let mtime = values?.contentModificationDate else { return false }
            // `>=` with a tiny tolerance: the diag file is created moments after the bundle is
            // laid down, but clock granularity / copy timing can make them equal.
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

    /// Container Library Logs dir (matches DiagnosticsLogger / OSLogStoreDumper).
    static func defaultLogDirectory() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ClaudeBattery", isDirectory: true)
    }

    /// Best-effort "when was this build installed": the app bundle's creation date. Files
    /// older than this are pre-production artifacts and are excluded. Falls back to
    /// `.distantPast` (include everything eligible by name) if the date can't be read.
    static func productionInstallDate() -> Date {
        guard let bundleURL = Bundle.main.bundleURL as URL?,
              let values = try? bundleURL.resourceValues(forKeys: [.creationDateKey]),
              let created = values.creationDate else {
            return .distantPast
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
