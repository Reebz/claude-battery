import XCTest
@testable import ClaudeBattery

/// Locks the pure Models-card bar list (U4): an "All Models" bar from the real weekly
/// aggregate above the per-model bars, never fabricated (KTD6).
final class ModelsCardTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func usage(from json: String) throws -> UsageData {
        let response = try decoder().decode(UsageResponse.self, from: Data(json.utf8))
        return UsageData(from: response)
    }

    func testModelBars_allModelsFirst_thenSonnet_inOrder() throws {
        // weekly_all 49% used -> 51 remaining; Sonnet 3% used -> 97 remaining.
        let json = """
        { "limits": [
            { "kind": "weekly_all", "group": "weekly", "percent": 49, "resets_at": "2026-06-21T23:00:00+00:00", "scope": null },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 3, "resets_at": "2026-06-21T22:59:59+00:00", "scope": { "model": { "id": null, "display_name": "Sonnet" }, "surface": null } }
        ] }
        """
        let bars = UsagePopoverView.modelBars(for: try usage(from: json))

        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].name, "All Models")
        XCTAssertEqual(bars[0].value, 51, accuracy: 0.01)
        XCTAssertEqual(bars[1].name, "Sonnet")
        XCTAssertEqual(bars[1].value, 97, accuracy: 0.01)
    }

    func testAllModelsValue_equalsWeeklyRemaining_neverFabricated() throws {
        let json = """
        { "limits": [
            { "kind": "weekly_all", "group": "weekly", "percent": 49, "resets_at": "2026-06-21T23:00:00+00:00", "scope": null },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 3, "resets_at": "2026-06-21T22:59:59+00:00", "scope": { "model": { "id": null, "display_name": "Sonnet" }, "surface": null } }
        ] }
        """
        let data = try usage(from: json)
        let bars = UsagePopoverView.modelBars(for: data)

        XCTAssertEqual(bars.first?.value, data.weeklyRemaining)
        XCTAssertNotEqual(data.weeklyRemaining, 100)  // not a fabricated full bar (KTD6)
    }
}
