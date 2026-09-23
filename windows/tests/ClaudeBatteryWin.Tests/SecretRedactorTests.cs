using System.Text.RegularExpressions;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// The redactor, checked against the Mac's own test values (U2, KTD1, KTD4). Every planted leak here
/// is one of the Mac's fixtures, so a rule that was dropped in the port fails under the same scenario
/// name it fails under on the Mac.
///
/// Two things are being proven at once: no secret survives, and genuine diagnostic signal does. A
/// redactor that scrubbed everything would pass the first half and make the exported file useless.
/// </summary>
public class SecretRedactorTests
{
    private static void AssertAbsent(string output, params string[] needles)
    {
        foreach (var needle in needles)
        {
            Assert.False(
                output.Contains(needle, StringComparison.Ordinal),
                $"'{needle}' survived redaction: {output}");
        }
    }

    private static void AssertPresent(string output, params string[] needles)
    {
        foreach (var needle in needles)
        {
            Assert.True(
                output.Contains(needle, StringComparison.Ordinal),
                $"'{needle}' is missing from: {output}");
        }
    }

    // --- Entry dispatch ------------------------------------------------------------------------

    [Theory]
    [InlineData("")]
    [InlineData("nothing to see here")]
    public void EmptyAndPlainStrings_PassThrough(string input) =>
        Assert.Equal(input, SecretRedactor.Redact(input));

    // --- Key handling --------------------------------------------------------------------------

    [Theory]
    [InlineData("{\"token \":\"NEEDLE_TRAIL_A\"}", "NEEDLE_TRAIL_A")]
    [InlineData("{\" sessionKey\":\"NEEDLE_LEAD_B\"}", "NEEDLE_LEAD_B")]
    public void WhitespacePaddedCredentialKeyInJson_Redacted(string input, string needle) =>
        AssertAbsent(SecretRedactor.Redact(input), needle);

    [Theory]
    [InlineData("{\"sess\u200BionKey\":\"NEEDLE_ZW_A\"}", "NEEDLE_ZW_A")]
    [InlineData("{\"to\u200Cken\":\"NEEDLE_ZW_B\"}", "NEEDLE_ZW_B")]
    public void ZeroWidthSplitCredentialKeyInJson_Redacted(string input, string needle) =>
        AssertAbsent(SecretRedactor.Redact(input), needle);

    [Fact]
    public void CredentialSubstringKeyInJson_Redacted() =>
        AssertAbsent(
            SecretRedactor.Redact("{\"my_token\":\"S1\",\"refresh_token\":\"S2\",\"x_csrftoken\":\"S3\"}"),
            "S1", "S2", "S3");

    // --- Leaf rules ----------------------------------------------------------------------------

    [Theory]
    [InlineData("{\"token\":1234567}", "1234567")]
    [InlineData("{\"token\":true}", "true")]
    [InlineData("{\"payload\":{\"sessionKey\":42424242}}", "42424242")]
    public void NonStringScalarUnderCredentialKey_RedactedToMarker(string input, string needle)
    {
        var output = SecretRedactor.Redact(input);
        AssertPresent(output, "REDACTED_NONSCALAR");
        AssertAbsent(output, needle);
    }

    [Fact]
    public void ScalarArrayElementsUnderCredentialKey_Redacted()
    {
        var output = SecretRedactor.Redact("{\"token\":[\"sk-secret\",123,true,null]}");
        AssertAbsent(output, "sk-secret", "123");
        AssertPresent(output, "REDACTED_NONSCALAR");
    }

    [Fact]
    public void SecretAsJsonKeyUnderCredentialKey_Redacted()
    {
        var output = SecretRedactor.Redact("{\"token\":{\"sk-ant-KEYSECRET\":true}}");
        AssertAbsent(output, "sk-ant-KEYSECRET");
        AssertPresent(output, "REDACTED_KEY_");
    }

    [Fact]
    public void NestedSecretUnderCredentialKey_DoesNotSurvive()
    {
        var output = SecretRedactor.Redact(
            "{\"kind\":\"x\",\"payload\":{\"token\":[{\"inner\":\"sk-ant-DEEPSECRET\"}]},\"ts\":1}");
        AssertAbsent(output, "sk-ant-DEEPSECRET");
        AssertPresent(output, "REDACTED_LEN_");
    }

