import AppleArchive
import Compression
import System
import XCTest
@testable import ClaudeBattery

/// The repeatable, in-suite no-secrets gate (replaces the throwaway grep gate). Drives the REAL
/// controlled producer — `DiagnosticsLogger` (enabled, temp dir) writing a `diag-*.jsonl` — with
/// planted secrets of every type (incl. nested-under-credential-key), runs the ACTUAL
/// `LogsExporter.buildArchive` over the eligible files, decodes the archive, and asserts the
/// extracted bytes contain NONE of the forbidden patterns. Also plants an oslogstore-*.txt with a
/// raw secret in the same dir and asserts the export NEVER ships it (posture invariant). This is
/// the end-to-end producer→archive assertion the export contract depends on.
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
        "FRAGTOKENLEAK",                             // url fragment token
        "99887766554433",                            // numeric scalar under credential key
        "CLEARANCESECRETXYZ",                        // cf_clearance cookie value
        "OPAQUELASTURLSECRET",                       // lasturl cookie value
        "OPAQUENEXTURLSECRET"                        // next-url cookie value
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
            "customRedirect": "com.app.oauth://cb?code=FRAGTOKENLEAK",
            // Nested secrets under credential keys (the P0 hole this gate also guards):
            "token": ["sk-ant-PLANTED2", "sk-ant-PLANTED3"],
            "signature": ["SIGNATUREBLOB"],
            // Direct non-string scalar under a credential key (the scalar fail-open this gate guards).
            "assertion": 99887766554433,
            // cookieHeader-only keys: cf_clearance/lasturl/next-url live SOLELY in cookieHeaderKeys.
            "cookieHeader": "cf_clearance=CLEARANCESECRETXYZ; lasturl=OPAQUELASTURLSECRET; next-url=OPAQUENEXTURLSECRET; theme=dark"
        ])
        logger.flush()

        // 2) Plant an oslogstore-*.txt with a RAW secret in the same dir. The export must NEVER
        //    ship it — uncontrolled OSLog content is excluded by name (posture invariant).
        let rawOslog = dir.appendingPathComponent("oslogstore-2026-06-03T00-00-00Z.txt")
        try "Account added: victim@example.com sessionKey=sk-ant-OSLOGRAW\n".data(using: .utf8)!.write(to: rawOslog)

        // Settle the async producer write.
        Thread.sleep(forTimeInterval: 0.2)

        // 3) Eligibility over the REAL producer output (installDate far in the past), then the
        //    ACTUAL buildArchive. Eligibility must select ONLY the diag-*.jsonl.
        let eligible = LogsExporter.eligibleLogFiles(in: dir, installedAfter: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(eligible.map { $0.lastPathComponent.hasPrefix("diag-") }, [true],
                       "eligibility must select exactly one diag-*.jsonl and no oslogstore: \(eligible.map { $0.lastPathComponent })")
        let archiveURL = try LogsExporter.buildArchive(from: eligible)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        // 4) Decode and scan every extracted byte.
        let extractDir = dir.appendingPathComponent("extracted", isDirectory: true)
        try Self.decodeArchive(at: archiveURL, into: extractDir)

        let extractedFiles = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(extractedFiles.map { $0.lastPathComponent.hasPrefix("oslogstore-") }), [false],
                       "no oslogstore file may be in the archive: \(extractedFiles.map { $0.lastPathComponent })")

        var combined = ""
        for f in extractedFiles {
            combined += (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        }

        for secret in Self.forbiddenSecrets {
            XCTAssertFalse(combined.contains(secret), "FORBIDDEN secret '\(secret)' present in exported archive bytes")
        }
        // The raw OSLog secret must not be in the archive (the file was excluded by name).
        XCTAssertFalse(combined.contains("sk-ant-OSLOGRAW"), "raw OSLog secret reached the archive")
        // A bare ASCII '@' that forms an email must not survive; assert no '@'-joined domain.
        XCTAssertNil(combined.range(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", options: .regularExpression),
                     "an @-email survived into the archive")
        // Proof the producer actually ran and was redacted (not just empty output).
        XCTAssertTrue(combined.contains("REDACTED_LEN_"), "expected redaction markers in archive content")
    }

    // MARK: - Helpers

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
