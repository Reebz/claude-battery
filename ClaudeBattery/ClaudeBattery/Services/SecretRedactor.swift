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
/// This is the producer-side redaction guarantee for the diagnostic log (`DiagnosticsLogger`,
/// `OSLogStoreDumper`). Every emitted line passes through here before it is written.
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
            if let outData = try? JSONSerialization.data(withJSONObject: redactedJson, options: [.fragmentsAllowed]),
               let outString = String(data: outData, encoding: .utf8) {
                return outString
            }
        }

        return regexRedact(message)
    }

    // MARK: - JSON walker

    private static func redactJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, val) in dict {
                if credentialKeys.contains(key.lowercased()), let s = val as? String {
                    out[key] = redactValue(forKey: key, value: s)
                } else {
                    out[key] = redactJSON(val)
                }
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { redactJSON($0) }
        }
        if let str = value as? String {
            return regexRedact(str)
        }
        return value
    }

    /// Marker an already-redacted value carries, e.g. `REDACTED_LEN_25` or
    /// `457f11ea...REDACTED_LEN_25`. Used to make redaction idempotent: a second pass over a
    /// value that is already a marker must return it unchanged, otherwise the `__cf_bm` SHA
    /// prefix and the `REDACTED_LEN_N` count would both drift each pass.
    private static func isAlreadyRedacted(_ value: String) -> Bool {
        value.range(of: "(^|\\.\\.\\.)REDACTED_LEN_[0-9]+$", options: .regularExpression) != nil
    }

    private static func redactValue(forKey key: String, value: String) -> String {
        guard !isAlreadyRedacted(value) else { return value }
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

    private static let urlWithQueryRegex = try! NSRegularExpression(
        pattern: "(https?://[^\\s?#]+)\\?[^\\s#]+",
        options: []
    )

    private static let urlSessionKeyFragmentRegex = try! NSRegularExpression(
        pattern: "(https?://[^\\s#]+)#[^\\s]*(sessionKey|session_key)[^\\s]*",
        options: [.caseInsensitive]
    )

    private static let cookiePairRegex = try! NSRegularExpression(
        pattern: "([A-Za-z0-9_\\-]+)=([^;\\s,]+)",
        options: []
    )

    /// Precompiled credential `key: value` / `key=value` matcher. Hoisted from a per-call
    /// `try?` (which silently skipped redaction on a compile failure — a real bypass) to a
    /// load-time `try!`. Group 1 = prefix (key + separator + optional opening quote),
    /// group 2 = key, group 3 = value.
    private static let credentialKeyValueRegex: NSRegularExpression = {
        let keys = credentialKeys.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "(?i)([\"']?(\(keys))[\"']?\\s*[:=]\\s*[\"']?)([^\"',;\\s\\}\\)]+)",
            options: []
        )
    }()

    /// `Authorization: Bearer <token>` / `Basic <creds>` (and bare `Bearer <token>`).
    /// The generic `credentialKeyValueRegex` value char-class stops at the space after the
    /// scheme word, so for `Authorization: Bearer abc` it would capture only `Bearer` and
    /// leave the token. This dedicated pass spans the space and redacts the token itself.
    /// Group 1 = everything up to and including the scheme word + space; group 2 = the token.
    private static let bearerTokenRegex = try! NSRegularExpression(
        pattern: "(?i)((?:authorization\\s*[:=]\\s*)?(?:bearer|basic)\\s+)([A-Za-z0-9\\-._~+/=]+)",
        options: []
    )

    /// Bare email addresses in free-text prose or as a JSON string value not under a
    /// credential key (e.g. `"Account added: user@example.com"`). Redacted to `[EMAIL]`.
    /// Local part and domain labels allow the RFC-permitted subset that actually appears
    /// in claude.ai data; the TLD requires at least two letters so it does not swallow a
    /// trailing word boundary.
    private static let emailRegex = try! NSRegularExpression(
        pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}",
        options: []
    )

    private static let cookieHeaderKeys: Set<String> = [
        "__cf_bm", "anthropic-csrf-token", "sessionkey",
        "cf_clearance", "lasturl", "next-url"
    ]

    // MARK: - Regex pass

    private static func regexRedact(_ input: String) -> String {
        var result = input

        // 1. Authorization bearer/basic tokens FIRST. The token char-class includes `=` and
        //    other base64url chars, so running this before the generic credential pass avoids
        //    the generic pass clipping the token at the scheme-word space and leaving a remnant.
        result = redactBearerTokens(result)

        // 2. Generic credential key=value / key: value pairs (sessionKey, password, token, …).
        result = redactCredentialPairs(result)

        // 3. Cookie headers (mixed secret + harmless pairs).
        result = redactCookieHeader(result)

        // 4. URLs (query strings + sessionKey fragments).
        result = redactURLs(result)

        // 5. UUID path segments.
        result = redactUUIDPaths(result)

        // 6. Bare emails LAST so already-redacted values (REDACTED_LEN_, [ORG-UUID], 8-char
        //    SHA prefixes) cannot contain an `@` that this would rewrite — and so an email
        //    surviving every structured pass is still caught (defense in depth).
        result = redactEmails(result)

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

        var fragmentRanges: [NSRange] = []
        urlSessionKeyFragmentRegex.enumerateMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length)) { m, _, _ in
            if let r = m?.range(at: 1) { fragmentRanges.append(NSRange(location: r.location, length: ((result as NSString).length - r.location))) }
        }
        for range in fragmentRanges.reversed() {
            let prefix = (result as NSString).substring(with: NSRange(location: range.location, length: 0))
            let urlMatch = urlSessionKeyFragmentRegex.firstMatch(in: result, range: range)
            if let urlMatch, urlMatch.numberOfRanges >= 2 {
                let urlOnly = (result as NSString).substring(with: urlMatch.range(at: 1))
                result = (result as NSString).replacingCharacters(in: urlMatch.range, with: prefix + urlOnly + "#REDACTED")
            }
        }

        let queryNS = result as NSString
        let queryMatches = urlWithQueryRegex.matches(in: result, range: NSRange(location: 0, length: queryNS.length))
        for match in queryMatches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let urlOnly = (result as NSString).substring(with: match.range(at: 1))
            result = (result as NSString).replacingCharacters(in: match.range, with: urlOnly + "?[REDACTED]")
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
