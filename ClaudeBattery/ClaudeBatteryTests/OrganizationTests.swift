import XCTest
@testable import ClaudeBattery

final class OrganizationTests: XCTestCase {

    // MARK: - Happy Path: Decode single org from JSON fixture

    func testDecodeSingleOrgFromFixture() throws {
        let data = try fixtureData("orgs_single")
        let orgs = try JSONDecoder().decode([Organization].self, from: data)

        XCTAssertEqual(orgs.count, 1)
        XCTAssertEqual(orgs[0].uuid, "org-abc-123-def-456")
    }

    // MARK: - Happy Path: Decode multiple orgs from JSON fixture

    func testDecodeMultipleOrgsFromFixture() throws {
        let data = try fixtureData("orgs_multiple")
        let orgs = try JSONDecoder().decode([Organization].self, from: data)

        XCTAssertEqual(orgs.count, 2)
        XCTAssertEqual(orgs[0].uuid, "org-abc-123-def-456")
        XCTAssertEqual(orgs[1].uuid, "org-xyz-789-ghi-012")
    }

    // MARK: - Edge Case: Empty array decodes to zero orgs

    func testDecodeEmptyArrayFromFixture() throws {
        let data = try fixtureData("orgs_empty")
        let orgs = try JSONDecoder().decode([Organization].self, from: data)

        XCTAssertTrue(orgs.isEmpty)
    }

    // MARK: - Edge Case: Extra fields are ignored (forward compatibility)

    func testDecodeIgnoresExtraFields() throws {
        let json = """
        [
          {
            "uuid": "org-enriched-999",
            "name": "Acme Corp",
            "billing_type": "pro",
            "created_at": "2025-01-01T00:00:00Z"
          }
        ]
        """.data(using: .utf8)!

        let orgs = try JSONDecoder().decode([Organization].self, from: json)

        XCTAssertEqual(orgs.count, 1)
        XCTAssertEqual(orgs[0].uuid, "org-enriched-999")
    }

    // MARK: - Error Path: Missing uuid key fails to decode

    func testDecodeMissingUuidThrows() {
        let json = """
        [{"name": "No UUID Org"}]
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode([Organization].self, from: json))
    }

    // MARK: - sanitizedName (stored on Account for disambiguation, issue #32)

    func testSanitizedName_nilWhenNoName() {
        let org = Organization(uuid: "o", name: nil, billingType: "pro", emailAddress: nil)
        XCTAssertNil(org.sanitizedName, "no real name -> nil (billingType is a displayName fallback, not a name)")
    }

    func testSanitizedName_stripsNewlinesAndRTLMarks() {
        let org = Organization(uuid: "o", name: "Ac\nme\u{200F}", billingType: nil, emailAddress: nil)
        XCTAssertEqual(org.sanitizedName, "Acme")
    }

    func testSanitizedName_capsAt100Chars() {
        let org = Organization(uuid: "o", name: String(repeating: "x", count: 150), billingType: nil, emailAddress: nil)
        XCTAssertEqual(org.sanitizedName?.count, 100)
    }

    func testDisplayName_stillFallsBackToBillingTypeThenOrganization() {
        XCTAssertEqual(Organization(uuid: "o", name: nil, billingType: "pro", emailAddress: nil).displayName, "Pro")
        XCTAssertEqual(Organization(uuid: "o", name: nil, billingType: nil, emailAddress: nil).displayName, "Organization")
        XCTAssertEqual(Organization(uuid: "o", name: "Acme", billingType: nil, emailAddress: nil).displayName, "Acme")
    }

    // MARK: - Helpers

    private func fixtureData(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            // Fall back to file-relative path for SPM-style test targets
            let path = URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name).json")
            return try Data(contentsOf: path)
        }
        return try Data(contentsOf: url)
    }
}