    [Fact]
    public void RotationKeys_KeepOnly8CharPrefix()
    {
        var output = SecretRedactor.Redact("{\"__cf_bm\":\"cfbmRAWVALUE-rotating\"}");
        AssertAbsent(output, "cfbmRAWVALUE");
        Assert.Matches(new Regex(@"[0-9a-f]{8}\.\.\.REDACTED_LEN_"), output);
    }

    // --- Idempotence ---------------------------------------------------------------------------

    [Theory]
    [InlineData("{\"token\":\"SECRET...REDACTED_LEN_5\"}", "SECRET...")]
    [InlineData("{\"token\":\"myprefix...REDACTED_LEN_99\"}", "myprefix")]
    public void CraftedMarkerPrefix_IsStillRedacted(string input, string needle)
    {
        var output = SecretRedactor.Redact(input);
        AssertAbsent(output, needle);
        AssertPresent(output, "REDACTED_LEN_");
    }

    [Theory]
    [InlineData("{\"token\":\"REDACTED_LEN_25\"}")]
    [InlineData("{\"__cf_bm\":\"457f11ea...REDACTED_LEN_25\"}")]
    public void GenuineMarkers_AreUnchanged(string input) =>
        Assert.Equal(input, SecretRedactor.Redact(input));

    [Fact]
    public void RedactingTwice_ProducesIdenticalBytes()
    {
        const string input = "{\"b\":\"x\",\"token\":\"abc\"}";
        var once = SecretRedactor.Redact(input);
        Assert.Equal(once, SecretRedactor.Redact(once));
    }

    // --- Cookie header and credential pairs ----------------------------------------------------

    [Fact]
    public void MixedCookieHeader_RedactsSecretsKeepsHarmless()
    {
        var output = SecretRedactor.Redact(
            "Cookie: sessionKey=sk-ant-deadbeef; __cf_bm=cfbmsecretvalue999; theme=dark");
        AssertAbsent(output, "sk-ant-deadbeef", "cfbmsecretvalue999");
        AssertPresent(output, "theme=dark");
    }

    [Fact]
    public void CommaDelimitedCredentialValue_FullyRedacted()
    {
        var output = SecretRedactor.Redact("token=abc,def,ghi rest");
        AssertAbsent(output, "abc,def,ghi");
        AssertPresent(output, "rest");
    }

    [Fact]
    public void SemicolonInNonCookieCredentialValue_FullyRedacted() =>
        AssertAbsent(SecretRedactor.Redact("assertion=abc;def"), "def");

    public static IEnumerable<object[]> BraceParenRemnantCases()
    {
        foreach (var key in new[] { "token", "assertion", "signature", "password", "csrftoken", "x-csrf-token", "_csrf", "authorization" })
        {
            foreach (var delimiter in new[] { ")", "}" })
            {
                yield return new object[] { $"{key}=HEADPART{delimiter}REMNANTLEAKTAIL" };
                yield return new object[] { $"{{\"note\":\"{key}=HEADPART{delimiter}REMNANTLEAKTAIL\"}}" };
            }
        }
    }

    [Theory]
    [MemberData(nameof(BraceParenRemnantCases))]
    public void BraceParenRemnant_NonCookieCredentialKeys_FullyRedacted(string input) =>
        AssertAbsent(SecretRedactor.Redact(input), "REMNANTLEAKTAIL");

    [Fact]
    public void HarmlessNonCredentialSignal_Preserved() =>
        AssertPresent(
            SecretRedactor.Redact("{\"decision\":\"allow\",\"host\":\"claude.ai\",\"status\":403,\"state\":\"signingIn\"}"),
            "claude.ai", "allow", "signingIn", "403");

    [Fact]
    public void GluedPrefixCookieKey_StillRedacted() =>
        AssertAbsent(
            SecretRedactor.Redact(new string('j', 4039) + "cf_clearance=GLUEDSECRETVALUE"),
            "GLUEDSECRETVALUE");

    // --- Authorization -------------------------------------------------------------------------

