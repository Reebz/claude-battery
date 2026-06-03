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

    // MARK: - Persistence across reopens (append to existing file)

    func testReopeningDirectory_appendsToExistingFile() {
        do {
            let logger = makeEnabledLogger()
            logger.emitMilestone(kind: "first-session", payload: ["a": 1])
            Thread.sleep(forTimeInterval: 0.05)
            logger.flush()
        }

        let logger2 = makeEnabledLogger()
        logger2.emitMilestone(kind: "second-session", payload: ["b": 2])
        Thread.sleep(forTimeInterval: 0.05)

        let lines = readAllLines(from: logger2.currentSessionFileURL!)
        let kinds = lines.compactMap { decode($0)?["kind"] as? String }
        XCTAssertTrue(kinds.contains("first-session"), "First-session line should persist across reinit: \(kinds)")
        XCTAssertTrue(kinds.contains("second-session"))
    }
}
