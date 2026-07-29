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

    // MARK: - Plan sample (R6): the milestone that collects plan data for tiers nobody here can see

    /// The real `plan-sample` payload, driven through the real producer and the real archive.
    ///
    /// Two things it pins. The SIGNAL survives: the tier string, the capabilities, the billing type,
    /// the reset times and the applied ratio are the whole point of the milestone, and a redactor
    /// change that scrubbed any of them would leave a reporter's file useless while every
    /// no-secrets assertion still passed. And the line is not silently thrown away:
    /// `DiagnosticsLogger.serialize` degrades a payload it cannot encode to a `serialize-failed`
    /// stub with the values dropped, so a Date or a bare nil sneaking into the payload would lose
    /// every sample without failing anything else.
    func testEndToEnd_planSample_carriesPlanSignalAndIsNotDropped() throws {
        let accountId = UUID()
        let usage = Self.makeUsage(session: 100, weekly: 6,
                                   sessionResetsAt: Self.sessionReset,
                                   weeklyResetsAt: Self.weeklyReset,
                                   planRatio: PlanRatio.max5x)
        let logger = DiagnosticsLogger(directoryOverride: dir, enabledOverride: true)
        logger.emitMilestone(kind: UsageService.planSampleKind,
                             payload: UsageService.planSamplePayload(
                                accountId: accountId,
                                rateLimitTier: "default_claude_max_5x",
                                capabilities: ["claude_max", "chat"],
                                billingType: "stripe_subscription",
                                usage: usage,
                                measurement: Self.measurement))
        logger.flush()
        Thread.sleep(forTimeInterval: 0.2)

        let combined = try Self.exportedText(from: dir, into: dir.appendingPathComponent("extracted-plan", isDirectory: true))

        XCTAssertTrue(combined.contains("plan-sample"), "the plan-sample kind is missing: \(combined)")
        XCTAssertFalse(combined.contains("serialize-failed"),
                       "the payload could not be encoded, so the sample was dropped: \(combined)")
        XCTAssertTrue(combined.contains("default_claude_max_5x"),
                      "the tier string is the whole reason this milestone exists: \(combined)")
        XCTAssertTrue(combined.contains("claude_max") && combined.contains("chat"),
                      "capabilities lost: \(combined)")
        XCTAssertTrue(combined.contains("stripe_subscription"), "billing type lost: \(combined)")
        // Reset times carry colons and hyphens, which trip the credential, cookie and UUID
        // pre-filters on the way through. Both must come out intact and NOT swapped for each other.
        XCTAssertTrue(combined.contains(Self.sessionResetString), "session reset time lost: \(combined)")
        XCTAssertTrue(combined.contains(Self.weeklyResetString), "weekly reset time lost: \(combined)")
        // The one-way account tag is what keeps a two-account export from interleaving into one
        // unusable sequence, so it has to survive too.
        XCTAssertTrue(combined.contains(SecretRedactor.sha256Prefix(accountId.uuidString)),
                      "the account tag was redacted away: \(combined)")
        XCTAssertTrue(combined.contains("applied_ratio") && combined.contains("measured_ratio"),
                      "both ratios must be present, they answer different questions: \(combined)")
        // Nothing identifying may ride along even on the clean path.
        XCTAssertFalse(combined.contains(accountId.uuidString), "the raw account id reached the archive")
        for secret in Self.forbiddenSecrets {
            XCTAssertFalse(combined.contains(secret), "FORBIDDEN secret '\(secret)' present in exported archive bytes")
        }
    }

    /// The leak KTD6 exists to close. `GET /api/organizations` returns names shaped like
    /// `"someone@gmail.com's Organization"`, so an address arrives EMBEDDED in a longer string
    /// rather than as a bare value. `planSamplePayload` deliberately emits no org name at all, which
    /// is the actual guarantee - this pins the backstop behind it, by planting the org name on the
    /// new milestone in every shape a future producer might add it in: a plain string value, a
    /// value inside a longer sentence, and an IDN address.
    ///
    /// It also asserts the redaction is SCOPED. `[EMAIL]'s Organization` proves the address alone
    /// was matched mid-string; a pass that nuked the whole line would satisfy every "absent"
    /// assertion here while destroying the diagnostic.
    func testEndToEnd_planSampleWithEmailBearingOrgName_isRedacted() throws {
        let usage = Self.makeUsage(session: 100, weekly: 6,
                                   sessionResetsAt: Self.sessionReset,
                                   weeklyResetsAt: Self.weeklyReset,
                                   planRatio: PlanRatio.max5x)
        var payload = UsageService.planSamplePayload(accountId: UUID(),
                                                     rateLimitTier: "default_claude_max_5x",
                                                     capabilities: ["claude_max", "chat"],
                                                     billingType: "stripe_subscription",
                                                     usage: usage,
                                                     measurement: Self.measurement)
        payload["org_name"] = "victim@example.com's Organization"
        payload["org_name_idn"] = "jens@müller.de's Organization"
        payload["note"] = "sampled victim@example.com's Organization at 100/6"
        payload["orgs"] = ["victim@example.com's Organization", "someone.else@example.com's Org"]

        let logger = DiagnosticsLogger(directoryOverride: dir, enabledOverride: true)
        logger.emitMilestone(kind: UsageService.planSampleKind, payload: payload)
        logger.flush()
        Thread.sleep(forTimeInterval: 0.2)

        let combined = try Self.exportedText(from: dir, into: dir.appendingPathComponent("extracted-orgname", isDirectory: true))

        XCTAssertFalse(combined.contains("victim@example.com"),
                       "an org name's embedded address reached the archive: \(combined)")
        XCTAssertFalse(combined.contains("someone.else@example.com"),
                       "an org name's embedded address reached the archive: \(combined)")
        XCTAssertFalse(combined.contains("jens@müller.de"),
                       "an IDN org-name address reached the archive: \(combined)")
        XCTAssertFalse(combined.contains("müller.de"), "an IDN domain remnant reached the archive: \(combined)")
        XCTAssertNil(combined.range(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", options: .regularExpression),
                     "an @-email survived from an org name: \(combined)")
        XCTAssertTrue(combined.contains("[EMAIL]"),
                      "no email marker, so the address was never matched: \(combined)")
        XCTAssertTrue(combined.contains("[EMAIL]'s Organization"),
                      "the mid-string match must scrub the address and leave the rest: \(combined)")
        // The real signal must still survive alongside the planted names.
        XCTAssertTrue(combined.contains("default_claude_max_5x"), "tier lost: \(combined)")
        XCTAssertFalse(combined.contains("serialize-failed"), "the sample was dropped: \(combined)")
    }

    /// The opt-in invariant, restated for the new milestone. `emitMilestone` gates on the toggle, so
    /// the plan sample must leave nothing on disk for a user who never turned logging on - and this
    /// one runs every couple of minutes, so a gate regression here would write continuously rather
    /// than once per sign-in.
    func testPlanSample_writesNothingWhenDiagnosticsDisabled() throws {
        let usage = Self.makeUsage(session: 100, weekly: 6,
                                   sessionResetsAt: Self.sessionReset,
                                   weeklyResetsAt: Self.weeklyReset,
                                   planRatio: PlanRatio.max5x)
        let logger = DiagnosticsLogger(directoryOverride: dir, enabledOverride: false)
        for _ in 0..<5 {
            logger.emitMilestone(kind: UsageService.planSampleKind,
                                 payload: UsageService.planSamplePayload(
                                    accountId: UUID(),
                                    rateLimitTier: "default_claude_max_5x",
                                    capabilities: ["claude_max", "chat"],
                                    billingType: "stripe_subscription",
                                    usage: usage,
                                    measurement: Self.measurement))
        }
        logger.flush()
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertNil(logger.currentSessionFileURL, "a disabled logger opened a file")
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(contents.filter { $0.lastPathComponent.hasPrefix("diag-") }.isEmpty,
                      "a disabled logger wrote a diag file: \(contents.map { $0.lastPathComponent })")
        XCTAssertTrue(LogsExporter.eligibleLogFiles(in: dir, installedAfter: Date(timeIntervalSince1970: 0)).isEmpty,
                      "a disabled logger produced something exportable")
    }

    /// The payload on its own, with no producer or archive around it.
    ///
    /// Absence has to be WRITTEN as JSON null, not left out. A reader deriving a ratio from these
    /// lines has to tell "this account has no measured ratio yet" apart from "this build did not
    /// emit the field", and a missing key cannot say which. The `isValidJSONObject` check is the
    /// one that matters most: it is the difference between a sample and a `serialize-failed` stub.
    func testPlanSamplePayload_isJSONEncodableAndWritesAbsenceAsNull() {
        // A brand-new account: no plan stored, no reset times, nothing measured, no ratio applied.
        let usage = Self.makeUsage(session: 40, weekly: 80,
                                   sessionResetsAt: nil, weeklyResetsAt: nil, planRatio: nil)
        let empty = RatioMeasurement(lastSessionRemaining: 40, lastSessionResetsAt: nil,
                                     lastWeeklyRemaining: 80, lastWeeklyResetsAt: nil,
                                     sessionPointsConsumed: 0, weeklyPointsConsumed: 0)
        let payload = UsageService.planSamplePayload(accountId: UUID(),
                                                     rateLimitTier: nil,
                                                     capabilities: nil,
                                                     billingType: nil,
                                                     usage: usage,
                                                     measurement: empty)

        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload),
                      "the payload must be encodable or the whole sample is replaced by a stub")
        for key in ["rate_limit_tier", "capabilities", "billing_type",
                    "session_resets_at", "weekly_resets_at", "measured_ratio", "applied_ratio"] {
            XCTAssertTrue(payload[key] is NSNull, "\(key) must be written as null when absent, not omitted")
        }
        XCTAssertEqual(payload["session_remaining"] as? Double, 40)
        XCTAssertEqual(payload["weekly_remaining"] as? Double, 80)

        // And the populated shape carries what it was given, measured ratio included: 42 weekly
        // points over 400 session points is 0.105, above the confidence bar and inside the
        // plausible band, so it is a number the reader can check against the table.
        let full = UsageService.planSamplePayload(accountId: UUID(),
                                                  rateLimitTier: "default_claude_max_5x",
                                                  capabilities: ["claude_max", "chat"],
                                                  billingType: "stripe_subscription",
                                                  usage: Self.makeUsage(session: 100, weekly: 6,
                                                                        sessionResetsAt: Self.sessionReset,
                                                                        weeklyResetsAt: Self.weeklyReset,
                                                                        planRatio: PlanRatio.max5x),
                                                  measurement: Self.measurement)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(full))
        XCTAssertEqual(full["rate_limit_tier"] as? String, "default_claude_max_5x")
        XCTAssertEqual(full["capabilities"] as? [String], ["claude_max", "chat"])
        XCTAssertEqual(full["billing_type"] as? String, "stripe_subscription")
        XCTAssertEqual(full["session_resets_at"] as? String, Self.sessionResetString)
        XCTAssertEqual(full["weekly_resets_at"] as? String, Self.weeklyResetString)
        XCTAssertEqual(full["applied_ratio"] as? Double, PlanRatio.max5x)
        XCTAssertEqual(full["measured_ratio"] as? Double ?? 0, 0.105, accuracy: 0.0001)
        // Neither the org name nor the org uuid nor the address is in the shape at all - not
        // emitted is the guarantee, the redactor is only the backstop behind it.
        for key in ["org_name", "organization_name", "organization_id", "email", "uuid"] {
            XCTAssertNil(full[key], "\(key) must not be part of the plan sample")
        }
    }

    // MARK: - Helpers (archive decode is shared via ArchiveTestSupport in LogsExporterTests)

    private static let sessionResetString = "2026-07-29T12:34:56Z"
    private static let weeklyResetString = "2026-08-02T03:04:05Z"
    private static let sessionReset = ISO8601DateFormatter().date(from: sessionResetString)!
    private static let weeklyReset = ISO8601DateFormatter().date(from: weeklyResetString)!

    /// A measurement past its confidence bar: 400 session points consumed against 42 weekly, so
    /// `ratio` is 0.105 rather than nil. The bar counts WEEKLY points, so a total of 4.2 - which
    /// whole-number readings could not produce anyway - would leave this nil and the payload
    /// carrying no measured ratio at all.
    private static let measurement = RatioMeasurement(lastSessionRemaining: 100,
                                                      lastSessionResetsAt: sessionReset,
                                                      lastWeeklyRemaining: 6,
                                                      lastWeeklyResetsAt: weeklyReset,
                                                      sessionPointsConsumed: 400,
                                                      weeklyPointsConsumed: 42)

    /// A `UsageData` built from the legacy per-field tiers, so session and weekly can be set
    /// independently. Mirrors the helper in `UsageServiceTests`; duplicated rather than shared
    /// because the two suites have no common base and this one needs the reset times set.
    private static func makeUsage(session: Double, weekly: Double,
                                  sessionResetsAt: Date?, weeklyResetsAt: Date?,
                                  planRatio: Double?) -> UsageData {
        func tier(remaining: Double, resetsAt: Date?) -> UsageTier {
            var json: [String: Any] = ["utilization": 100 - remaining]
            if let resetsAt {
                json["resets_at"] = ISO8601DateFormatter().string(from: resetsAt)
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            return try! decoder.decode(UsageTier.self, from: JSONSerialization.data(withJSONObject: json))
        }
        return UsageData(from: UsageResponse(fiveHour: tier(remaining: session, resetsAt: sessionResetsAt),
                                             sevenDay: tier(remaining: weekly, resetsAt: weeklyResetsAt),
                                             sevenDayOpus: nil,
                                             sevenDaySonnet: nil,
                                             extraUsage: nil,
                                             limits: nil,
                                             spend: nil),
                         planRatio: planRatio)
    }

    /// Run the REAL eligibility + archive path over whatever the producer wrote, and hand back
    /// every extracted byte as one string. The assertions are about what did and did not survive
    /// the whole producer-to-archive pipeline, so nothing here short-circuits it.
    private static func exportedText(from dir: URL, into extractDir: URL) throws -> String {
        let eligible = LogsExporter.eligibleLogFiles(in: dir, installedAfter: Date(timeIntervalSince1970: 0))
        let archiveURL = try LogsExporter.buildArchive(from: eligible)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        try ArchiveTestSupport.decode(at: archiveURL, into: extractDir)
        var combined = ""
        for f in try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil) {
            combined += (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        }
        return combined
    }
}