    [Theory]
    [InlineData("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.signaturepart", "eyJhbGciOiJIUzI1NiJ9")]
    [InlineData("Authorization: Bearer abc:def:ghi", "def:ghi")]
    [InlineData("Authorization: Negotiate NEGOTIATESECRETBLOB", "NEGOTIATESECRETBLOB")]
    [InlineData("Authorization: Digest realm=\"x\", nonce=\"DIGESTNONCESECRET\"", "DIGESTNONCESECRET")]
    [InlineData("authorization=Bearer EQUALSSEPARATEDSECRET", "EQUALSSEPARATEDSECRET")]
    [InlineData("Authorization\uFF1ANegotiate FWNEGOTIATEsecret", "FWNEGOTIATEsecret")]
    [InlineData("proxy-authorization\uFF1DNTLM FWNTLMsecretblob", "FWNTLMsecretblob")]
    public void AuthorizationAnyScheme_FullyRedacted(string input, string needle) =>
        AssertAbsent(SecretRedactor.Redact(input), needle);

    [Theory]
    [InlineData("{\"header\":\"Bearer abc123def456ghi789jkl\"}", "abc123def456ghi789jkl")]
    [InlineData("Bearer \"NEEDLE_Q_A\"", "NEEDLE_Q_A")]
    [InlineData("Bearer *NEEDLE_STAR_B", "NEEDLE_STAR_B")]
    [InlineData("Bearer NEEDLE_AT_C@host", "NEEDLE_AT_C")]
    public void BareBearerToken_FullyRedacted(string input, string needle) =>
        AssertAbsent(SecretRedactor.Redact(input), needle);

    // --- URLs ----------------------------------------------------------------------------------

    [Fact]
    public void UrlQuery_Redacted()
    {
        var output = SecretRedactor.Redact("https://claude.ai/api/x?sessionKey=secret&t=1");
        AssertPresent(output, "https://claude.ai/api/x", "?[REDACTED]");
        AssertAbsent(output, "sessionKey=secret");
    }

    [Theory]
    [InlineData("https://claude.ai/cb#access_token=FRAGTOKENLEAK", "FRAGTOKENLEAK", "#[REDACTED]")]
    [InlineData("msauth.com.x://auth#access_token=CUSTOMFRAGLEAK", "CUSTOMFRAGLEAK", "#[REDACTED]")]
    [InlineData("data:image/png;base64,SECRETPAYLOADBLOB", "SECRETPAYLOADBLOB", "data:[REDACTED]")]
    [InlineData("mailto:victim@example.com?subject=hi", "victim@example.com", "mailto:[REDACTED]")]
    public void UrlShapes_Redacted(string input, string needle, string marker)
    {
        var output = SecretRedactor.Redact(input);
        AssertAbsent(output, needle);
        AssertPresent(output, marker);
    }

    [Theory]
    [InlineData("com.app.oauth://callback?code=CUSTOMCODE", "CUSTOMCODE")]
    [InlineData("/auth/cb?code=LIVEAUTHCODE123&next=/x", "LIVEAUTHCODE123")]
    [InlineData("/cb#access_token=AT_LEAK&id_token=IT_LEAK", "AT_LEAK")]
    public void RedirectParams_Redacted(string input, string needle) =>
        AssertAbsent(SecretRedactor.Redact(input), needle);

    [Theory]
    [InlineData("error code=42")]
    [InlineData("NSURLErrorDomain code=-1012")]
    [InlineData("area code=415 here")]
    public void RedirectParamCode_NotRedactedInProse(string input) =>
        Assert.Equal(input, SecretRedactor.Redact(input));

    // --- UUID, emails, and the Anthropic-token backstop ----------------------------------------

    [Fact]
    public void UuidPath_Redacted()
    {
        var output = SecretRedactor.Redact("/api/organizations/3f2504e0-4f89-41d3-9a0c-0305e82c3301/usage");
        AssertPresent(output, "[ORG-UUID]");
        AssertAbsent(output, "3f2504e0");
    }

    [Theory]
    [InlineData("account for victim@example.com please", "victim@example.com")]
    [InlineData("write to jens@m\u00FCller.de now", "m\u00FCller.de")]
    [InlineData("write to jens@mu\u0308ller.de now", "mu\u0308ller.de")]
    [InlineData("u@inter_nal.example.com", "inter_nal.example.com")]
    [InlineData("\"weird name\"@example.com", "example.com")]
    [InlineData("victim@example.comX", "victim@example.com")]
    public void Emails_RedactedToToken(string input, string needle)
    {
        var output = SecretRedactor.Redact(input);
        AssertAbsent(output, needle);
        AssertPresent(output, "[EMAIL]");
    }

