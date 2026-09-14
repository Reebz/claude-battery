using System.IO;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ClaudeBatteryWin.Services;

/// <summary>
/// The single chokepoint every diagnostic line passes through before it reaches a file, the console,
/// or an exported archive. Ported rule for rule from the Mac <c>SecretRedactor</c> (U2, KTD4), with
/// one rule the Mac never needed: a Windows user-profile path discloses the account name and .NET
/// puts one in almost every exception message, so those are replaced first.
///
/// Two branches. A line that parses as JSON is walked as a tree, so a secret under a credential key
/// is replaced whether it sits in a value, an array element, a nested object, or a key. Anything else
/// goes through the ordered regex pipeline in <see cref="RegexRedact"/>. Both converge on the same
/// guarantee: no session key, cookie value, bearer token, password, email address, organization UUID,
/// or Anthropic token survives.
///
/// Redaction is one-way and idempotent. A value becomes "REDACTED_LEN_&lt;n&gt;" (the length is kept
/// because a length change is the signal that a credential rotated); a value under a rotation key
/// keeps an 8-character SHA-256 prefix so two readings can be compared without revealing either.
/// Re-redacting an already-redacted line is a byte-for-byte no-op.
/// </summary>
public static class SecretRedactor
{
    /// <summary>Keys whose value is always a secret. Matched case-insensitively, by equality OR by
    /// substring, so "my_token" and "refresh_token" match through "token".</summary>
    private static readonly string[] CredentialKeys =
    {
        "token", "sessionkey", "assertion", "signature", "password", "__cf_bm",
        "anthropic-csrf-token", "email", "email_address", "emailaddress", "csrftoken",
        "x-csrf-token", "_csrf", "authorization", "cf_clearance", "lasturl", "next-url", "value"
    };

    /// <summary>The subset whose values rotate: these keep an 8-hex one-way prefix so a reader can
    /// tell "the same cookie" from "a new cookie" without seeing either.</summary>
    private static readonly HashSet<string> RotationDetectableKeys =
        new(new[] { "__cf_bm", "anthropic-csrf-token" }, StringComparer.Ordinal);

    /// <summary>Used only by the cookie-header pass, which has a wider value class than the
    /// keyword-anchored credential pass and so must act on a narrower key set.</summary>
    private static readonly HashSet<string> CookieHeaderKeys =
        new(new[] { "__cf_bm", "anthropic-csrf-token", "sessionkey", "cf_clearance", "lasturl", "next-url" },
            StringComparer.Ordinal);

    private const string NonScalarRedactionMarker = "REDACTED_NONSCALAR";
    private const int MaxRedactInputLength = 4096;
    private const char FullwidthColon = '：';
    private const char FullwidthEquals = '＝';

    // --- Precompiled patterns. Compiled once: a per-call compile that failed would silently skip a
    // whole redaction pass, which is the worst failure mode this class has. ---

    private static readonly Regex AlreadyRedactedRegex =
        new(@"^([0-9a-f]{8}\.\.\.)?REDACTED_LEN_[0-9]+$", RegexOptions.Compiled);

    private static readonly Regex RedactedKeyRegex =
        new(@"^REDACTED_KEY_[0-9a-f]{8}$", RegexOptions.Compiled);

    private static readonly Regex UuidRegex =
        new(@"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", RegexOptions.Compiled);

    private static readonly Regex UrlWithQueryRegex =
        new(@"([a-zA-Z][a-zA-Z0-9+.\-]*://[^\s?#]+)\?[^\s#]+", RegexOptions.Compiled);

    private static readonly Regex UrlFragmentRegex =
        new(@"([a-zA-Z][a-zA-Z0-9+.\-]*://[^\s#]+)#[^\s]+", RegexOptions.Compiled);

    private static readonly Regex OpaqueUriRegex =
        new(@"(?i)\b(data|mailto):[^\s]+", RegexOptions.Compiled);

    private static readonly Regex RedirectParamRegex =
        new(@"(?i)([?&#])(code|access_token|id_token|refresh_token)=([^\s&#]+)", RegexOptions.Compiled);

