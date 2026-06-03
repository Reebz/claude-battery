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
        // The test's namesake: a rotation-detectable key keeps an 8-hex SHA prefix on the regex
        // (non-JSON) path too, so rotation stays observable. Mirrors the JSON sibling's assertion;
        // without this a lost rotationDetectableKeys membership would pass silently.
        XCTAssertNotNil(out.range(of: "[0-9a-f]{8}\\.\\.\\.REDACTED_LEN_", options: .regularExpression),
                        "expected 8-hex SHA rotation prefix: \(out)")
    }

    // MARK: - Bare email in prose AND in a JSON value → [EMAIL]

    func testBareEmailInProse_redactedToEmailToken() {
        let out = SecretRedactor.redact("Account added: jane.doe@example.co.uk via store")
        // Narrowed to the secret itself (local part + domain), not a global `@` ban — a later
        // change introducing a legitimate @mention should not fail a correct redaction.
        XCTAssertFalse(out.contains("jane.doe@example.co.uk"), out)
        XCTAssertFalse(out.contains("jane.doe"), out)
        XCTAssertFalse(out.contains("example.co.uk"), out)
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
        // The full token (which itself contains the "payload" segment) must be gone; assert on
        // the token and its segments, not a bare "payload" substring that prose could carry.
        XCTAssertFalse(out.contains(token), "Bearer token survived: \(out)")
        XCTAssertFalse(out.contains(".payload."), out)
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
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

    // MARK: - P0: secrets nested in an array/object UNDER a credential key must not survive

    /// THE test that proves the nested-JSON-under-credential-key leak is closed. Each case puts
    /// an opaque (non-regex-detectable) secret inside an array or object whose parent key is a
    /// credential key, including the exact `serialize()` envelope shape the producer writes.
    func testNestedSecretUnderCredentialKey_doesNotSurvive() {
        let cases: [(String, [String])] = [
            // Arrays under a credential key.
            (#"{"token":["sk-ant-LEAK1","sk-ant-LEAK2"]}"#, ["sk-ant-LEAK1", "sk-ant-LEAK2"]),
            (#"{"password":["PWSECRET1"]}"#, ["PWSECRET1"]),
            (#"{"assertion":["ASSERTLEAK"]}"#, ["ASSERTLEAK"]),
            // Objects under a credential key.
            (#"{"signature":{"r":"SIGLEAK","s":"SIGLEAK2"}}"#, ["SIGLEAK", "SIGLEAK2"]),
            (#"{"signature":{"raw":"SIGSECRETVALUE"}}"#, ["SIGSECRETVALUE"]),
            (#"{"_csrf":{"v":"CSRFLEAK"}}"#, ["CSRFLEAK"]),
            // Deeply nested.
            (#"{"token":{"a":{"b":["sk-ant-DEEPLEAK"]}}}"#, ["sk-ant-DEEPLEAK"]),
            // The realistic serialize() envelope: payload nested under a credential key.
            (#"{"kind":"x","payload":{"token":["sk-ant-ENVLEAK1","sk-ant-ENVLEAK2"]},"ts":"2026-06-03T00:00:00Z"}"#, ["sk-ant-ENVLEAK1", "sk-ant-ENVLEAK2"]),
            (#"{"kind":"x","payload":{"signature":{"r":"ENVSIGLEAK"}},"ts":"t"}"#, ["ENVSIGLEAK"])
        ]
        for (input, secrets) in cases {
            let out = SecretRedactor.redact(input)
            for secret in secrets {
                XCTAssertFalse(out.contains(secret), "nested secret '\(secret)' survived under credential key: \(out)")
            }
            XCTAssertTrue(out.contains("REDACTED_LEN_"), "expected length redaction: \(out)")
        }
    }

    func testNonStringScalarUnderCredentialKey_redactedToMarker() {
        // A bare numeric/bool/null scalar DIRECTLY under a credential key must become the non-scalar
        // marker. This is the fail-open that previously returned `{"token":1234567}` verbatim (the
        // non-String branch recursed into redactJSON, which falls through to `return value` for a
        // bare scalar). Direct shapes + an exact-marker assertion (no OR that masks a regression).
        let cases: [(String, String)] = [
            (#"{"token":1234567}"#, "1234567"),
            (#"{"password":true}"#, "true"),
            (#"{"sessionKey":987654321}"#, "987654321"),
            (#"{"__cf_bm":999}"#, "999"),
            // The realistic serialize() envelope: a numeric token nested in `payload`.
            (#"{"kind":"x","payload":{"sessionKey":1234567890123456},"ts":"t"}"#, "1234567890123456")
        ]
        for (input, raw) in cases {
            let out = SecretRedactor.redact(input)
            XCTAssertFalse(out.contains(raw), "scalar '\(raw)' survived under credential key: \(out)")
            XCTAssertTrue(out.contains("REDACTED_NONSCALAR"), "expected exact non-scalar marker: \(out)")
        }
    }

    func testNestedSecret_idempotent() {
        let inputs = [
            #"{"token":["sk-ant-LEAK"]}"#,
            #"{"signature":{"r":"SIGLEAK"}}"#,
            #"{"token":{"count":5}}"#,
            #"{"kind":"x","payload":{"token":["sk-ant-ENV"]},"ts":"t"}"#
        ]
        for input in inputs {
            let once = SecretRedactor.redact(input)
            let twice = SecretRedactor.redact(once)
            XCTAssertEqual(once, twice, "nested redaction not idempotent for \(input)\n once: \(once)\n twice: \(twice)")
        }
    }

    // MARK: - IDN / Unicode / quoted-local / underscore-domain emails

    func testIDNEmails_doNotSurvive() {
        let cases: [(String, String)] = [
            ("Account added and activated: jens@müller.de", "müller.de"),
            ("user giorgos@παράδειγμα.gr signed in", "παράδειγμα.gr"),
            ("li@例え.jp added", "例え.jp"),
            ("office@münchen.de", "münchen.de"),
            ("ivan@почта.рф", "почта.рф")
        ]
        for (input, domain) in cases {
            let out = SecretRedactor.redact(input)
            XCTAssertFalse(out.contains(domain), "IDN domain '\(domain)' survived: \(out)")
            XCTAssertTrue(out.contains("[EMAIL]"), "IDN email not redacted: \(out)")
        }
    }

    func testUnderscoreDomainEmail_doesNotLeakDomain() {
        let out = SecretRedactor.redact("u@inter_nal.example.com from billing")
        XCTAssertFalse(out.contains("inter_nal.example.com"), out)
        XCTAssertTrue(out.contains("[EMAIL]"), out)
    }

    func testQuotedLocalPartEmail_doesNotLeakDomain() {
        let out = SecretRedactor.redact(#"contact "weird name"@example.com today"#)
        XCTAssertFalse(out.contains("@example.com"), out)
        XCTAssertTrue(out.contains("[EMAIL]"), out)
    }

    // MARK: - Credential value char-class truncation (comma/semicolon/colon)

    func testCommaDelimitedCredentialValue_fullyRedacted() {
        let out = SecretRedactor.redact("token=abc,def,ghi rest")
        XCTAssertFalse(out.contains("abc,def,ghi"), out)
        XCTAssertFalse(out.contains("def,ghi"), "comma-tail of the secret survived: \(out)")
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
        XCTAssertTrue(out.contains("rest"), "following whitespace-delimited token should survive: \(out)")
    }

    func testSemicolonInNonCookieCredentialValue_fullyRedacted() {
        // `assertion` is not a cookieHeaderKey, so the old cookie-rescue did not help it.
        let out = SecretRedactor.redact("assertion=abc;def")
        XCTAssertFalse(out.contains("def"), "semicolon-tail survived for non-cookie key: \(out)")
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    func testColonDelimitedBearerToken_fullyRedacted() {
        let out = SecretRedactor.redact("Authorization: Bearer abc:def:ghi")
        XCTAssertFalse(out.contains("def:ghi"), "colon-tail of bearer token survived: \(out)")
        XCTAssertFalse(out.contains("abc:def:ghi"), out)
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    // MARK: - URL fragment generalization (not just sessionKey keyword)

    func testURLFragmentWithArbitraryToken_redacted() {
        let cases = [
            "see https://claude.ai/cb#access_token=sk-ant-FRAGSECRET&x=1 now",
            "https://claude.ai/cb#tokenval-OPAQUESECRET",
            "https://claude.ai/cb#id_token=eyJFRAGJWT"
        ]
        for input in cases {
            let out = SecretRedactor.redact(input)
            XCTAssertTrue(out.contains("#[REDACTED]"), "fragment not redacted: \(out)")
            for secret in ["sk-ant-FRAGSECRET", "OPAQUESECRET", "eyJFRAGJWT"] {
                XCTAssertFalse(out.contains(secret), "fragment secret survived: \(out)")
            }
        }
    }

    func testURLFragmentSessionKeyStillRedacted() {
        let out = SecretRedactor.redact("https://claude.ai/cb#sessionKey=sk-ant-SECRET&x=1")
        XCTAssertFalse(out.contains("sk-ant-SECRET"), out)
        XCTAssertTrue(out.contains("#[REDACTED]"), out)
    }

    // MARK: - Any-scheme URL + opaque data:/mailto: redaction (defense-in-depth)

    func testCustomSchemeURLQuery_redacted() {
        // A custom-scheme OAuth redirect carries `code=` just like http(s).
        let out = SecretRedactor.redact("redirect com.app.oauth://callback?code=SECRETCODE123&state=x")
        XCTAssertFalse(out.contains("SECRETCODE123"), "custom-scheme query secret survived: \(out)")
        XCTAssertTrue(out.contains("?[REDACTED]"), out)
    }

    func testCustomSchemeURLFragment_redacted() {
        let out = SecretRedactor.redact("msauth.com.x://auth#access_token=SECRETFRAG")
        XCTAssertFalse(out.contains("SECRETFRAG"), out)
        XCTAssertTrue(out.contains("#[REDACTED]"), out)
    }

    func testDataURI_redacted() {
        let out = SecretRedactor.redact("avatar data:image/png;base64,SECRETPAYLOADBLOB rest")
        XCTAssertFalse(out.contains("SECRETPAYLOADBLOB"), "data: URI payload survived: \(out)")
        XCTAssertTrue(out.contains("data:[REDACTED]"), out)
    }

    func testMailtoURI_redacted() {
        let out = SecretRedactor.redact("link mailto:victim@example.com?subject=hi")
        XCTAssertFalse(out.contains("victim@example.com"), "mailto address survived: \(out)")
        XCTAssertTrue(out.contains("mailto:[REDACTED]"), out)
    }

    // MARK: - Scheme-less / relative redirect params (no <scheme>://)

    func testSchemelessRedirectParamCode_redacted() {
        // A relative redirect has no `<scheme>://`, so the URL passes miss it; the redirect-param
        // pass must still redact the exchangeable authorization `code`.
        let out = SecretRedactor.redact("nav decision for /auth/cb?code=LIVEAUTHCODE123&next=/x")
        XCTAssertFalse(out.contains("LIVEAUTHCODE123"), "scheme-less redirect code survived: \(out)")
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    func testSchemelessRedirectTokensInFragment_redacted() {
        let out = SecretRedactor.redact("/cb#access_token=OPAQUEACCESSTOKEN&id_token=OPAQUEIDTOKEN")
        XCTAssertFalse(out.contains("OPAQUEACCESSTOKEN"), out)
        XCTAssertFalse(out.contains("OPAQUEIDTOKEN"), out)
    }

    // MARK: - cookieHeaderKeys redacted ONLY by the cookie pass (cf_clearance / lasturl / next-url)

    func testCfClearanceCookie_redactedKeepsHarmless() {
        // cf_clearance is a genuine Cloudflare clearance token and lives ONLY in cookieHeaderKeys
        // (not credentialKeys), so it is redacted exclusively by redactCookieHeader.
        let out = SecretRedactor.redact("cf_clearance=CLEARANCESECRETVALUE; theme=dark")
        XCTAssertFalse(out.contains("CLEARANCESECRETVALUE"), "cf_clearance value survived: \(out)")
        XCTAssertTrue(out.contains("theme=dark"), "harmless cookie should survive: \(out)")
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    func testLastUrlAndNextUrlCookies_redacted() {
        let out = SecretRedactor.redact("lasturl=OPAQUELASTURLSECRET; next-url=OPAQUENEXTURLSECRET; theme=dark")
        XCTAssertFalse(out.contains("OPAQUELASTURLSECRET"), "lasturl value survived: \(out)")
        XCTAssertFalse(out.contains("OPAQUENEXTURLSECRET"), "next-url value survived: \(out)")
        XCTAssertTrue(out.contains("theme=dark"), out)
    }

    // MARK: - Secret in a JSON KEY position under a credential key

    func testSecretAsJSONKeyUnderCredentialKey_redacted() {
        // A secret can ride in a key, not just a value. Inside a credential subtree the key is
        // SHA-redacted (REDACTED_KEY_<8hex>) so it cannot survive verbatim.
        let out = SecretRedactor.redact(#"{"token":{"sk-ant-KEYSECRET":true}}"#)
        XCTAssertFalse(out.contains("sk-ant-KEYSECRET"), "secret in key position survived: \(out)")
        XCTAssertTrue(out.contains("REDACTED_KEY_"), out)
    }

    // MARK: - isAlreadyRedacted both alternations (bare-^ and SHA-prefix)

    func testIdempotenceGuard_bareLenMarkerUnderCredentialKey() {
        // Re-redacting a value that is already `REDACTED_LEN_N` (non-rotation key) must be a no-op.
        XCTAssertEqual(SecretRedactor.redact(#"{"token":"REDACTED_LEN_25"}"#), #"{"token":"REDACTED_LEN_25"}"#)
    }

    func testIdempotenceGuard_shaPrefixMarkerUnderRotationKey() {
        let input = #"{"__cf_bm":"457f11ea...REDACTED_LEN_25"}"#
        XCTAssertEqual(SecretRedactor.redact(input), input)
    }

    func testIdempotenceGuard_bareLenInKeyValueProse() {
        XCTAssertEqual(SecretRedactor.redact("token=REDACTED_LEN_25"), "token=REDACTED_LEN_25")
    }

    /// BREAKER FIX: a value that merely ENDS in `…REDACTED_LEN_<n>` (an attacker-crafted prefix)
    /// must NOT be waved through by the idempotence guard — the `SECRET` prefix must be redacted.
    func testIsAlreadyRedacted_doesNotPassThroughCraftedPrefix() {
        let out = SecretRedactor.redact(#"{"token":"SECRET...REDACTED_LEN_5"}"#)
        XCTAssertFalse(out.contains("SECRET"), "crafted prefix survived the idempotence guard: \(out)")
        XCTAssertTrue(out.contains("REDACTED_LEN_"), out)
    }

    func testIsAlreadyRedacted_doesNotPassThroughLongPrefix() {
        // A non-8-hex prefix before `...REDACTED_LEN_` must be treated as a real (unredacted) value.
        let out = SecretRedactor.redact(#"{"token":"myprefix...REDACTED_LEN_99"}"#)
        XCTAssertFalse(out.contains("myprefix"), "crafted prefix survived: \(out)")
    }

    func testIsAlreadyRedacted_genuineMarkersStillIdempotent() {
        // The real bare and 8-hex-SHA marker forms must still pass through unchanged.
        XCTAssertEqual(SecretRedactor.redact(#"{"token":"REDACTED_LEN_25"}"#), #"{"token":"REDACTED_LEN_25"}"#)
        XCTAssertEqual(SecretRedactor.redact(#"{"__cf_bm":"457f11ea...REDACTED_LEN_25"}"#),
                       #"{"__cf_bm":"457f11ea...REDACTED_LEN_25"}"#)
    }

    // MARK: - ReDoS: pathological non-matching input completes quickly + is truncated

    func testLongNonMatchingInput_completesQuicklyAndTruncates() {
        // 40 KB with no `=`/`@` terminator — the pre-fix quadratic patterns took tens of seconds.
        let pathological = String(repeating: "ab", count: 20_000)
        let start = Date()
        let out = SecretRedactor.redact(pathological)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "redact took \(elapsed)s on a 40KB line — possible ReDoS regression")
        XCTAssertTrue(out.contains("…[TRUNCATED]"), "long input should be truncated: \(out.prefix(40))…")
    }

    func testLongInputStillRedactsLeadingSecret() {
        // A secret at the start, then a long pathological tail: secret still redacted, fast.
        let input = "sessionKey=sk-ant-HEADSECRET " + String(repeating: "x", count: 20_000)
        let start = Date()
        let out = SecretRedactor.redact(input)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertFalse(out.contains("sk-ant-HEADSECRET"), "leading secret survived under truncation: \(out.prefix(80))")
    }
}
