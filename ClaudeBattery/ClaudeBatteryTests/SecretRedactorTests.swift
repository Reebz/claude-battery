import XCTest
@testable import ClaudeBattery

/// The P0 redaction matrix: assert NO secret survives `SecretRedactor.redact`.
/// Covers credential keys, rotation-detectable cookies, bare emails (prose + JSON value),
/// the `Authorization: Bearer` leak the recon flagged, URL queries, UUID paths, idempotence,
/// and regex-compile resilience (the precompiled `static let` removes the silent-skip mode).
final class SecretRedactorTests: XCTestCase {

    // MARK: - Credential keys → REDACTED_LEN_N

    func testSessionKeyKeyValue_redactedToLen() {
        let out = SecretRedactor.redact("sessionKey=sk-ant-sid01-abcdef123456")
        XCTAssertFalse(out.contains("sk-ant"), "sessionKey value survived: \(out)")
        XCTAssertTrue(out.contains("REDACTED_LEN_"), "expected length signal: \(out)")
    }

    func testPasswordKeyValue_redactedToLen() {
        let out = SecretRedactor.redact("password: hunter2horse")
        XCTAssertFalse(out.contains("hunter2horse"), out)
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    func testTokenInJSON_redactedToLen() {
        let out = SecretRedactor.redact(#"{"token":"abc.def.ghi"}"#)
        XCTAssertFalse(out.contains("abc.def.ghi"), out)
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    func testAssertionInJSON_redactedToLen() {
        let out = SecretRedactor.redact(#"{"assertion":"webauthn-blob-9999"}"#)
        XCTAssertFalse(out.contains("webauthn-blob-9999"), out)
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    func testEmailKeyInJSON_redactedToLen() {
        // Under the `email` credential key the value is REDACTED_LEN_N (stronger than [EMAIL]).
        let out = SecretRedactor.redact(#"{"email":"user@example.com"}"#)
        XCTAssertFalse(out.contains("user@example.com"), out)
        XCTAssertFalse(out.contains("@example.com"), out)
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    // MARK: - Rotation-detectable cookies → 8-char SHA prefix only

    func testCfBmInJSON_keepsOnly8CharPrefix() {
        let raw = "AbCdEf0123456789-the-rest-of-a-long-cf-bm-token-value"
        let out = SecretRedactor.redact(#"{"__cf_bm":"\#(raw)"}"#)
        XCTAssertFalse(out.contains(raw), "raw __cf_bm survived: \(out)")
        XCTAssertFalse(out.contains("the-rest-of-a-long"), out)
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
        // 8-char lowercase hex SHA prefix present.
        let hasPrefix = out.range(of: "[0-9a-f]{8}\\.\\.\\.REDACTED_LEN_", options: .regularExpression) != nil
        XCTAssertTrue(hasPrefix, "expected 8-hex SHA prefix: \(out)")
    }

    func testCsrfTokenCookie_keepsOnly8CharPrefix() {
        let raw = "csrf-secret-token-value-1234567890"
        let out = SecretRedactor.redact("anthropic-csrf-token=\(raw)")
        XCTAssertFalse(out.contains(raw), out)
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    // MARK: - Bare email in prose AND in a JSON value → [EMAIL]

    func testBareEmailInProse_redactedToEmailToken() {
        let out = SecretRedactor.redact("Account added: jane.doe@example.co.uk via store")
        XCTAssertFalse(out.contains("jane.doe@example.co.uk"), out)
        XCTAssertFalse(out.contains("@"), "an @ survived in prose: \(out)")
        XCTAssertTrue(out.contains("[EMAIL]"), out)
    }

    func testBareEmailInNonCredentialJSONValue_redactedToEmailToken() {
        // `note` is NOT a credential key, so the email is caught by the regex email pass → [EMAIL].
        let out = SecretRedactor.redact(#"{"note":"contact mitch@gmail.com soon"}"#)
        XCTAssertFalse(out.contains("mitch@gmail.com"), out)
        XCTAssertFalse(out.contains("@gmail.com"), out)
        XCTAssertTrue(out.contains("[EMAIL]"), out)
    }

    func testDisplayNameEmailInJSONValue_doesNotSurvive() {
        // displayName == email when no nickname; producer must never emit it, but if it slips
        // through a non-credential key, the email pass still catches it.
        let out = SecretRedactor.redact(#"{"displayName":"someone@anthropic.com"}"#)
        XCTAssertFalse(out.contains("someone@anthropic.com"), out)
        XCTAssertTrue(out.contains("[EMAIL]"), out)
    }

    // MARK: - Authorization: Bearer (the recon-flagged latent leak) → fully redacted

    func testAuthorizationBearer_fullyRedacted() {
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig"
        let out = SecretRedactor.redact("Authorization: Bearer \(token)")
        XCTAssertFalse(out.contains(token), "Bearer token survived: \(out)")
        XCTAssertFalse(out.contains("payload"), out)
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
        // The scheme word may remain, but no token characters after it.
        XCTAssertFalse(out.contains("Bearer \(token)"), out)
    }

    func testBearerTokenInJSONValue_fullyRedacted() {
        let token = "abc123def456ghi789jkl"
        let out = SecretRedactor.redact(#"{"header":"Bearer \#(token)"}"#)
        XCTAssertFalse(out.contains(token), out)
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    func testAuthorizationBasic_fullyRedacted() {
        let creds = "dXNlcjpwYXNzd29yZA=="
        let out = SecretRedactor.redact("Authorization: Basic \(creds)")
        XCTAssertFalse(out.contains(creds), out)
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    // MARK: - URL query → [REDACTED]

    func testURLQuery_redacted() {
        let out = SecretRedactor.redact("Fetching https://claude.ai/api/x?sessionKey=secret&t=1")
        XCTAssertFalse(out.contains("sessionKey=secret"), out)
        XCTAssertFalse(out.contains("secret"), out)
        XCTAssertTrue(out.contains("?[REDACTED]"), out)
        XCTAssertTrue(out.contains("https://claude.ai/api/x"), "URL base should be kept: \(out)")
    }

    // MARK: - UUID path → [ORG-UUID]

    func testUUIDPath_redacted() {
        let out = SecretRedactor.redact("GET /api/organizations/3f2504e0-4f89-41d3-9a0c-0305e82c3301/usage")
        XCTAssertFalse(out.contains("3f2504e0-4f89-41d3-9a0c-0305e82c3301"), out)
        XCTAssertTrue(out.contains("[ORG-UUID]"), out)
    }

    // MARK: - Mixed cookie header (secret + harmless pairs)

    func testMixedCookieHeader_redactsSecretsKeepsHarmless() {
        let header = "Cookie: sessionKey=sk-ant-deadbeef; __cf_bm=cfbmsecretvalue999; theme=dark"
        let out = SecretRedactor.redact(header)
        XCTAssertFalse(out.contains("sk-ant-deadbeef"), out)
        XCTAssertFalse(out.contains("cfbmsecretvalue999"), out)
        // Harmless, non-credential cookie value is preserved.
        XCTAssertTrue(out.contains("theme=dark"), "harmless cookie should survive: \(out)")
    }

    // MARK: - Idempotence

    func testIdempotence_reRedactingIsStable() {
        let inputs = [
            "sessionKey=sk-ant-sid01-abcdef123456",
            "Account added: jane.doe@example.co.uk",
            "Authorization: Bearer eyJ.payload.sig",
            #"{"__cf_bm":"AbCdEf0123456789longtoken"}"#,
            "https://claude.ai/x?sessionKey=secret&t=1",
            "/api/organizations/3f2504e0-4f89-41d3-9a0c-0305e82c3301/usage"
        ]
        for input in inputs {
            let once = SecretRedactor.redact(input)
            let twice = SecretRedactor.redact(once)
            XCTAssertEqual(once, twice, "redact is not idempotent for: \(input)\n once: \(once)\n twice: \(twice)")
        }
    }

    // MARK: - Regex-compile resilience (precompiled static let removes silent-skip)

    func testEmptyAndPlainStrings_passThrough() {
        XCTAssertEqual(SecretRedactor.redact(""), "")
        XCTAssertEqual(SecretRedactor.redact("nothing to see here"), "nothing to see here")
    }

    func testCredentialRedactionAlwaysRuns_noSilentSkip() {
        // The credential-key regex is a precompiled static let (try!), so it cannot silently
        // skip on a per-call compile failure the way the former `try?` could. Proven by the
        // value being redacted every time across many calls.
        for i in 0..<200 {
            let out = SecretRedactor.redact("sessionKey=secretvalue\(i)")
            XCTAssertFalse(out.contains("secretvalue\(i)"), "call \(i) skipped redaction: \(out)")
            XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
        }
    }

    // MARK: - Composite line (every secret type at once)

    func testCompositeLine_noSecretSurvives() {
        let line = """
        sessionKey=sk-ant-sid01-LEAK; __cf_bm=cfbmLEAKvalue; \
        Authorization: Bearer bearerLEAKtoken email user@leak.com \
        https://claude.ai/api?token=LEAK /orgs/3f2504e0-4f89-41d3-9a0c-0305e82c3301
        """
        let out = SecretRedactor.redact(line)
        for secret in ["sk-ant-sid01-LEAK", "cfbmLEAKvalue", "bearerLEAKtoken", "user@leak.com", "3f2504e0-4f89-41d3-9a0c-0305e82c3301"] {
            XCTAssertFalse(out.contains(secret), "secret '\(secret)' survived: \(out)")
        }
        XCTAssertFalse(out.contains("@leak.com"), out)
    }
}
