import XCTest
@testable import ClaudeBattery

/// Tests for the gating redesign (U6): the logger is INERT until enabled (no file, no
/// directory, nil URL), opens lazily on the first gated emit, writes session-start once,
/// and runs every emitted line through `SecretRedactor`.
final class DiagnosticsLoggerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsLoggerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Enabled logger writing into the test temp dir.
    private func makeEnabledLogger() -> DiagnosticsLogger {
        DiagnosticsLogger(directoryOverride: tempDir, enabledOverride: true)
    }

    /// Disabled logger — must produce no artifact at all.
    private func makeDisabledLogger() -> DiagnosticsLogger {
        DiagnosticsLogger(directoryOverride: tempDir, enabledOverride: false)
    }

    private func readAllLines(from url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    // MARK: - Inert when disabled

    func testDisabled_noFileNoDirectoryNoURL() {
        let logger = makeDisabledLogger()
        logger.emitMilestone(kind: "should-not-write", payload: ["a": 1])

        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertNil(logger.currentSessionFileURL, "disabled logger must not resolve a file URL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path),
                       "disabled logger must not create the log directory")
    }

    func testDisabled_flushIsNoOp() {
        let logger = makeDisabledLogger()
        logger.flush() // must not crash, must not create anything
        XCTAssertNil(logger.currentSessionFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
    }

    // MARK: - Lazy open + session-start on first gated emit

    func testInit_isInert_noFileBeforeFirstEmit() {
        let logger = makeEnabledLogger()
        // Construction alone must not open the file (the old design wrote session-start in init).
        XCTAssertNil(logger.currentSessionFileURL, "enabled logger must stay inert until first emit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testFirstEmitWhenEnabled_writesPathResolvedAndSessionStart() {
        let logger = makeEnabledLogger()
        logger.emitMilestone(kind: "first-real-event", payload: ["k": "v"])

        Thread.sleep(forTimeInterval: 0.05)

        let url = logger.currentSessionFileURL
        XCTAssertNotNil(url, "first gated emit should lazily open the file")
        let lines = readAllLines(from: url!)
        XCTAssertGreaterThanOrEqual(lines.count, 3)

        XCTAssertEqual(decode(lines[0])?["kind"] as? String, "path-resolved")
        XCTAssertEqual(decode(lines[1])?["kind"] as? String, "session-start")
        XCTAssertEqual(decode(lines[2])?["kind"] as? String, "first-real-event")
    }

    func testPathResolved_namesTheFileWithoutTheAbsolutePath() {
        // The export is written to be attached to a public GitHub issue, and the absolute path
        // carries the macOS account name. The redactor cannot help: a bare filesystem path has no
        // `=`, no `@` and no scheme, so it ships verbatim. Keep the file name and a home-relative
        // directory, and make the override a presence marker rather than a second path.
        let logger = makeEnabledLogger()
        logger.emitMilestone(kind: "first-real-event", payload: ["k": "v"])
        Thread.sleep(forTimeInterval: 0.05)

        let lines = readAllLines(from: logger.currentSessionFileURL!)
        let payload = decode(lines[0])?["payload"] as? [String: Any]
        XCTAssertNil(payload?["path"], "the absolute path must not be emitted")
        XCTAssertEqual(payload?["file"] as? String, logger.currentSessionFileURL?.lastPathComponent)
        XCTAssertEqual(payload?["directoryOverride"] as? String, "(set)",
                       "a test override is a home-shaped path too, so it is reported as presence only")
        XCTAssertFalse(lines[0].contains(NSHomeDirectory()),
                       "no home path may reach a file the user is told to post publicly")
    }

    func testEnabled_createsMissingDirectoryOnFirstEmit() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
        let logger = makeEnabledLogger()
        logger.emitMilestone(kind: "open", payload: [:])
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testSessionStart_writtenOnlyOnce() {
        let logger = makeEnabledLogger()
        for i in 0..<5 { logger.emitMilestone(kind: "evt", payload: ["i": i]) }
        Thread.sleep(forTimeInterval: 0.1)

        let lines = readAllLines(from: logger.currentSessionFileURL!)
        let starts = lines.filter { decode($0)?["kind"] as? String == "session-start" }
        XCTAssertEqual(starts.count, 1, "session-start must be written exactly once")
    }

    // MARK: - Milestone writes valid JSON

    func testEmitMilestone_writesValidJSONLine() {
        let logger = makeEnabledLogger()
        logger.emitMilestone(kind: "test-event", payload: ["key": "value", "n": 42])

        Thread.sleep(forTimeInterval: 0.05)

        let lines = readAllLines(from: logger.currentSessionFileURL!)
        let matchingLine = lines.first { $0.contains("\"kind\":\"test-event\"") }
        XCTAssertNotNil(matchingLine, "Expected a line with kind=test-event in \(lines)")

        let decoded = decode(matchingLine!)
        XCTAssertEqual(decoded?["kind"] as? String, "test-event")
        XCTAssertNotNil(decoded?["ts"])
        let payload = decoded?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["key"] as? String, "value")
        XCTAssertEqual(payload?["n"] as? Int, 42)
    }

    // MARK: - Redaction through the producer

    func testEmit_redactsSecretValuesBeforeWrite() {
        let logger = makeEnabledLogger()
        logger.emitMilestone(kind: "leaky", payload: [
            "sessionKey": "sk-ant-sid01-shouldnotsurvive",
            "note": "from user@leak.com",
            "__cf_bm": "cfbmShouldNotSurvive12345"
        ])
        Thread.sleep(forTimeInterval: 0.05)

        let content = (try? String(contentsOf: logger.currentSessionFileURL!, encoding: .utf8)) ?? ""
        XCTAssertFalse(content.contains("sk-ant-sid01-shouldnotsurvive"), "sessionKey leaked to disk: \(content)")
        XCTAssertFalse(content.contains("user@leak.com"), "email leaked to disk: \(content)")
        XCTAssertFalse(content.contains("cfbmShouldNotSurvive12345"), "__cf_bm leaked to disk: \(content)")
        XCTAssertTrue(content.contains("REDACTED_LEN_"), "expected redaction marker: \(content)")
    }

    /// `redactedLine` is the single redaction chokepoint every emit goes through. Asserting it
    /// redacts a planted secret proves the wiring; if the redact call were dropped, this fails.
    func testRedactionChokepoint_redactsSecrets() {
        let logger = makeEnabledLogger()
        let line = logger.redactedLine(kind: "cookie-store-poll", payload: [
            "sessionKey": "sk-ant-HOTLEAK",
            "names": "sessionKey=.claude.ai, __cf_bm=.claude.ai",
            "note": "from chokepoint@leak.com"
        ])
        XCTAssertFalse(line.contains("sk-ant-HOTLEAK"), "sessionKey survived: \(line)")
        XCTAssertFalse(line.contains("chokepoint@leak.com"), "email survived: \(line)")
        XCTAssertTrue(line.contains("REDACTED_LEN_"), "line not redacted: \(line)")
    }

    // MARK: - Volume

    func testEmitMilestone_writes100Entries() {
        let logger = makeEnabledLogger()
        for i in 0..<100 {
            logger.emitMilestone(kind: "bulk", payload: ["i": i])
        }

        Thread.sleep(forTimeInterval: 0.2)

        let lines = readAllLines(from: logger.currentSessionFileURL!)
        let bulkLines = lines.filter { $0.contains("\"kind\":\"bulk\"") }
        XCTAssertEqual(bulkLines.count, 100, "Expected 100 bulk entries, got \(bulkLines.count)")

        for line in bulkLines {
            XCTAssertNotNil(decode(line), "Line is not valid JSON: \(line)")
        }
    }

    // MARK: - Concurrent writes

    func testConcurrentMilestoneEmits_produceWellFormedLines() {
        let logger = makeEnabledLogger()
        // Open the file first so currentSessionFileURL is resolved before the concurrent burst.
        logger.emitMilestone(kind: "warmup", payload: [:])
        Thread.sleep(forTimeInterval: 0.05)

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "concurrent.test", attributes: .concurrent)

        for i in 0..<50 {
            group.enter()
            queue.async {
                logger.emitMilestone(kind: "concurrent", payload: ["i": i, "padding": String(repeating: "x", count: 100)])
                group.leave()
            }
        }
        group.wait()
        Thread.sleep(forTimeInterval: 0.2)

        let lines = readAllLines(from: logger.currentSessionFileURL!)
        let concurrentLines = lines.filter { $0.contains("\"kind\":\"concurrent\"") }
        XCTAssertEqual(concurrentLines.count, 50)
        for line in concurrentLines {
            XCTAssertNotNil(decode(line), "Concurrent write produced malformed JSON: \(line)")
        }
    }

    // MARK: - Per-launch file isolation (a build/process boundary starts a fresh file)

    func testEachLaunchWritesItsOwnFile_noCrossLaunchAppend() {
        // ADV-001/REL-01: each launch (process) writes its OWN diag-<date>-<launch>.jsonl rather
        // than appending to a shared per-day file, so a build boundary's install-date floor stays
        // accurate (a prior build's file is never re-touched and keeps its old mtime).
        var firstURL: URL?
        do {
            let logger = makeEnabledLogger()
            logger.emitMilestone(kind: "first-session", payload: ["a": 1])
            Thread.sleep(forTimeInterval: 0.05)
            firstURL = logger.currentSessionFileURL
            logger.flush()
        }

        let logger2 = makeEnabledLogger()
        logger2.emitMilestone(kind: "second-session", payload: ["b": 2])
        Thread.sleep(forTimeInterval: 0.05)
        let secondURL = logger2.currentSessionFileURL

        XCTAssertNotNil(firstURL)
        XCTAssertNotNil(secondURL)
        XCTAssertNotEqual(firstURL, secondURL, "each launch must use its own diag file")

        let secondKinds = readAllLines(from: secondURL!).compactMap { decode($0)?["kind"] as? String }
        XCTAssertTrue(secondKinds.contains("second-session"))
        XCTAssertFalse(secondKinds.contains("first-session"),
                       "a per-launch file must not contain a prior launch's lines: \(secondKinds)")

        // Both per-launch files remain on disk and are export-eligible.
        let eligible = LogsExporter.eligibleLogFiles(in: tempDir, installedAfter: .distantPast)
        XCTAssertEqual(eligible.count, 2, "both per-launch diag files should be eligible")
    }

    // MARK: - Transient open failure does not permanently disable logging (REL-02)

    func testOpenFailure_noCrash_noFalseURL() {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // A regular file where the logger expects a directory: createDirectory(at:) fails, so the
        // open fails. The logger must not crash, must not resolve a URL, and (because it does not
        // latch didStartSession on failure) a later emit re-attempts rather than being disabled.
        let blockerFile = tempDir.appendingPathComponent("blocker", isDirectory: false)
        try? "x".data(using: .utf8)!.write(to: blockerFile)
        let unwritable = blockerFile.appendingPathComponent("logs", isDirectory: true)

        let logger = DiagnosticsLogger(directoryOverride: unwritable, enabledOverride: true)
        logger.emitMilestone(kind: "evt1", payload: [:])
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNil(logger.currentSessionFileURL, "a failed open must not resolve a file URL")

        logger.emitMilestone(kind: "evt2", payload: [:])
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNil(logger.currentSessionFileURL, "re-attempt after a failed open must stay crash-free")
    }

    // MARK: - Retention prunes old diag files on session start (DI-01)

    func testOldDiagFilesPrunedOnSessionStart() {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let ancient = tempDir.appendingPathComponent("diag-2000-01-01-oldtoken.jsonl")
        try? "{\"kind\":\"ancient\"}\n".data(using: .utf8)!.write(to: ancient)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                                               ofItemAtPath: ancient.path)

        let logger = makeEnabledLogger()
        logger.emitMilestone(kind: "new-session", payload: [:])
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ancient.path),
                       "a diag file older than the retention window should be pruned on session start")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logger.currentSessionFileURL!.path),
                      "the current session's file must remain")
    }

    // MARK: - Production gate reads the shared defaults key (drift guard, swift-ios-001)

    func testProductionGate_readsSharedDefaultsKey() {
        let key = DiagnosticsDefaults.loggingEnabledKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        // A production logger (enabledOverride nil) must read the gate from the SAME key the
        // SettingsView @AppStorage writes, so the toggle and producer cannot drift.
        UserDefaults.standard.set(true, forKey: key)
        let logger = DiagnosticsLogger(directoryOverride: tempDir, enabledOverride: nil)
        XCTAssertTrue(logger.diagnosticLoggingEnabled, "production gate must read DiagnosticsDefaults.loggingEnabledKey")
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(logger.diagnosticLoggingEnabled)
    }

    // MARK: - serialize-failed fallback preserves the kind + payload key names (DI-03)

    func testSerializeFailedFallback_preservesKindAndKeys() {
        let logger = makeEnabledLogger()
        // A Date value is not JSON-serializable, so serialize() takes the fallback branch.
        let line = logger.redactedLine(kind: "cookie-store-poll", payload: [
            "count": 3,
            "when": Date()
        ])
        XCTAssertTrue(line.contains("serialize-failed"), "expected the serialize-failed fallback: \(line)")
        XCTAssertTrue(line.contains("cookie-store-poll"), "fallback must preserve the original kind: \(line)")
        XCTAssertTrue(line.contains("count"), "fallback must preserve payload key names: \(line)")
        XCTAssertTrue(line.contains("when"), "fallback must preserve payload key names: \(line)")
    }

    /// Control chars (TAB, U+0001) in the kind or in a payload KEY name must not break the
    /// fallback's JSON validity. The old string-interpolation fallback only stripped `\`, `"`,
    /// and `\n`, so a TAB/CR/other control char passed through and produced invalid JSON; the
    /// `JSONSerialization`-built fallback escapes them correctly.
    func testSerializeFailedFallback_withControlCharsInKindAndKeys_isValidJSON() {
        let logger = makeEnabledLogger()
        // Date values force the primary serialization to fail (non-JSON-serializable), and the
        // control chars live in the kind and a payload key name that the fallback echoes back.
        let line = logger.redactedLine(kind: "bad\u{0009}kind\u{0001}", payload: [
            "k\u{0009}ey": Date(),
            "norm": Date()
        ])

        let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
        XCTAssertNotNil(obj, "fallback line with control chars must still be valid JSON: \(line)")

        let dict = obj as? [String: Any]
        XCTAssertEqual(dict?["kind"] as? String, "serialize-failed", "fallback must report serialize-failed: \(line)")
        let payload = dict?["payload"] as? [String: Any]
        XCTAssertNotNil(payload?["failed_kind"], "fallback payload must carry failed_kind: \(line)")
        XCTAssertNotNil(payload?["keys"], "fallback payload must carry keys: \(line)")
    }
}
