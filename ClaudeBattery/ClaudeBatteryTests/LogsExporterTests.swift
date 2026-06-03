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
        try Self.decodeArchive(at: archiveURL, into: extractDir)

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

    func testBuildArchive_throwsWhenSourceFileMissing() {
        // A non-existent eligible file makes staging copyItem throw → buildArchive throws, which
        // exportWithSavePanel maps to .failure(String). Locks the error contract the Settings UI
        // surfaces to the user.
        let bogus = dir.appendingPathComponent("diag-does-not-exist.jsonl")
        XCTAssertThrowsError(try LogsExporter.buildArchive(from: [bogus]))
    }

    // MARK: - Helpers

    /// Decode an LZFSE `.aar` produced by `buildArchive` back onto disk.
    private static func decodeArchive(at archiveURL: URL, into destination: URL) throws {
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
