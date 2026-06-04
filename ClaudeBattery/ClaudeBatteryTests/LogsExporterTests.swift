import AppleArchive
import Compression
import System
import XCTest
@testable import ClaudeBattery

/// Tests for the redaction-respecting, sandbox-correct export (U7). Exercises the pure
/// eligibility filter and the in-process archive WITHOUT invoking `NSSavePanel` (the panel
/// path is a manual gate). Proves the posture invariant: ONLY post-install `diag-*.jsonl` is
/// exported; oslogstore-*.txt (uncontrolled OSLog content), prior-build files, and stray files
/// are always excluded; the archived bytes contain only the controlled redacted producer output.
final class LogsExporterTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogsExporterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    @discardableResult
    private func write(_ name: String, _ contents: String, mtime: Date? = nil) -> URL {
        let url = dir.appendingPathComponent(name)
        try? contents.data(using: .utf8)!.write(to: url)
        if let mtime {
            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - Eligibility filter

    func testEligible_includesOnlyDiagJsonlAfterInstall() {
        let install = Date()
        write("diag-2026-06-03.jsonl", "{\"kind\":\"a\"}\n", mtime: install.addingTimeInterval(10))
        write("diag-2026-06-04.jsonl", "{\"kind\":\"b\"}\n", mtime: install.addingTimeInterval(20))

        let eligible = LogsExporter.eligibleLogFiles(in: dir, installedAfter: install)
        let names = Set(eligible.map { $0.lastPathComponent })
        XCTAssertEqual(names, ["diag-2026-06-03.jsonl", "diag-2026-06-04.jsonl"])
    }

    func testEligible_alwaysExcludesOslogstoreDumps_evenPostInstall() {
        // POSTURE INVARIANT: uncontrolled OSLog content never reaches the export. An
        // oslogstore-*.txt is excluded regardless of date — even a post-install one.
        let install = Date()
        write("diag-2026-06-03.jsonl", "{\"kind\":\"a\"}\n", mtime: install.addingTimeInterval(10))
        write("oslogstore-2026-06-03T00-00-00Z.txt", "[Auth] info nav-decision host=claude.ai\n", mtime: install.addingTimeInterval(10))

        let names = Set(LogsExporter.eligibleLogFiles(in: dir, installedAfter: install).map { $0.lastPathComponent })
        XCTAssertEqual(names, ["diag-2026-06-03.jsonl"], "oslogstore must NEVER be eligible for export")
        XCTAssertFalse(LogsExporter.isEligibleName("oslogstore-2026-06-03T00-00-00Z.txt"),
                       "isEligibleName must reject oslogstore-*.txt")
    }

    func testEligible_excludesPriorBuildDiagFiles() {
        let install = Date()
        // A diag file from a PRIOR build, written before this install.
        write("diag-2026-05-01.jsonl", "{\"old\":1}\n", mtime: install.addingTimeInterval(-86_400))
        write("diag-2026-06-03.jsonl", "{\"new\":1}\n", mtime: install.addingTimeInterval(10))

        let names = Set(LogsExporter.eligibleLogFiles(in: dir, installedAfter: install).map { $0.lastPathComponent })
        XCTAssertEqual(names, ["diag-2026-06-03.jsonl"], "prior-build diag file must be excluded")
    }

    func testEligible_excludesStrayFiles() {
        let install = Date()
        write("diag-2026-06-03.jsonl", "{\"k\":1}\n", mtime: install.addingTimeInterval(10))
        write("notes.txt", "hello", mtime: install.addingTimeInterval(10))
        write("diag-backup.zip", "x", mtime: install.addingTimeInterval(10))

        let names = Set(LogsExporter.eligibleLogFiles(in: dir, installedAfter: install).map { $0.lastPathComponent })
        XCTAssertEqual(names, ["diag-2026-06-03.jsonl"])
    }

    func testEligible_missingDirectory_returnsEmptyNoCrash() {
        let missing = dir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(LogsExporter.eligibleLogFiles(in: missing, installedAfter: .distantPast), [])
    }

    func testEligible_emptyDirectory_returnsEmpty() {
        XCTAssertEqual(LogsExporter.eligibleLogFiles(in: dir, installedAfter: .distantPast), [])
    }

    // MARK: - Archive build + content verification

    func testBuildArchive_shipsOnlyDiagJsonl_neverOslogstore() throws {
        let install = Date()
        // The only writer of diag-*.jsonl is DiagnosticsLogger; these lines are SecretRedactor-processed.
        let diagURL = write("diag-2026-06-03.jsonl",
            "{\"kind\":\"session-cookie-captured\",\"payload\":{\"domain\":\".claude.ai\"}}\n" +
            "{\"kind\":\"org-discovery-status\",\"payload\":{\"status\":200}}\n",
            mtime: install.addingTimeInterval(10))
        // A post-install oslogstore with a secret — must NEVER ship (posture invariant), even
        // though it is post-install. This is the uncontrolled-OSLog content the export excludes.
        write("oslogstore-2026-06-03T00-00-00Z.txt", "sessionKey=sk-ant-SHOULD-NOT-SHIP\n", mtime: install.addingTimeInterval(10))

        let eligible = LogsExporter.eligibleLogFiles(in: dir, installedAfter: install)
        XCTAssertEqual(eligible.map { $0.lastPathComponent }, ["diag-2026-06-03.jsonl"],
                       "only diag-*.jsonl may be eligible")

        let archiveURL = try LogsExporter.buildArchive(from: eligible)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path), "archive should be created")

        let extractDir = dir.appendingPathComponent("extracted", isDirectory: true)
        try ArchiveTestSupport.decode(at: archiveURL, into: extractDir)

        let extracted = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        let extractedNames = Set(extracted.map { $0.lastPathComponent })
        XCTAssertEqual(extractedNames, ["diag-2026-06-03.jsonl"], "archive must contain ONLY diag-*.jsonl: \(extractedNames)")
        XCTAssertFalse(extractedNames.contains { $0.hasPrefix("oslogstore-") }, "oslogstore leaked into archive")

        var combined = ""
        for f in extracted { combined += (try? String(contentsOf: f, encoding: .utf8)) ?? "" }
        XCTAssertFalse(combined.contains("sk-ant-SHOULD-NOT-SHIP"), "OSLog secret reached the archive")
        XCTAssertTrue(combined.contains("session-cookie-captured"))

        // No mutation of the included diag file.
        let extractedDiag = (try? String(contentsOf: extractDir.appendingPathComponent("diag-2026-06-03.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertEqual(extractedDiag, try String(contentsOf: diagURL, encoding: .utf8))
    }

    @MainActor
    func testExportWithSavePanel_nothingToExport_whenNoEligibleFiles() {
        // Empty dir → nothingToExport (does not present the panel, does not crash).
        let result = LogsExporter.exportWithSavePanel(logsDirectory: dir, installDate: Date())
        XCTAssertEqual(result, .nothingToExport)
    }

    // MARK: - Fail-closed install date + error path

    func testProductionInstallDate_isReadableForRunningBundle() {
        // The running test bundle has a readable creation date; it must NOT be the fail-closed
        // sentinel. (The fail-closed branch is exercised indirectly: distantFuture would exclude
        // everything, which testExportWithSavePanel_nothingToExport covers behaviorally.)
        XCTAssertNotEqual(LogsExporter.productionInstallDate(), .distantFuture)
    }

    func testFailClosed_distantFutureInstallDate_excludesEverything() {
        write("diag-2026-06-03.jsonl", "{\"k\":1}\n", mtime: Date())
        let names = LogsExporter.eligibleLogFiles(in: dir, installedAfter: .distantFuture)
        XCTAssertTrue(names.isEmpty, "a future install floor must exclude all files (fail-closed)")
    }

    @MainActor
    func testExportWithSavePanel_installDateUnreadable_whenDistantFuture() {
        // DI-05: an unreadable install date (.distantFuture) is distinct from an empty history, so
        // the UI can explain the cause rather than show "no logs yet". Does not present the panel.
        write("diag-2026-06-03.jsonl", "{\"k\":1}\n", mtime: Date())
        let result = LogsExporter.exportWithSavePanel(logsDirectory: dir, installDate: .distantFuture)
        XCTAssertEqual(result, .installDateUnreadable)
    }

    func testEligible_sameDayPriorLaunchFileExcludedByMtime() {
        // ADV-001: two same-UTC-day per-launch files; the prior build's file (pre-install mtime)
        // must be excluded so its bytes never ship, even though the date in the name matches.
        let install = Date()
        write("diag-2026-06-03-priorbld.jsonl", "{\"preinstall\":1}\n", mtime: install.addingTimeInterval(-60))
        write("diag-2026-06-03-currbld.jsonl", "{\"postinstall\":1}\n", mtime: install.addingTimeInterval(10))
        let names = Set(LogsExporter.eligibleLogFiles(in: dir, installedAfter: install).map { $0.lastPathComponent })
        XCTAssertEqual(names, ["diag-2026-06-03-currbld.jsonl"],
                       "a same-day prior-launch file before the install floor must be excluded")
    }

    func testBuildArchive_throwsWhenSourceFileMissing() {
        // A non-existent eligible file makes staging copyItem throw → buildArchive throws, which
        // exportWithSavePanel maps to .failure(String). Locks the error contract the Settings UI
        // surfaces to the user.
        let bogus = dir.appendingPathComponent("diag-does-not-exist.jsonl")
        XCTAssertThrowsError(try LogsExporter.buildArchive(from: [bogus]))
    }

    // MARK: - Atomic save (writeArchive)

    func testWriteArchive_toNewPath_copiesContent() throws {
        let src = dir.appendingPathComponent("source.aar")
        let bytes = Data("known-archive-bytes".utf8)
        try bytes.write(to: src)

        let dest = dir.appendingPathComponent("saved.aar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "precondition: dest must not exist")

        try LogsExporter.writeArchive(src, to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "dest should exist after save")
        XCTAssertEqual(try Data(contentsOf: dest), bytes, "dest bytes must match source")
    }

    func testWriteArchive_overExistingFile_replacesAtomically() throws {
        let src = dir.appendingPathComponent("source.aar")
        let newBytes = Data("the-new-replacement-bytes".utf8)
        try newBytes.write(to: src)

        let dest = dir.appendingPathComponent("saved.aar")
        try Data("the-old-pre-existing-bytes".utf8).write(to: dest)

        try LogsExporter.writeArchive(src, to: dest)

        XCTAssertEqual(try Data(contentsOf: dest), newBytes, "dest must be replaced with source bytes")
        XCTAssertTrue(siblingTempFiles(of: dest).isEmpty, "no .tmp-* sibling may remain: \(siblingTempFiles(of: dest))")
    }

    func testWriteArchive_overExisting_originalSurvivesWhenSourceMissing() throws {
        // REGRESSION (P2 non-atomic destructive overwrite): the old remove-then-copy destroyed the
        // user's pre-existing file before the copy, so a copy failure left NOTHING in its place.
        // writeArchive must never destroy the original when the operation cannot complete.
        let dest = dir.appendingPathComponent("saved.aar")
        let originalBytes = Data("the-irreplaceable-original-bytes".utf8)
        try originalBytes.write(to: dest)

        let missingSource = dir.appendingPathComponent("does-not-exist.aar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingSource.path), "precondition: source must be missing")

        XCTAssertThrowsError(try LogsExporter.writeArchive(missingSource, to: dest),
                             "a missing source must make the save throw")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path),
                      "the pre-existing file must survive a failed save")
        XCTAssertEqual(try Data(contentsOf: dest), originalBytes,
                       "the pre-existing file's bytes must be untouched after a failed save")
        XCTAssertTrue(siblingTempFiles(of: dest).isEmpty, "no .tmp-* litter may remain: \(siblingTempFiles(of: dest))")
    }

    func testWriteArchive_overSymlinkDestination_replacesLinkAndLeavesTargetIntact() throws {
        // REGRESSION: `replaceItemAt` throws ENOENT on a SYMLINK original (fileExists follows the
        // link, so a symlink-to-existing-file reaches the replace branch). writeArchive must unlink+
        // move instead — replace the link with a real file, leave the link's target untouched.
        let src = dir.appendingPathComponent("source.aar")
        try Data("new-archive-bytes".utf8).write(to: src)
        let target = dir.appendingPathComponent("real-target.txt")
        try Data("original-target-bytes".utf8).write(to: target)
        let linkDest = dir.appendingPathComponent("saved-link.aar")
        try FileManager.default.createSymbolicLink(at: linkDest, withDestinationURL: target)

        try LogsExporter.writeArchive(src, to: linkDest)

        XCTAssertEqual(try Data(contentsOf: linkDest), Data("new-archive-bytes".utf8),
                       "destination must hold the source bytes after replacing the symlink")
        XCTAssertEqual(try Data(contentsOf: target), Data("original-target-bytes".utf8),
                       "the symlink's former target must be untouched")
        let isLink = ((try? FileManager.default.attributesOfItem(atPath: linkDest.path))?[.type] as? FileAttributeType) == .typeSymbolicLink
        XCTAssertFalse(isLink, "destination must be a real file, not a symlink, after the save")
        XCTAssertTrue(siblingTempFiles(of: linkDest).isEmpty, "no .tmp-* litter may remain")
    }

    /// `.tmp-*` siblings writeArchive may have staged next to `dest` in its parent directory.
    private func siblingTempFiles(of dest: URL) -> [URL] {
        let parent = dest.deletingLastPathComponent()
        let prefix = "." + dest.lastPathComponent + ".tmp-"
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil, options: []
        )) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    // MARK: - Helpers (shared archive decode lives in ArchiveTestSupport, below)
}

/// Shared LZFSE `.aar` decode helper for the export test suites (LogsExporterTests +
/// NoSecretsExportGateTests), hoisted from a byte-for-byte duplicate in both files. Inverse of
/// `LogsExporter.buildArchive`: read stream → decompress → decode → extract onto disk.
enum ArchiveTestSupport {
    static func decode(at archiveURL: URL, into destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let archivePath = FilePath(archiveURL),
              let destPath = FilePath(destination) else {
            throw LogsExporter.ExportError.pathConstruction
        }
        guard let readStream = ArchiveByteStream.fileStream(
            path: archivePath, mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)
        ) else { throw LogsExporter.ExportError.streamOpen }
        defer { try? readStream.close() }

        guard let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readStream) else {
            throw LogsExporter.ExportError.streamOpen
        }
        defer { try? decompressStream.close() }

        guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream) else {
            throw LogsExporter.ExportError.streamOpen
        }
        defer { try? decodeStream.close() }

        guard let extractStream = ArchiveStream.extractStream(extractingTo: destPath) else {
            throw LogsExporter.ExportError.streamOpen
        }
        defer { try? extractStream.close() }

        _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
    }
}
