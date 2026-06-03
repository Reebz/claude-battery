import CryptoKit
import Foundation

/// Strips session keys, full cookie values, URL query strings, Authorization headers,
/// WebAuthn assertions, email addresses, and org UUIDs from diagnostic output.
/// Length is preserved as a signal (`REDACTED_LEN_<N>`) so a reader can still tell
/// whether a value rotated between requests.
///
/// Single entry point: `SecretRedactor.redact(_:)`. Internally:
/// 1. Try to parse as JSON; if it succeeds, walk the tree and rewrite recognized
///    credential keys.
/// 2. Otherwise apply regex passes: credential key=value pairs, `Authorization`
///    bearer/basic tokens, bare email addresses, cookie headers, URL query strings,
///    URL fragments, and UUID-shaped path segments.
///
/// This is the producer-side redaction guarantee for the diagnostic log (`DiagnosticsLogger`).
/// Every emitted line passes through here before it is written.
enum SecretRedactor {
    /// Case-insensitive credential keys whose string values get redacted to
    /// `REDACTED_LEN_<N>`. UUID-shaped path segments are handled by the regex pass.
    private static let credentialKeys: Set<String> = [
        "token", "sessionkey", "assertion", "signature", "password",
        "__cf_bm", "anthropic-csrf-token", "email", "email_address",
        "emailaddress", "csrftoken", "x-csrf-token", "_csrf",
        "authorization"
    ]

    /// Keys whose values keep an 8-character SHA-256 prefix so rotation across
    /// requests is observable without exposing the raw value.
    private static let rotationDetectableKeys: Set<String> = [
        "__cf_bm", "anthropic-csrf-token"
    ]

    static func redact(_ message: String) -> String {
        guard !message.isEmpty else { return message }

        if let data = message.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let redactedJson = redactJSON(json)
            // `.sortedKeys` makes the output deterministic (byte-identical for identical input),
            // which is what keeps redaction idempotent for object payloads — without it, a second
            // pass re-serializes the same dict with a different key order and the strings, though
            // equally redacted, would not compare equal.
            if let outData = try? JSONSerialization.data(withJSONObject: redactedJson, options: [.fragmentsAllowed, .sortedKeys]),
               let outString = String(data: outData, encoding: .utf8) {
                return outString
            }
        }

