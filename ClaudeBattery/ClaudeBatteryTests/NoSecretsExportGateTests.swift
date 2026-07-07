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
        try ArchiveTestSupport.decode(at: archiveURL, into: extractDir)

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

    /// Hardens the gate against two producer-shape regressions the original end-to-end test did not
    /// drive: (1) a STRUCTURED cookie pair carrying a `value` field (the real cookie-store-poll shape
    /// is name+domain; a regression adding the value would leak the live cookie/session value), and
    /// (2) a secret riding in a JSON KEY position under a credential key. Both are now redacted by
    /// the producer→archive pipeline; a wiring regression (dropping the `value` denylist entry or the
    /// JSON-walker key redaction) would leak verbatim and fail here.
    func testEndToEnd_structuredCookiePairsAndKeyPosition_hasNoSecrets() throws {
        let logger = DiagnosticsLogger(directoryOverride: dir, enabledOverride: true)
        logger.emitMilestone(kind: "cookie-store-poll", payload: [
            "count": 1,
            "names": [["name": "sessionKey", "domain": ".claude.ai", "value": "sk-ant-COOKIEVALSECRET"]]
        ])
        logger.emitMilestone(kind: "key-position", payload: [
            "token": ["sk-ant-KEYPOSSECRET": true]
        ])
        logger.flush()
        Thread.sleep(forTimeInterval: 0.2)

        let eligible = LogsExporter.eligibleLogFiles(in: dir, installedAfter: Date(timeIntervalSince1970: 0))
        let archiveURL = try LogsExporter.buildArchive(from: eligible)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let extractDir = dir.appendingPathComponent("extracted-structured", isDirectory: true)
        try ArchiveTestSupport.decode(at: archiveURL, into: extractDir)

        var combined = ""
        for f in try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil) {
            combined += (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        }
        XCTAssertFalse(combined.contains("sk-ant-COOKIEVALSECRET"), "structured cookie `value` leaked: \(combined)")
        XCTAssertFalse(combined.contains("sk-ant-KEYPOSSECRET"), "secret in JSON key position leaked: \(combined)")
        XCTAssertTrue(combined.contains("REDACTED_KEY_"), "expected key-position SHA redaction marker: \(combined)")
        XCTAssertTrue(combined.contains("REDACTED_LEN_"), "expected value redaction marker: \(combined)")
        // The producer's genuine signal — cookie NAME + domain — must survive (it is not a secret).
        XCTAssertTrue(combined.contains("sessionKey"), "cookie name signal lost: \(combined)")
        XCTAssertTrue(combined.contains("claude.ai"), "cookie domain signal lost: \(combined)")
    }

    /// Plant the REAL `login-state` producer shape (the U5 adversarial-pass gate blind spot).
    /// `AuthManager.updateLoginOverlay` interpolates the LoginState `.error` message into
    /// `payload["state"] = "error: \(message)"` and emits `kind: "login-state"`. Today every `.error`
    /// message is a static literal so nothing leaks — but the gate never planted this kind, so a future
    /// error path interpolating a secret (an org name, an API body, `error.localizedDescription`) would
    /// ship unredacted with a green suite. This pins the contract: a secret-shaped value in a
    /// login-state error is scrubbed by the unconditional producer→redactor→archive pipeline, which
    /// applies `SecretRedactor.redact` to every kind with no kind-based branch.
    func testEndToEnd_loginStateError_hasNoSecrets() throws {
        let logger = DiagnosticsLogger(directoryOverride: dir, enabledOverride: true)
        logger.emitMilestone(kind: "login-state", payload: [
            "state": "error: sign-in failed for victim@example.com (token sk-ant-LOGINSTATESECRET)"
        ])
        logger.flush()
        Thread.sleep(forTimeInterval: 0.2)

        let eligible = LogsExporter.eligibleLogFiles(in: dir, installedAfter: Date(timeIntervalSince1970: 0))
        let archiveURL = try LogsExporter.buildArchive(from: eligible)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        let extractDir = dir.appendingPathComponent("extracted-loginstate", isDirectory: true)
        try ArchiveTestSupport.decode(at: archiveURL, into: extractDir)

        var combined = ""
        for f in try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil) {
            combined += (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        }
        XCTAssertFalse(combined.contains("sk-ant-LOGINSTATESECRET"),
                       "login-state error token leaked into archive: \(combined)")
        XCTAssertFalse(combined.contains("victim@example.com"),
                       "login-state error email leaked into archive: \(combined)")
        XCTAssertNil(combined.range(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", options: .regularExpression),
                     "an @-email survived from the login-state line: \(combined)")
        XCTAssertTrue(combined.contains("REDACTED_LEN_"),
                      "expected redaction marker proving the login-state line was processed")
        // The non-secret signal — the `login-state` kind — must survive so the diagnostic stays useful.
        XCTAssertTrue(combined.contains("login-state"),
                      "login-state kind signal lost: \(combined)")
    }

    // MARK: - Helpers (archive decode is shared via ArchiveTestSupport in LogsExporterTests)
}
