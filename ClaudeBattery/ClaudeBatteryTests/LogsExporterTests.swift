import AppleArchive
import Compression
import System
import XCTest
@testable import ClaudeBattery

/// Tests for the redaction-respecting, sandbox-correct export (U7). Exercises the pure
/// eligibility filter and the in-process archive WITHOUT invoking `NSSavePanel` (the panel
/// path is a manual gate). Proves: only post-install `diag-*.jsonl` are included; `oslogstore-*`
/// and other artifacts are excluded; the archived bytes contain only redacted producer output.
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

    func testEligible_excludesOslogstoreDumps() {
        let install = Date()
        write("diag-2026-06-03.jsonl", "{\"kind\":\"a\"}\n", mtime: install.addingTimeInterval(10))
        // Pre-production debug artifact that may carry a raw-cookie #if DEBUG line.
        write("oslogstore-2026-06-03T00-00-00Z.txt", "JS document.cookie: sessionKey=LEAK\n", mtime: install.addingTimeInterval(10))

        let names = Set(LogsExporter.eligibleLogFiles(in: dir, installedAfter: install).map { $0.lastPathComponent })
        XCTAssertEqual(names, ["diag-2026-06-03.jsonl"])
        XCTAssertFalse(names.contains { $0.hasPrefix("oslogstore-") }, "oslogstore dump must be excluded")
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

    func testBuildArchive_containsOnlyEligibleRedactedContent() throws {
        let install = Date()
        // U6 is the only writer: these lines are already SecretRedactor-processed.
        let diagURL = write("diag-2026-06-03.jsonl",
            "{\"kind\":\"session-cookie-captured\",\"payload\":{\"domain\":\".claude.ai\"}}\n" +
            "{\"kind\":\"org-discovery-status\",\"payload\":{\"status\":200}}\n",
            mtime: install.addingTimeInterval(10))
        // An excluded oslogstore artifact with a secret — must NOT end up in the archive.
        write("oslogstore-old.txt", "sessionKey=sk-ant-SHOULD-NOT-SHIP\n", mtime: install.addingTimeInterval(10))

        let eligible = LogsExporter.eligibleLogFiles(in: dir, installedAfter: install)
        XCTAssertEqual(eligible.map { $0.lastPathComponent }, ["diag-2026-06-03.jsonl"])

        let archiveURL = try LogsExporter.buildArchive(from: eligible)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path), "archive should be created")

        // Decode the archive into a temp dir and verify the extracted file set + content.
        let extractDir = dir.appendingPathComponent("extracted", isDirectory: true)
        try Self.decodeArchive(at: archiveURL, into: extractDir)

        let extracted = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        let extractedNames = Set(extracted.map { $0.lastPathComponent })
        XCTAssertTrue(extractedNames.contains("diag-2026-06-03.jsonl"), "diag file missing from archive: \(extractedNames)")
        XCTAssertFalse(extractedNames.contains { $0.hasPrefix("oslogstore-") }, "oslogstore artifact leaked into archive")

        let extractedContent = (try? String(contentsOf: extractDir.appendingPathComponent("diag-2026-06-03.jsonl"), encoding: .utf8)) ?? ""
        XCTAssertFalse(extractedContent.contains("sk-ant-SHOULD-NOT-SHIP"), "secret from an excluded file is in the archive")
        XCTAssertTrue(extractedContent.contains("session-cookie-captured"))

        // Sanity: the original on-disk diag content equals what we archived (no mutation).
        let original = try String(contentsOf: diagURL, encoding: .utf8)
        XCTAssertEqual(extractedContent, original)
    }

    @MainActor
    func testExportWithSavePanel_nothingToExport_whenNoEligibleFiles() {
        // Empty dir → nothingToExport (does not present the panel, does not crash).
        let result = LogsExporter.exportWithSavePanel(logsDirectory: dir, installDate: Date())
        XCTAssertEqual(result, .nothingToExport)
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