    private static readonly Regex CookiePairRegex =
        new(@"([A-Za-z0-9_\-]+)=([^;\s,]+)", RegexOptions.Compiled);

    private static readonly Regex CredentialKeyValueRegex = BuildCredentialKeyValueRegex();

    private static readonly Regex BearerTokenRegex =
        new(@"(?i)(\b(?:bearer|basic)\s+[""']?)(\S+)", RegexOptions.Compiled);

    private static readonly Regex AuthorizationValueRegex =
        new(@"(?i)(authorization\s*[:=：＝]\s*)([^\s\n][^\n]*)", RegexOptions.Compiled);

    private static readonly Regex BareSchemeWordRegex =
        new(@"(?i)\b(bearer|basic)\s", RegexOptions.Compiled);

    private static readonly Regex EmailRegex = new(
        @"(?:""[^""]{0,128}""|[\p{L}\p{N}\p{M}._%+\-]{1,128})@[\p{L}\p{N}\p{M}_\-]{1,128}"
        + @"(?:\.[\p{L}\p{N}\p{M}_\-]{1,128}){0,16}\.[\p{L}\p{M}]{2,24}(?![\p{L}\p{M}])",
        RegexOptions.Compiled);

    private static readonly Regex ApiTokenRegex =
        new(@"sk-ant-[A-Za-z0-9_\-]{1,512}", RegexOptions.Compiled);

    /// <summary>The Windows rule the Mac has no equivalent for: the user's profile directory. .NET
    /// puts the full path in most file-system exception messages, and a bare path carries no "=",
    /// "@", or URL scheme, so nothing else in this class would catch it.</summary>
    private static readonly Regex UserProfilePathRegex =
        new(@"(?i)([A-Za-z]:\\Users\\)([^\\/:*?""<>|\r\n]+)", RegexOptions.Compiled);

    /// <summary>The literal signed-in Windows account name, as a path segment. A profile redirected
    /// off the default location (roaming profiles, a mapped home drive) never matches the shape
    /// above, so the name itself is matched too - but only between separators, so an ordinary word
    /// that happens to be the account name is left alone in prose.</summary>
    private static readonly Regex? CurrentUserSegmentRegex = BuildCurrentUserSegmentRegex();

    private const string UserSegmentReplacement = "[USER]";

    // --- Public surface ---------------------------------------------------------------------

    /// <summary>
    /// Redact one message. A JSON line is walked as a tree and re-serialized with keys in ordinal
    /// order (so re-redacting produces identical bytes); anything else goes through the regex
    /// pipeline. Every producer in the app funnels through this one method.
    /// </summary>
    public static string Redact(string message)
    {
        if (string.IsNullOrEmpty(message))
        {
            return message;
        }

        if (TryRedactJson(message, out var redactedJson))
        {
            return redactedJson;
        }

        return RegexRedact(message);
    }

