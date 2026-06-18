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

    // Two scoped limits sharing display_name "Sonnet" must key on their distinct model ids,
    // not the shared display name, so the ForEach keys stay unique. Exercises the modelId-first
    // `ModelUsage.id` defense (id = modelId ?? displayName), which the id:null fixtures above do not.
    func testModelBars_duplicateDisplayName_distinctModelIds_keysStayUnique() throws {
        let json = """
        { "limits": [
            { "kind": "weekly_all", "group": "weekly", "percent": 49, "resets_at": "2026-06-21T23:00:00+00:00", "scope": null },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 3, "resets_at": "2026-06-21T22:59:59+00:00", "scope": { "model": { "id": "claude-sonnet-4-5", "display_name": "Sonnet" }, "surface": null } },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 7, "resets_at": "2026-06-21T22:59:59+00:00", "scope": { "model": { "id": "claude-sonnet-3-7", "display_name": "Sonnet" }, "surface": null } }
        ] }
        """
        let bars = UsagePopoverView.modelBars(for: try usage(from: json))

        // All keys (including the leading "__all_models__") must be unique.
        XCTAssertEqual(Set(bars.map { $0.id }).count, bars.count)

        // The two "Sonnet" bars carry the two distinct model ids, not the shared display name.
        let sonnetIds = bars.filter { $0.name == "Sonnet" }.map { $0.id }
        XCTAssertEqual(Set(sonnetIds), ["claude-sonnet-4-5", "claude-sonnet-3-7"])
    }

    // A real per-model bar whose display_name is literally "All Models" (and null model id) must
    // not collide with the synthetic aggregate's "__all_models__" key.
    func testModelBars_scopedModelNamedAllModels_doesNotCollideWithSyntheticKey() throws {
        let json = """
        { "limits": [
            { "kind": "weekly_all", "group": "weekly", "percent": 49, "resets_at": "2026-06-21T23:00:00+00:00", "scope": null },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 3, "resets_at": "2026-06-21T22:59:59+00:00", "scope": { "model": { "id": null, "display_name": "All Models" }, "surface": null } }
        ] }
        """
        let bars = UsagePopoverView.modelBars(for: try usage(from: json))

        XCTAssertEqual(bars.first?.id, "__all_models__")
        let scopedBar = bars.first { $0.name == "All Models" && $0.id != "__all_models__" }
        XCTAssertNotNil(scopedBar)
        XCTAssertEqual(scopedBar?.id, "All Models")  // id = modelId ?? displayName, modelId nil
        XCTAssertEqual(Set(bars.map { $0.id }).count, bars.count)  // still distinct keys
    }
}