        return regexRedact(message)
    }

    // MARK: - JSON walker

    /// Marker substituted for a non-string value (array/object) found under a credential key.
    /// A structured value under a credential key has no legitimate non-secret use, so the whole
    /// subtree is replaced rather than walked — closing the nested-secret leak where a token
    /// array/object would otherwise reach `regexRedact`, which does not recognize opaque tokens.
    static let nonScalarRedactionMarker = "REDACTED_NONSCALAR"

    /// Walk the JSON tree. `forceRedact` is set once any credential-keyed ancestor is entered:
    /// from that point EVERY descendant string is length-redacted (not regex-redacted), so a
    /// secret nested in an array/object under a credential key (e.g. `{"token":["sk-ant-…"]}`)
    /// cannot slip through to `regexRedact` and survive verbatim.
    private static func redactJSON(_ value: Any, forceRedact: Bool = false) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, val) in dict {
                if forceRedact || credentialKeys.contains(key.lowercased()) {
                    // This key IS a credential, or we are already inside a credential subtree:
                    // force-redact the value. `forceRedactValue` covers strings (REDACTED_LEN_N),
                    // nested containers (recurse in force mode), AND bare non-string scalars
                    // (REDACTED_NONSCALAR) — the last closes the fail-open where a numeric/bool
                    // token DIRECTLY under a credential key (`{"token":1234567}`) returned verbatim
                    // because the old non-String branch recursed into `redactJSON`, which falls
                    // through to `return value` for a bare scalar.
                    //
                    // When already inside the subtree (`forceRedact`), the KEY is redacted too: a
                    // secret can ride in a key position (`{"token":{"<secret>":1}}`) and would
                    // otherwise survive verbatim. The credential key itself (first entry into the
                    // subtree, where `forceRedact == false`) is a fixed name, not a secret, so it
                    // is preserved for readability.
                    let outKey = forceRedact ? redactKey(key) : key
                    out[outKey] = forceRedactValue(forKey: key, value: val)
                } else {
                    out[key] = redactJSON(val, forceRedact: false)
                }
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { redactJSON($0, forceRedact: forceRedact) }
        }
        if let str = value as? String {
            return forceRedact ? redactValue(forKey: "", value: str) : regexRedact(str)
        }
        return value
    }

    /// Redact a single value while inside a credential subtree. Strings become `REDACTED_LEN_N`;
    /// nested containers keep recursing in force-redact mode; non-string scalars (Int/Bool/null)
    /// are replaced with the non-scalar marker (a number/bool under a credential key could itself
    /// be a secret, e.g. a numeric token).
    private static func forceRedactValue(forKey key: String, value: Any) -> Any {
        if value is [String: Any] || value is [Any] {
            return redactJSON(value, forceRedact: true)
        }
        if let str = value as? String {
            return redactValue(forKey: key, value: str)
        }
        return nonScalarRedactionMarker
    }

    /// Redact a dictionary KEY encountered inside a credential subtree (force mode) to a one-way
    /// 8-char SHA prefix, so a secret in a key position (`{"token":{"<secret>":1}}`) cannot survive
    /// verbatim. Idempotent: an already-redacted key passes through unchanged, so a second redact
    /// pass does not drift the prefix (and keeps object payloads byte-stable under `.sortedKeys`).
    private static func redactKey(_ key: String) -> String {
        if key.range(of: "^REDACTED_KEY_[0-9a-f]{8}$", options: .regularExpression) != nil { return key }
        return "REDACTED_KEY_\(sha256Prefix(key))"
    }

    /// Whether `value` is EXACTLY a redaction marker this redactor produces: either the bare
    /// `REDACTED_LEN_<n>` form, or the rotation form `<8 lowercase hex>...REDACTED_LEN_<n>`.
    /// Anchored at both ends so an attacker-supplied value that merely ENDS in
    /// `…REDACTED_LEN_<n>` (e.g. `myprefix...REDACTED_LEN_99`) does NOT slip through unredacted —
    /// the prefix must be exactly an 8-hex SHA chunk or absent. Used to keep redaction idempotent
    /// (a real marker re-redacted to itself would otherwise drift the count / SHA prefix).
    private static func isAlreadyRedacted(_ value: String) -> Bool {
        value.range(of: "^([0-9a-f]{8}\\.\\.\\.)?REDACTED_LEN_[0-9]+$", options: .regularExpression) != nil
    }

    private static func redactValue(forKey key: String, value: String) -> String {
        // Idempotence: a value that is already a redaction marker (LEN form or the non-scalar
        // marker) must pass through unchanged, or the count/SHA prefix would drift each pass.
        guard !isAlreadyRedacted(value), value != nonScalarRedactionMarker else { return value }
        let count = value.count
        if rotationDetectableKeys.contains(key.lowercased()) {
            return "\(sha256Prefix(value))...REDACTED_LEN_\(count)"
        }
        return "REDACTED_LEN_\(count)"
    }

    private static func sha256Prefix(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }

    // MARK: - Precompiled regexes
    //
    // Every regex is a `static let` built once with `try!`. The patterns are constant
    // (the credential-key alternation is derived from the static `credentialKeys` set),
    // so a force-unwrap is safe at load and cannot silently skip redaction the way the
    // former per-call `try?` compile did — a compile failure there left secrets unredacted.

    private static let uuidRegex = try! NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        options: []
    )

    /// Query string on ANY `<scheme>://…` URL (not just http/https): an OAuth redirect on a
    /// custom scheme (`com.app.oauth://cb?code=…`) carries the same `code=`/`token=` secrets, so
    /// the scheme is generalized to `[a-z][a-z0-9+.-]*` (RFC 3986 scheme grammar).
    private static let urlWithQueryRegex = try! NSRegularExpression(
        pattern: "([a-zA-Z][a-zA-Z0-9+.\\-]*://[^\\s?#]+)\\?[^\\s#]+",
        options: []
    )

    /// Whole fragment on ANY `<scheme>://…` URL. Generalized from a `sessionKey`-keyword-only
    /// http(s) match: implicit-flow / custom-scheme redirects carry access/id tokens in the
    /// fragment under arbitrary names (`access_token`, `id_token`, `code`).
    private static let urlFragmentRegex = try! NSRegularExpression(
        pattern: "([a-zA-Z][a-zA-Z0-9+.\\-]*://[^\\s#]+)#[^\\s]+",
        options: []
    )

    /// Opaque-body URIs that have no `//` authority: `data:` and `mailto:`. A `data:` URI can
    /// embed an arbitrary payload and a `mailto:` carries an email; redact everything after the
    /// scheme to a marker. Anchored on the scheme so ordinary prose containing the words is safe.
    private static let opaqueURIRegex = try! NSRegularExpression(
        pattern: "(?i)\\b(data|mailto):[^\\s]+",
        options: []
    )

    /// OAuth redirect parameters (`code`, `access_token`, `id_token`, `refresh_token`) in a query
    /// or fragment, redacted REGARDLESS of URL scheme — including a SCHEME-LESS relative redirect
    /// (`/cb?code=…`) that the `<scheme>://` passes above do not match. The authorization `code`
    /// is exchangeable for tokens, so it is redacted even though no current producer emits a
    /// redirect URL (defense-in-depth on the OAuth-redirect surface the app actively handles).
    /// `state` is intentionally excluded: it is a CSRF nonce, not an access credential, and the
    /// producer uses `state` as its own (non-secret) login-state diagnostic key.
    private static let redirectParamRegex = try! NSRegularExpression(
        pattern: "(?i)\\b(code|access_token|id_token|refresh_token)=([^\\s&#]+)",
        options: []
    )

    private static let cookiePairRegex = try! NSRegularExpression(
        pattern: "([A-Za-z0-9_\\-]+)=([^;\\s,]+)",
        options: []
    )

    /// Precompiled credential `key: value` / `key=value` matcher. Hoisted from a per-call
    /// `try?` (which silently skipped redaction on a compile failure — a real bypass) to a
    /// load-time `try!`. Group 1 = prefix (key + separator + optional opening quote),
    /// group 2 = key, group 3 = value.
    ///
    /// The value class is `[^"'\s\}\)]+` — it deliberately does NOT stop at `,` `;` `:` so an
    /// opaque secret containing those delimiters (e.g. `token=abc,def`, `assertion=a:b:c`) is
    /// captured whole rather than leaving a `,def`/`:b:c` remnant. Over-capturing a following
    /// `;theme=dark` (no space) is the safe direction for a P0 redactor; real cookie headers use
    /// `; ` with a space, which still terminates the value.
    ///
    /// It DOES stop at `}` and `)` (and quotes) to avoid eating surrounding JSON/paren structure
    /// on the regex (non-JSON) path. A secret containing a literal `}`/`)` would therefore leave a
    /// post-brace remnant on this path — a non-concern in practice: real session keys / `__cf_bm` /
    /// bearer tokens are cookie-octet/base64url and contain neither, and structured JSON payloads
    /// are redacted whole by the JSON walker, not here. The JSON walker is the primary control.
    private static let credentialKeyValueRegex: NSRegularExpression = {
        let keys = credentialKeys.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "(?i)([\"']?(\(keys))[\"']?\\s*[:=]\\s*[\"']?)([^\"'\\s\\}\\)]+)",
            options: []
        )
    }()

    /// `Authorization: Bearer <token>` / `Basic <creds>` (and bare `Bearer <token>`).
    /// The generic `credentialKeyValueRegex` value char-class stops at the space after the
    /// scheme word, so for `Authorization: Bearer abc` it would capture only `Bearer` and
    /// leave the token. This dedicated pass spans the space and redacts the token itself.
    /// Group 1 = everything up to and including the scheme word + space; group 2 = the token.
    /// The token class includes `:` so an opaque colon-delimited token (`Bearer a:b:c`) is
    /// captured whole instead of leaving a `:b:c` remnant.
    private static let bearerTokenRegex = try! NSRegularExpression(
        pattern: "(?i)((?:authorization\\s*[:=]\\s*)?(?:bearer|basic)\\s+)([A-Za-z0-9\\-._~+/=:]+)",
        options: []
    )

    /// Bare email addresses in free-text prose or as a JSON string value not under a
    /// credential key (e.g. `"Account added: user@example.com"`). Redacted to `[EMAIL]`.
    ///
    /// Unicode-aware: the local-part and domain classes use `\p{L}`/`\p{N}` so internationalized
    /// (IDN) addresses are caught too — `jens@müller.de`, `用户@例え.jp`, `ivan@почта.рф` — not just
    /// ASCII. A quoted local part (`"weird name"@example.com`, RFC 5321) is matched via the
    /// leading alternation, and `_` is permitted in domain labels (enterprise relay hosts).
    /// Classes/quantifiers are bounded to avoid quadratic backtracking (the local part is capped,
    /// the domain-label repetition is bounded, and a `\b` anchors the TLD) so a long non-email
    /// run does not stall the export.
    ///
    /// Scope: this pass requires a dotted TLD, so a dotless-host address (`user@localhost`) is NOT
    /// matched. That is acceptable because this is the defense-in-depth backstop, not the primary
    /// guarantee: the PRODUCER CONTRACT is that no email is ever emitted into a diagnostic payload
    /// (every address originates from the claude.ai org API as a real dotted-TLD email stored only
    /// in `Account.email`, never passed to `DiagnosticsLogger`). Broadening to dotless hosts is
    /// deliberately avoided — it would only ever over-redact non-email `@`-bearing tokens, since no
    /// data source produces a dotless address.
    private static let emailRegex = try! NSRegularExpression(
        pattern: "(?:\"[^\"]{0,128}\"|[\\p{L}\\p{N}._%+\\-]{1,128})@[\\p{L}\\p{N}_\\-]{1,128}(?:\\.[\\p{L}\\p{N}_\\-]{1,128}){0,16}\\.[\\p{L}]{2,24}\\b",
        options: []
    )

    /// Cookie-header keys whose values are redacted by `redactCookieHeader`. Three of these
    /// (`__cf_bm`, `anthropic-csrf-token`, `sessionkey`) are ALSO in `credentialKeys` and already
    /// redacted by the earlier `redactCredentialPairs` pass; the overlap is intentional, not dead.
    /// The cookie pass uses a broader value class (`[^;\s,]+` vs the credential pass's
    /// `[^"'\s}\)]+`), so it is the backstop that catches a delimiter-bearing remnant (a value
    /// containing `}`/`)`) the narrower credential class would leave. The other three
    /// (`cf_clearance`, `lasturl`, `next-url`) live ONLY here and are redacted ONLY by this pass —
    /// they have dedicated regression tests so a future edit dropping one fails CI.
    private static let cookieHeaderKeys: Set<String> = [
        "__cf_bm", "anthropic-csrf-token", "sessionkey",
        "cf_clearance", "lasturl", "next-url"
    ]

    // MARK: - Regex pass

    /// Per-call input cap. Several passes (`emailRegex`, `cookiePairRegex`) are O(n^2) on long
    /// non-matching input. A single large pathological line would stall redaction; lines this
    /// long carry no diagnostic value, so we hard-truncate before the regex passes. The marker
    /// makes the truncation auditable. The cheap pre-filters below (skip a pass when its trigger
    /// char is absent) keep even the capped worst case near-linear.
    static let maxRedactInputLength = 4_096

    private static func regexRedact(_ input: String) -> String {
        var result = input
        if result.utf16.count > maxRedactInputLength {
            let endIndex = result.index(result.startIndex, offsetBy: maxRedactInputLength, limitedBy: result.endIndex) ?? result.endIndex
            result = String(result[result.startIndex..<endIndex]) + "…[TRUNCATED]"
        }

        // Cheap pre-filters: a credential `key=value`/`key:value`, a cookie pair, and a bearer
        // token all require a `=` or `:`; an email requires `@`. Skipping the corresponding
        // (quadratic) regex when its trigger char is absent makes a long non-matching line (the
        // ReDoS case) near-linear instead of O(n^2). The `:`/`=` set covers all three structured
        // passes; bearer also needs a scheme word but `:`/`=`/space precede it in practice.
        let hasKVDelim = result.contains("=") || result.contains(":")
        let hasAt = result.contains("@")

        // 1. Authorization bearer/basic tokens FIRST. The token char-class includes `=` and
        //    other base64url chars, so running this before the generic credential pass avoids
        //    the generic pass clipping the token at the scheme-word space and leaving a remnant.
        if hasKVDelim || result.range(of: "(?i)(bearer|basic)\\s", options: .regularExpression) != nil {
            result = redactBearerTokens(result)
        }

        // 2. Generic credential key=value / key: value pairs (sessionKey, password, token, …).
        if hasKVDelim {
            result = redactCredentialPairs(result)
            // 3. Cookie headers (mixed secret + harmless pairs) — also key=value shaped.
            result = redactCookieHeader(result)
        }

        // 4. URLs (query strings + fragments on any <scheme>://, plus opaque data:/mailto: URIs)
        //    — run when a `://` authority OR a `data:`/`mailto:` scheme could be present. The
        //    `:` covers `data:`/`mailto:`; gate on it (and `//`) so non-URL prose is skipped.
        if result.contains("://") || hasKVDelim {
            result = redactURLs(result)
        }

        // 5. UUID path segments — only when a hyphen could form a UUID.
        if result.contains("-") {
            result = redactUUIDPaths(result)
        }

        // 6. Bare emails LAST so already-redacted values (REDACTED_LEN_, [ORG-UUID], 8-char
        //    SHA prefixes) cannot contain an `@` that this would rewrite — and so an email
        //    surviving every structured pass is still caught (defense in depth).
        if hasAt {
            result = redactEmails(result)
        }

        return result
    }

    private static func redactCredentialPairs(_ input: String) -> String {
        let nsString = input as NSString
        let matches = credentialKeyValueRegex.matches(in: input, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return input }
        var replaced = input
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4 else { continue }
            let prefixRange = match.range(at: 1)
            let keyRange = match.range(at: 2)
            let valueRange = match.range(at: 3)
            let prefix = (replaced as NSString).substring(with: prefixRange)
            let key = (replaced as NSString).substring(with: keyRange)
            let value = (replaced as NSString).substring(with: valueRange)
            let redactedValue = redactValue(forKey: key, value: value)
            let replacement = prefix + redactedValue
            replaced = (replaced as NSString).replacingCharacters(
                in: NSRange(location: prefixRange.location, length: prefixRange.length + valueRange.length),
                with: replacement
            )
        }
        return replaced
    }

    private static func redactBearerTokens(_ input: String) -> String {
        let nsString = input as NSString
        let matches = bearerTokenRegex.matches(in: input, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return input }
        var replaced = input
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let prefixRange = match.range(at: 1)
            let tokenRange = match.range(at: 2)
            let prefix = (replaced as NSString).substring(with: prefixRange)
            let token = (replaced as NSString).substring(with: tokenRange)
            let replacement = prefix + "REDACTED_LEN_\(token.count)"
            replaced = (replaced as NSString).replacingCharacters(
                in: NSRange(location: prefixRange.location, length: prefixRange.length + tokenRange.length),
                with: replacement
            )
        }
        return replaced
    }

    private static func redactEmails(_ input: String) -> String {
        let nsString = input as NSString
        let matches = emailRegex.matches(in: input, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return input }
        var replaced = input
        for match in matches.reversed() {
            replaced = (replaced as NSString).replacingCharacters(in: match.range, with: "[EMAIL]")
        }
        return replaced
    }

    private static func redactCookieHeader(_ input: String) -> String {
        let nsString = input as NSString
        let matches = cookiePairRegex.matches(in: input, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return input }

        var redacted = input
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let keyRange = match.range(at: 1)
            let valueRange = match.range(at: 2)
            let key = (redacted as NSString).substring(with: keyRange)
            let value = (redacted as NSString).substring(with: valueRange)
            if cookieHeaderKeys.contains(key.lowercased()) {
                let redactedValue = redactValue(forKey: key, value: value)
                redacted = (redacted as NSString).replacingCharacters(in: valueRange, with: redactedValue)
            }
        }
        return redacted
    }

    private static func redactURLs(_ input: String) -> String {
        var result = input

        // Whole-fragment redaction for any <scheme>:// URL (access_token/id_token/code/etc.).
        let fragNS = result as NSString
        let fragMatches = urlFragmentRegex.matches(in: result, range: NSRange(location: 0, length: fragNS.length))
        for match in fragMatches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let urlOnly = (result as NSString).substring(with: match.range(at: 1))
            result = (result as NSString).replacingCharacters(in: match.range, with: urlOnly + "#[REDACTED]")
        }

        let queryNS = result as NSString
        let queryMatches = urlWithQueryRegex.matches(in: result, range: NSRange(location: 0, length: queryNS.length))
        for match in queryMatches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let urlOnly = (result as NSString).substring(with: match.range(at: 1))
            result = (result as NSString).replacingCharacters(in: match.range, with: urlOnly + "?[REDACTED]")
        }

        // Opaque-body URIs (data:, mailto:) — redact the whole body after the scheme.
        let opaqueNS = result as NSString
        let opaqueMatches = opaqueURIRegex.matches(in: result, range: NSRange(location: 0, length: opaqueNS.length))
        for match in opaqueMatches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let scheme = (result as NSString).substring(with: match.range(at: 1))
            result = (result as NSString).replacingCharacters(in: match.range, with: scheme + ":[REDACTED]")
        }

        // Scheme-less / relative redirect params: the `<scheme>://` passes above redact the whole
        // query/fragment of an absolute URL, but a relative redirect (`/cb?code=…`) has no scheme
        // and would otherwise slip through. Redact just the param value, length-preserving and
        // idempotent (an already-redacted value is left alone so the count does not drift).
        let redirectNS = result as NSString
        let redirectMatches = redirectParamRegex.matches(in: result, range: NSRange(location: 0, length: redirectNS.length))
        for match in redirectMatches.reversed() {
            guard match.numberOfRanges >= 3 else { continue }
            let valueRange = match.range(at: 2)
            let value = (result as NSString).substring(with: valueRange)
            guard !isAlreadyRedacted(value) else { continue }
            result = (result as NSString).replacingCharacters(in: valueRange, with: "REDACTED_LEN_\(value.count)")
        }

        return result
    }

    private static func redactUUIDPaths(_ input: String) -> String {
        let nsString = input as NSString
        let matches = uuidRegex.matches(in: input, range: NSRange(location: 0, length: nsString.length))
        var result = input
        for match in matches.reversed() {
            result = (result as NSString).replacingCharacters(in: match.range, with: "[ORG-UUID]")
        }
        return result
    }
}