    /// <summary>
    /// A one-way 8-character tag for a value. Producers use it directly to label which locally
    /// configured account a reading came from without putting the account id in the file.
    /// </summary>
    public static string Sha256Prefix(string value)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(hash).ToLowerInvariant()[..8];
    }

    // --- Windows user-path pass ----------------------------------------------------------------

    /// <summary>Replaces the profile-path shape and the literal current account name, before every
    /// other pass so a later pass cannot split a path and leave half the name behind.</summary>
    internal static string RedactUserPaths(string input)
    {
        var result = UserProfilePathRegex.Replace(input, m => m.Groups[1].Value + UserSegmentReplacement);
        if (CurrentUserSegmentRegex is not null)
        {
            result = CurrentUserSegmentRegex.Replace(result, m => m.Groups[1].Value + UserSegmentReplacement + m.Groups[2].Value);
        }
        return result;
    }

    private static Regex? BuildCurrentUserSegmentRegex()
    {
        string name;
        try
        {
            name = Environment.UserName;
        }
        catch (Exception)
        {
            return null;
        }

        // A one- or two-character account name would match far too much ordinary text.
        if (string.IsNullOrWhiteSpace(name) || name.Length < 3)
        {
            return null;
        }

        return new Regex(
            @"(?i)([\\/])" + Regex.Escape(name) + @"([\\/]|$)",
            RegexOptions.Compiled);
    }

    // --- JSON branch ---------------------------------------------------------------------------

    private static bool TryRedactJson(string message, out string redacted)
    {
        redacted = string.Empty;
        JsonNode? node;
        try
        {
            // The Mac parses with fragmentsAllowed, so a bare string or number counts as JSON too.
            node = JsonNode.Parse(
                message,
                nodeOptions: null,
                documentOptions: new JsonDocumentOptions { AllowTrailingCommas = false });
        }
        catch (JsonException)
        {
            return false;
        }

        if (node is null)
        {
            return false;
        }

        try
        {
            var walked = RedactJsonNode(node, forceRedact: false);
            redacted = SerializeSorted(walked);
            return true;
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or NotSupportedException)
        {
            return false;
        }
    }

    /// <summary>
    /// Writes the tree back out with every object's keys in ordinal order. Sorting is what makes
    /// re-redacting an already-redacted line byte-identical; System.Text.Json does not sort.
    /// </summary>
    private static string SerializeSorted(JsonNode? node)
    {
        var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer, new JsonWriterOptions { SkipValidation = false }))
        {
            WriteSorted(writer, node);
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    private static void WriteSorted(Utf8JsonWriter writer, JsonNode? node)
    {
        switch (node)
        {
            case null:
                writer.WriteNullValue();
                break;
            case JsonObject obj:
                writer.WriteStartObject();
                foreach (var pair in obj.ToArray().OrderBy(p => p.Key, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(pair.Key);
                    WriteSorted(writer, pair.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonArray array:
                writer.WriteStartArray();
                foreach (var element in array)
                {
                    WriteSorted(writer, element);
                }
                writer.WriteEndArray();
                break;
            default:
                node.WriteTo(writer);
                break;
        }
    }

    /// <summary>
    /// The tree walk. <paramref name="forceRedact"/> is true once the walk has entered a credential
    /// key's subtree: everything below it is a secret, including strings that sit in key position.
    /// </summary>
    private static JsonNode? RedactJsonNode(JsonNode? node, bool forceRedact)
    {
        switch (node)
        {
            case JsonObject obj:
            {
                var result = new JsonObject();
                foreach (var pair in obj.ToArray())
                {
                    var key = pair.Key;
                    var value = pair.Value?.DeepClone();

                    if (forceRedact || IsCredentialKey(key))
                    {
                        // Inside an already-entered credential subtree a key can itself be a secret.
                        // At the boundary the key name ("token") is not a secret and stays readable.
                        var outputKey = forceRedact ? RedactKey(key) : key;
                        result[outputKey] = ForceRedactValue(key, value);
                    }
                    else
                    {
                        result[key] = RedactJsonNode(value, forceRedact: false);
                    }
                }
                return result;
            }
            case JsonArray array:
            {
                var result = new JsonArray();
                foreach (var element in array.ToArray())
                {
                    var clone = element?.DeepClone();
                    result.Add(forceRedact
                        ? ForceRedactValue(string.Empty, clone)
                        : RedactJsonNode(clone, forceRedact: false));
                }
                return result;
            }
            case JsonValue value when TryGetString(value, out var text):
                // A plain string outside any credential key still gets emails, URLs and UUIDs scrubbed.
                return JsonValue.Create(forceRedact ? RedactValue(string.Empty, text) : RegexRedact(text));
            default:
                return node?.DeepClone();
        }
    }

    /// <summary>A leaf inside a credential subtree: objects and arrays recurse, strings shrink to a
    /// length marker, and every other scalar becomes a fixed marker (its value is a secret and its
    /// type tells a reader nothing worth keeping).</summary>
    private static JsonNode? ForceRedactValue(string key, JsonNode? value)
    {
        switch (value)
        {
            case JsonObject or JsonArray:
                return RedactJsonNode(value, forceRedact: true);
            case JsonValue jsonValue when TryGetString(jsonValue, out var text):
                return JsonValue.Create(RedactValue(key, text));
            case null:
                return JsonValue.Create(NonScalarRedactionMarker);
            default:
                return JsonValue.Create(NonScalarRedactionMarker);
        }
    }

    private static bool TryGetString(JsonValue value, out string text)
    {
        if (value.TryGetValue<string>(out var s))
        {
            text = s;
            return true;
        }
        text = string.Empty;
        return false;
    }

    // --- Leaf rules ----------------------------------------------------------------------------

    /// <summary>Replaces one secret value. Idempotent: a value that is already a marker is returned
    /// untouched, so re-redacting a line changes nothing.</summary>
    internal static string RedactValue(string key, string value)
    {
        if (IsAlreadyRedacted(value) || value == NonScalarRedactionMarker)
        {
            return value;
        }

        var count = TextElementCount(value);
        var normalized = key.ToLowerInvariant();
        return RotationDetectableKeys.Contains(normalized)
            ? $"{Sha256Prefix(value)}...REDACTED_LEN_{count}"
            : $"REDACTED_LEN_{count}";
    }

    internal static string RedactKey(string key) =>
        RedactedKeyRegex.IsMatch(key) ? key : "REDACTED_KEY_" + Sha256Prefix(key);

    /// <summary>
    /// True only when the WHOLE string is a marker. Anchored at both ends deliberately: a crafted
    /// value ending in "...REDACTED_LEN_5" is a real secret with a decoy tail and must still be
    /// redacted.
    /// </summary>
    internal static bool IsAlreadyRedacted(string value) => AlreadyRedactedRegex.IsMatch(value);

    /// <summary>Counts what a reader would call characters, matching the Mac's grapheme-cluster
    /// count, so the same secret reports the same length on both platforms.</summary>
    private static int TextElementCount(string value) => new StringInfo(value).LengthInTextElements;

    // --- Key handling --------------------------------------------------------------------------

    /// <summary>Strips invisible formatting characters, trims, lowercases. A zero-width space
    /// spliced into "sessionKey" is a real way to smuggle a secret past a naive key check.</summary>
    internal static string NormalizedKey(string key)
    {
        var builder = new StringBuilder(key.Length);
        foreach (var rune in key.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) != UnicodeCategory.Format)
            {
                builder.Append(rune.ToString());
            }
        }
        return builder.ToString().Trim().ToLowerInvariant();
    }

    internal static bool IsCredentialKey(string key)
    {
        var normalized = NormalizedKey(key);
        foreach (var candidate in CredentialKeys)
        {
            if (normalized == candidate || normalized.Contains(candidate, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
    }

    private static Regex BuildCredentialKeyValueRegex()
    {
        var keys = string.Join("|", CredentialKeys.Select(Regex.Escape));
        // The value class stops only at a quote or whitespace, never at "}" ")" "," or ";", so an
        // opaque secret containing punctuation is captured whole instead of leaving a tail behind.
        return new Regex(
            @"(?i)([""']?(" + keys + @")[""']?\s*[:=：＝]\s*[""']?)([^""'\s]+)",
            RegexOptions.Compiled);
    }

    // --- Regex branch --------------------------------------------------------------------------

    /// <summary>
    /// The non-JSON pipeline. Pass order is part of the contract: the Authorization pass has to run
    /// before the bearer pass, which has to run before the generic credential pass, or a token gets
    /// cut in half and the tail survives. Emails run late so a marker's own text is never rewritten,
    /// and the Anthropic-token catch-all runs last.
    /// </summary>
    internal static string RegexRedact(string input)
    {
        // The Windows path rule runs before everything else: a later pass that splits on "\\" would
        // leave half an account name behind.
        var result = RedactUserPaths(StripFormatScalars(input));

        if (result.Length > MaxRedactInputLength)
        {
            result = result[..MaxRedactInputLength] + "…[TRUNCATED]";
        }

        // Two cheap probes keep a long line that matches nothing close to linear.
        var hasKVDelim = result.Contains('=') || result.Contains(':')
            || result.Contains(FullwidthColon) || result.Contains(FullwidthEquals);
        var hasAt = result.Contains('@');

        if (hasKVDelim)
        {
            result = RedactAuthorizationValues(result);
        }
        if (hasKVDelim || BareSchemeWordRegex.IsMatch(result))
        {
            result = RedactBearerTokens(result);
        }
        if (hasKVDelim)
        {
            result = RedactCredentialPairs(result);
            result = RedactCookieHeader(result);
        }
        if (result.Contains("://", StringComparison.Ordinal) || hasKVDelim)
        {
            result = RedactUrls(result);
        }
        if (result.Contains('-'))
        {
            result = UuidRegex.Replace(result, "[ORG-UUID]");
        }
        if (hasAt)
        {
            result = EmailRegex.Replace(result, "[EMAIL]");
        }
        if (result.Contains("sk-ant-", StringComparison.Ordinal))
        {
            result = ApiTokenRegex.Replace(result, m => $"REDACTED_LEN_{TextElementCount(m.Value)}");
        }

        return result;
    }

    private static string StripFormatScalars(string input)
    {
        var needsStrip = false;
        foreach (var rune in input.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) == UnicodeCategory.Format)
            {
                needsStrip = true;
                break;
            }
        }
        if (!needsStrip)
        {
            return input;
        }

        var builder = new StringBuilder(input.Length);
        foreach (var rune in input.EnumerateRunes())
        {
            if (Rune.GetUnicodeCategory(rune) != UnicodeCategory.Format)
            {
                builder.Append(rune.ToString());
            }
        }
        return builder.ToString();
    }

    /// <summary>Any "authorization" key takes the whole rest of the line, whatever the scheme.
    /// Running first is what stops the narrower passes from orphaning half a token.</summary>
    private static string RedactAuthorizationValues(string input) =>
        AuthorizationValueRegex.Replace(input, m =>
        {
            var value = m.Groups[2].Value;
            return IsAlreadyRedacted(value)
                ? m.Value
                : m.Groups[1].Value + $"REDACTED_LEN_{TextElementCount(value)}";
        });

    /// <summary>A bare "Bearer &lt;token&gt;" with no Authorization key in front of it, as it appears
    /// inside a JSON string or in prose. The scheme word stays; only the token goes.</summary>
    private static string RedactBearerTokens(string input) =>
        BearerTokenRegex.Replace(input, m =>
        {
            var token = m.Groups[2].Value;
            return IsAlreadyRedacted(token)
                ? m.Value
                : m.Groups[1].Value + $"REDACTED_LEN_{TextElementCount(token)}";
        });

    private static string RedactCredentialPairs(string input) =>
        CredentialKeyValueRegex.Replace(input, m =>
        {
            var key = m.Groups[2].Value;
            var value = m.Groups[3].Value;
            return m.Groups[1].Value + RedactValue(key, value);
        });

    /// <summary>A mixed cookie header: the secret pairs go, "theme=dark" stays exactly as it was.
    /// This pass has the wider value class, so it acts only on the cookie key set.</summary>
    private static string RedactCookieHeader(string input) =>
        CookiePairRegex.Replace(input, m =>
        {
            var key = m.Groups[1].Value;
            if (!CookieHeaderKeys.Contains(key.ToLowerInvariant()))
            {
                return m.Value;
            }
            var value = m.Groups[2].Value;
            return key + "=" + RedactValue(key, value);
        });

    /// <summary>
    /// Four passes in order: fragment, query, opaque scheme, then redirect parameters that carry no
    /// scheme at all. The last one is anchored to a real "?", "&amp;" or "#" so ordinary prose such
    /// as "error code=42" is left alone.
    /// </summary>
    private static string RedactUrls(string input)
    {
        var result = UrlFragmentRegex.Replace(input, m => m.Groups[1].Value + "#[REDACTED]");
        result = UrlWithQueryRegex.Replace(result, m => m.Groups[1].Value + "?[REDACTED]");
        result = OpaqueUriRegex.Replace(result, m => m.Groups[1].Value + ":[REDACTED]");
        result = RedirectParamRegex.Replace(result, m =>
        {
            var value = m.Groups[3].Value;
            if (IsAlreadyRedacted(value))
            {
                return m.Value;
            }
            return m.Groups[1].Value + m.Groups[2].Value + "=" + $"REDACTED_LEN_{TextElementCount(value)}";
        });
        return result;
    }
}