    [Fact]
    public void EmailMidString_RedactedInPlace() =>
        AssertPresent(SecretRedactor.Redact("someone@gmail.com's Organization"), "[EMAIL]'s Organization");

    [Fact]
    public void DotlessHost_IsNotAnEmail() =>
        Assert.Equal("user@localhost", SecretRedactor.Redact("user@localhost"));

    [Fact]
    public void EmailUnderCredentialKey_RedactedToLength()
    {
        var output = SecretRedactor.Redact("{\"email\":\"victim@example.com\"}");
        AssertPresent(output, "REDACTED_LEN_");
        AssertAbsent(output, "victim@example.com", "[EMAIL]");
    }

    [Fact]
    public void ApiToken_InFreeText_Redacted() =>
        AssertAbsent(
            SecretRedactor.Redact("failed with token sk-ant-FREETEXTSECRET in the message"),
            "sk-ant-FREETEXTSECRET");

    // --- The Windows rule the Mac never needed -------------------------------------------------

    [Fact]
    public void WindowsUserProfilePath_HasItsAccountNameReplaced()
    {
        var output = SecretRedactor.Redact(
            "System.IO.FileNotFoundException: Could not find C:\\Users\\someone\\AppData\\Local\\x.json");
        AssertAbsent(output, "someone");
        AssertPresent(output, "[USER]", "AppData");
    }

    [Fact]
    public void WindowsUserProfilePath_InsideJsonValue_HasItsAccountNameReplaced() =>
        AssertAbsent(
            SecretRedactor.Redact("{\"error\":\"open C:\\\\Users\\\\someone\\\\AppData\\\\Local\\\\x.json failed\"}"),
            "someone");

    [Fact]
    public void RedirectedProfilePath_HasTheAccountNameReplaced()
    {
        // A roaming or redirected profile never matches the C:\Users\ shape, so the literal account
        // name is matched too - between separators only, so ordinary prose is left alone.
        var user = Environment.UserName;
        if (user.Length < 3)
        {
            return; // too short to match safely; the rule deliberately skips it
        }

        var output = SecretRedactor.Redact($"open D:\\Profiles\\{user}\\AppData\\Local\\x.json failed");
        AssertAbsent(output, user);
        AssertPresent(output, "[USER]");
    }

    // --- Pipeline shape ------------------------------------------------------------------------

    [Fact]
    public void LongNonMatchingInput_CompletesQuicklyAndTruncates()
    {
        var input = string.Concat(Enumerable.Repeat("ab", 20000));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var output = SecretRedactor.Redact(input);
        watch.Stop();

        AssertPresent(output, "\u2026[TRUNCATED]");
        Assert.True(watch.ElapsedMilliseconds < 1000, $"took {watch.ElapsedMilliseconds}ms");
    }

    [Fact]
    public void LongInput_StillRedactsLeadingSecret()
    {
        var input = "sessionKey=sk-ant-HEADSECRET" + new string('x', 20000);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var output = SecretRedactor.Redact(input);
        watch.Stop();

        AssertAbsent(output, "sk-ant-HEADSECRET");
        Assert.True(watch.ElapsedMilliseconds < 1000, $"took {watch.ElapsedMilliseconds}ms");
    }

    [Fact]
    public void CredentialRedactionAlwaysRuns_NoSilentSkip()
    {
        // The patterns are compiled once. A per-call compile that failed would skip a whole pass and
        // nothing would say so, which is why this runs the same input 200 times.
        for (var i = 0; i < 200; i++)
        {
            AssertAbsent(SecretRedactor.Redact("sessionKey=sk-ant-LOOPSECRET"), "sk-ant-LOOPSECRET");
        }
    }

    [Fact]
    public void Sha256Prefix_IsEightLowercaseHexAndStable()
    {
        var first = SecretRedactor.Sha256Prefix("some-account-id");
        Assert.Equal(8, first.Length);
        Assert.Matches(new Regex("^[0-9a-f]{8}$"), first);
        Assert.Equal(first, SecretRedactor.Sha256Prefix("some-account-id"));
        Assert.NotEqual(first, SecretRedactor.Sha256Prefix("another-account-id"));
    }
}
