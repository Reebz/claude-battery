import Foundation
import os
import XCTest
@testable import ClaudeBattery

/// Tests for the OSLog dump producer (U6). The P0 property is that every rendered line is
/// SecretRedactor-processed before write. `OSLogEntryLog` has no public initializer, so the
/// render+redact step is factored into the pure `renderRedacted(...)` seam and tested directly
/// with planted secrets. Also covers the gate-off invariant (no `oslogstore-*.txt` written).
final class OSLogStoreDumperTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OSLogStoreDumperTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func oslogstoreFiles() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("oslogstore-") && $0.lastPathComponent.hasSuffix(".txt") }
    }

    // MARK: - renderRedacted (the P0 redaction seam)

    func testRenderRedacted_redactsRawCookieInComposedMessage() {
        let line = OSLogStoreDumper.renderRedacted(
            date: Date(),
            category: "Auth",
            level: "debug",
            composedMessage: "JS document.cookie: sessionKey=sk-ant-PLANTED; __cf_bm=cfbmPLANTED"
        )
        XCTAssertFalse(line.contains("sk-ant-PLANTED"), "raw sessionKey survived the dump render: \(line)")
        XCTAssertFalse(line.contains("cfbmPLANTED"), "raw __cf_bm survived the dump render: \(line)")
        XCTAssertTrue(line.contains("REDACTED_LEN_"), "render did not redact: \(line)")
    }

    func testRenderRedacted_redactsEmailInComposedMessage() {
        let line = OSLogStoreDumper.renderRedacted(
            date: Date(),
            category: "Auth",
            level: "info",
            composedMessage: "Account added and activated: someone@example.com"
        )
        XCTAssertFalse(line.contains("someone@example.com"), "email survived the dump render: \(line)")
        XCTAssertTrue(line.contains("[EMAIL]"), "render did not redact email: \(line)")
    }

    func testRenderRedacted_redactsIDNEmailInComposedMessage() {
        let line = OSLogStoreDumper.renderRedacted(
            date: Date(),
            category: "Auth",
            level: "info",
            composedMessage: "Added account: jens@müller.de"
        )
        XCTAssertFalse(line.contains("müller.de"), "IDN email survived the dump render: \(line)")
        XCTAssertTrue(line.contains("[EMAIL]"), line)
    }

    func testRenderRedacted_preservesNonSecretStructure() {
        let line = OSLogStoreDumper.renderRedacted(
            date: Date(timeIntervalSince1970: 0),
            category: "Diagnostics",
            level: "notice",
            composedMessage: "nav-decision host=claude.ai"
        )
        XCTAssertTrue(line.contains("[Diagnostics]"), line)
        XCTAssertTrue(line.contains("notice"), line)
        XCTAssertTrue(line.contains("claude.ai"), line)
    }

    // MARK: - Gate-off invariant

    func testDump_disabled_writesNoFile() {
        OSLogStoreDumper.dump(hoursBack: 1, directoryOverride: dir, enabledOverride: false)
        XCTAssertTrue(oslogstoreFiles().isEmpty, "gate-off dump wrote an oslogstore file")
        // The directory itself must not be created by a disabled dump.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "gate-off dump created the log directory")
    }

    // MARK: - Gate-on writes a (redacted) file

    func testDump_enabled_writesRedactedFileAndPlantedSecretIsAbsent() throws {
        // Plant a secret in the real OSLog stream for this process, then dump.
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.claudebattery.app", category: "DumperTest")
        logger.notice("planted sessionKey=sk-ant-OSLOGPLANTED for dumper test")

        OSLogStoreDumper.dump(hoursBack: 1, directoryOverride: dir, enabledOverride: true)

        let files = oslogstoreFiles()
        // OSLogStore may be unreadable/empty in some CI hosts; only assert content when a file
        // was produced. The gate-off and renderRedacted tests cover the invariants deterministically.
        guard let file = files.first else {
            throw XCTSkip("OSLogStore produced no entries in this test host; render+gate covered elsewhere")
        }
        let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertFalse(content.contains("sk-ant-OSLOGPLANTED"), "planted secret survived into oslogstore dump: \(content)")
    }
}
