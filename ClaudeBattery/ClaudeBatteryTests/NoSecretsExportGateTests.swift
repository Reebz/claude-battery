import AppleArchive
import Compression
import System
import XCTest
@testable import ClaudeBattery

/// The repeatable, in-suite no-secrets gate (replaces the throwaway grep gate). Drives the REAL
/// producers — `DiagnosticsLogger` (enabled, temp dir) writing a `diag-*.jsonl`, plus the
/// `OSLogStoreDumper.renderRedacted` path writing an `oslogstore-*.txt` — with planted secrets of
/// every type, runs the ACTUAL `LogsExporter.buildArchive` over the eligible files, decodes the
/// archive, and asserts the extracted bytes contain NONE of the forbidden patterns. This is the
/// end-to-end producer→archive assertion the export contract depends on.
final class NoSecretsExportGateTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoSecretsGate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Forbidden substrings that must NEVER appear in the extracted archive bytes.
    private static let forbiddenSecrets = [
        "sk-ant-",                                   // session key / API token shape
        "victim@example.com",                        // ASCII email
        "jens@müller.de",                            // IDN email
        "müller.de",                                 // IDN domain remnant
        "3f2504e0-4f89-41d3-9a0c-0305e82c3301",      // raw org UUID
        "cfbmRAWVALUE",                              // raw __cf_bm
        "bearerRAWTOKEN",                            // bearer token
        "basicRAWCREDS",                             // basic creds
        "PWPLAINTEXT",                               // password
        "SIGNATUREBLOB",                             // signature
        "LEAKEDQUERYVAL",                            // url query value
        "FRAGTOKENLEAK"                              // url fragment token
    ]

    func testEndToEnd_producerToArchive_hasNoSecrets() throws {
        // 1) Real DiagnosticsLogger (enabled) → diag-*.jsonl with planted secrets of every type,
        //    including the NESTED-under-credential-key shapes (arrays/objects).
        let logger = DiagnosticsLogger(directoryOverride: dir, enabledOverride: true)
        logger.emitMilestone(kind: "planted", payload: [
            "sessionKey": "sk-ant-PLANTED1",
            "authorization": "Bearer bearerRAWTOKEN",
            "basic": "Basic basicRAWCREDS",
            "__cf_bm": "cfbmRAWVALUE-rotating",
            "password": "PWPLAINTEXT",
            "note": "account for victim@example.com and jens@müller.de",
            "url": "https://claude.ai/api/organizations/3f2504e0-4f89-41d3-9a0c-0305e82c3301?q=LEAKEDQUERYVAL#access=FRAGTOKENLEAK",
            // Nested secrets under credential keys (the P0 hole this gate also guards):
            "token": ["sk-ant-PLANTED2", "sk-ant-PLANTED3"],
            "signature": ["SIGNATUREBLOB"]
        ])
        logger.flush()

        // 2) Real OSLogStoreDumper render path → oslogstore-*.txt with planted raw os_log lines.
        try writeRenderedOSLogDump(secrets: [
            "JS document.cookie: sessionKey=sk-ant-PLANTED4; __cf_bm=cfbmRAWVALUE",
            "Account added and activated: victim@example.com",
            "Added account: jens@müller.de",
            "redirect https://claude.ai/cb#token=FRAGTOKENLEAK"
        ])

        // Settle the async producer write.
        Thread.sleep(forTimeInterval: 0.2)

        // 3) Eligibility over the REAL producer output (installDate far in the past so both files
        //    qualify), then the ACTUAL buildArchive.
        let eligible = LogsExporter.eligibleLogFiles(in: dir, installedAfter: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(eligible.isEmpty, "expected producer files to be eligible")
        let archiveURL = try LogsExporter.buildArchive(from: eligible)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        // 4) Decode and scan every extracted byte.
        let extractDir = dir.appendingPathComponent("extracted", isDirectory: true)
        try Self.decodeArchive(at: archiveURL, into: extractDir)

        let extractedFiles = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        XCTAssertFalse(extractedFiles.isEmpty, "archive decoded to no files")

        var combined = ""
        for f in extractedFiles {
            combined += (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        }

        for secret in Self.forbiddenSecrets {
            XCTAssertFalse(combined.contains(secret), "FORBIDDEN secret '\(secret)' present in exported archive bytes")
        }
        // A bare ASCII '@' that forms an email must not survive; assert no '@'-joined domain.
        XCTAssertNil(combined.range(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", options: .regularExpression),
                     "an @-email survived into the archive")
        // Proof the producers actually ran and were redacted (not just empty output).
        XCTAssertTrue(combined.contains("REDACTED_LEN_"), "expected redaction markers in archive content")
    }

    // MARK: - Helpers

    /// Write an `oslogstore-*.txt` using the dumper's real render+redact seam over planted lines.
    private func writeRenderedOSLogDump(secrets: [String]) throws {
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("oslogstore-\(ts).txt")
        var body = ""
        for msg in secrets {
            body += OSLogStoreDumper.renderRedacted(date: Date(), category: "Auth", level: "info", composedMessage: msg) + "\n"
        }
        try body.data(using: .utf8)!.write(to: url)
    }

    private static func decodeArchive(at archiveURL: URL, into destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let archivePath = FilePath(archiveURL), let destPath = FilePath(destination) else {
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
