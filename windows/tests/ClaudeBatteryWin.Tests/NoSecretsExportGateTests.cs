using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// The gate the whole redaction system exists to satisfy (U2, R8). Ported from the Mac
/// <c>NoSecretsExportGateTests</c>.
///
/// This is not a source scan - <see cref="NoSecretsGateTests"/> is that, and it is the cheaper second
/// check. This one runs the real pipeline end to end: a real logger writing to a real file, fed
/// planted secrets covering every redaction category at once, then the real eligibility filter, the
/// real archive builder, a real unzip, and a scan of every byte that came back out. A redaction bug
/// that only shows up at runtime fails here and nowhere else.
///
/// The planted values are the Mac's own fixtures, chosen to be distinctive enough that a false
/// negative is not credible.
/// </summary>
public class NoSecretsExportGateTests : IDisposable
{
    /// <summary>Every literal that must never appear in a decoded archive.</summary>
    private static readonly string[] ForbiddenSecrets =
    {
        "sk-ant-",
        "victim@example.com",
        "jens@m\u00FCller.de",
        "m\u00FCller.de",
        "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
        "cfbmRAWVALUE",
        "bearerRAWTOKEN",
        "basicRAWCREDS",
        "PWPLAINTEXT",
        "SIGNATUREBLOB",
        "LEAKEDQUERYVAL",
        "FRAGTOKENLEAK",
        "99887766554433",
        "CLEARANCESECRETXYZ",
        "OPAQUELASTURLSECRET",
        "OPAQUENEXTURLSECRET",
        "LEAKEDCODE",
        "LEAKEDSTATE",
        "idp.example"
    };

    private static readonly Regex AnyEmail =
        new(@"[\p{L}\p{N}\p{M}._%+\-]+@[\p{L}\p{N}\p{M}\-]+\.[\p{L}\p{M}]{2,}");

    private readonly string _dir = Path.Combine(
        Path.GetTempPath(), "cbw-export-gate-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_dir))
            {
                Directory.Delete(_dir, recursive: true);
            }
        }
        catch (IOException)
        {
        }
    }

    private DiagnosticsLogger Logger() => new(settings: null, directoryOverride: _dir, enabledOverride: true);

    private static Func<IDictionary<string, object?>> Payload(IDictionary<string, object?> payload) => () => payload;

    /// <summary>Runs the real export and returns the decoded bytes of every entry, plus the entry
    /// names, so the archive itself is what gets scanned rather than the pre-archive string.</summary>
    private (string Combined, string[] Names) ExportAndDecode()
    {
        var eligible = LogsExporter.EligibleLogFiles(_dir, DateTimeOffset.MinValue);
        Assert.NotEmpty(eligible);

        var archive = LogsExporter.BuildArchive(eligible, DateTimeOffset.UtcNow);
        try
        {
            using var zip = ZipFile.OpenRead(archive);
            var names = zip.Entries.Select(e => e.Name).ToArray();
            var combined = new StringBuilder();
            foreach (var entry in zip.Entries)
            {
                using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
                combined.Append(reader.ReadToEnd());
            }
            return (combined.ToString(), names);
        }
        finally
        {
            File.Delete(archive);
        }
    }

    private static void AssertNoSecretsSurvive(string combined)
    {
        foreach (var secret in ForbiddenSecrets)
        {
            Assert.False(
                combined.Contains(secret, StringComparison.Ordinal),
                $"'{secret}' survived into the exported archive");
        }

        var email = AnyEmail.Match(combined);
        Assert.False(email.Success, $"an email-shaped string survived: {email.Value}");

        // A positive check too: without it this test would pass on an empty archive.
        Assert.Contains("REDACTED_LEN_", combined, StringComparison.Ordinal);
    }

    // --- The end-to-end gate -------------------------------------------------------------------

    [Fact]
    public void EndToEnd_ProducerToArchive_HasNoSecrets()
    {
        // Covers AE10.
        var logger = Logger();

        logger.EmitMilestone("planted", Payload(new Dictionary<string, object?>
        {
            ["sessionKey"] = "sk-ant-PLANTED1",
            ["authorization"] = "Bearer bearerRAWTOKEN",
            ["basic"] = "Basic basicRAWCREDS",
            ["__cf_bm"] = "cfbmRAWVALUE-rotating",
            ["password"] = "PWPLAINTEXT",
            ["note"] = "account for victim@example.com and jens@m\u00FCller.de (umlaut domain)",
            ["url"] = "https://claude.ai/api/organizations/3f2504e0-4f89-41d3-9a0c-0305e82c3301"
                + "?q=LEAKEDQUERYVAL#access=FRAGTOKENLEAK",
            ["customRedirect"] = "com.app.oauth://cb?code=FRAGTOKENLEAK",
            ["token"] = new[] { "sk-ant-PLANTED2", "sk-ant-PLANTED3" },
            ["signature"] = new[] { "SIGNATUREBLOB" },
            ["assertion"] = 99887766554433L,
            ["cookieHeader"] = "cf_clearance=CLEARANCESECRETXYZ; lasturl=OPAQUELASTURLSECRET;"
                + " next-url=OPAQUENEXTURLSECRET; theme=dark"
        }));

        // Three polls, as a real session would produce.
        for (var i = 0; i < 3; i++)
        {
            logger.EmitMilestone("poll", Payload(new Dictionary<string, object?>
            {
                ["status"] = 200,
                ["sessionKey"] = "sk-ant-POLLSECRET" + i
            }));
        }

        // A dump of uncontrolled log content, written straight to disk. It must be excluded by name,
        // not by trusting redaction to have cleaned it.
        File.WriteAllText(
            Path.Combine(_dir, "oslogstore-2026-06-03T00-00-00Z.txt"),
            "Account added: victim@example.com sessionKey=sk-ant-OSLOGRAW\n");

        var (combined, names) = ExportAndDecode();

        AssertNoSecretsSurvive(combined);
        Assert.DoesNotContain("sk-ant-OSLOGRAW", combined, StringComparison.Ordinal);
        Assert.DoesNotContain(names, n => n.StartsWith("oslogstore-", StringComparison.Ordinal));
    }

    [Fact]
    public void EndToEnd_StructuredCookiePairsAndKeyPosition_HasNoSecrets()
    {
        var logger = Logger();

        logger.EmitMilestone("cookie-store-poll", Payload(new Dictionary<string, object?>
        {
            ["count"] = 1,
            ["names"] = new object[]
            {
                new Dictionary<string, object?>
                {
                    ["name"] = "sessionKey",
                    ["domain"] = ".claude.ai",
                    ["value"] = "sk-ant-COOKIEVALSECRET"
                }
            }
        }));

        logger.EmitMilestone("key-position", Payload(new Dictionary<string, object?>
        {
            ["token"] = new Dictionary<string, object?> { ["sk-ant-KEYPOSSECRET"] = true }
        }));

        var (combined, _) = ExportAndDecode();

        Assert.DoesNotContain("sk-ant-COOKIEVALSECRET", combined, StringComparison.Ordinal);
        Assert.DoesNotContain("sk-ant-KEYPOSSECRET", combined, StringComparison.Ordinal);
        Assert.Contains("REDACTED_KEY_", combined, StringComparison.Ordinal);
        Assert.Contains("REDACTED_LEN_", combined, StringComparison.Ordinal);

        // The genuine signal survives: a reader still learns which cookie and which host.
        Assert.Contains("sessionKey", combined, StringComparison.Ordinal);
        Assert.Contains("claude.ai", combined, StringComparison.Ordinal);
    }

    [Fact]
    public void EndToEnd_LoginStateError_HasNoSecrets()
    {
        Logger().EmitMilestone("login-state", Payload(new Dictionary<string, object?>
        {
            ["state"] = "error: sign-in failed for victim@example.com (token sk-ant-LOGINSTATESECRET)"
        }));

        var (combined, _) = ExportAndDecode();

        Assert.DoesNotContain("sk-ant-LOGINSTATESECRET", combined, StringComparison.Ordinal);
        Assert.DoesNotContain("victim@example.com", combined, StringComparison.Ordinal);
        Assert.False(AnyEmail.IsMatch(combined));
        Assert.Contains("REDACTED_LEN_", combined, StringComparison.Ordinal);
        Assert.Contains("login-state", combined, StringComparison.Ordinal);
    }

    [Fact]
    public void EndToEnd_WindowsPathInAnExceptionMessage_LosesTheAccountName()
    {
        Logger().EmitMilestone("io-failed", Payload(new Dictionary<string, object?>
        {
            ["message"] = "System.IO.FileNotFoundException: Could not find file "
                + "'C:\\Users\\someone\\AppData\\Local\\ClaudeBatteryWin\\accounts.json'."
        }));

        var (combined, _) = ExportAndDecode();

        Assert.DoesNotContain("someone", combined, StringComparison.Ordinal);
        Assert.Contains("[USER]", combined, StringComparison.Ordinal);
    }

    [Fact]
    public void Export_NeverAdmitsTheCrashLogOrTheAccountsFile()
    {
        Logger().EmitMilestone("probe", Payload(new Dictionary<string, object?> { ["x"] = 1 }));

        File.WriteAllText(Path.Combine(_dir, "crash.log"), "sessionKey=sk-ant-CRASHRAW");
        File.WriteAllText(Path.Combine(_dir, "accounts.json"), "[{\"sessionKey\":\"sk-ant-ACCOUNTSRAW\"}]");
        File.WriteAllText(Path.Combine(_dir, "diag-not-a-log.txt"), "sk-ant-WRONGSUFFIX");

        var (combined, names) = ExportAndDecode();

        Assert.DoesNotContain("crash.log", names);
        Assert.DoesNotContain("accounts.json", names);
        Assert.DoesNotContain("diag-not-a-log.txt", names);
        Assert.DoesNotContain("sk-ant-CRASHRAW", combined, StringComparison.Ordinal);
        Assert.DoesNotContain("sk-ant-ACCOUNTSRAW", combined, StringComparison.Ordinal);
        Assert.DoesNotContain("sk-ant-WRONGSUFFIX", combined, StringComparison.Ordinal);
    }


    // --- The plan sample -----------------------------------------------------------------------

    [Fact]
    public void EndToEnd_PlanSample_CarriesTheSignalAndNoIdentity()
    {
        var accountId = Guid.Parse("3f2504e0-4f89-41d3-9a0c-0305e82c3301");
        var account = new Account
        {
            Id = accountId,
            Email = "victim@example.com",
            SessionKey = "sk-ant-PLANSAMPLEKEY",
            OrganizationId = "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
            OrganizationName = "victim@example.com's Organization",
            RateLimitTier = "default_claude_max_5x",
            Capabilities = new[] { "claude_max", "chat" },
            BillingType = "stripe_subscription",
        };

        var reading = new UsageReading(
            new UsageSnapshot
            {
                SessionRemaining = 40,
                SessionResetDate = new DateTimeOffset(2026, 7, 29, 12, 34, 56, TimeSpan.Zero),
                WeeklyRemaining = 80,
                WeeklyResetDate = new DateTimeOffset(2026, 8, 2, 3, 4, 5, TimeSpan.Zero),
            },
            PlanRatio.Max5x);

        var measurement = new RatioMeasurement { SessionPointsConsumed = 400, WeeklyPointsConsumed = 42 };

        Logger().EmitMilestone(
            UsageService.PlanSampleKind,
            () => UsageService.PlanSamplePayload(account, reading, measurement));

        var (combined, _) = ExportAndDecode();

        // The signal survives, non-destructively.
        Assert.Contains("plan-sample", combined, StringComparison.Ordinal);
        Assert.DoesNotContain("serialize-failed", combined, StringComparison.Ordinal);
        Assert.Contains("default_claude_max_5x", combined, StringComparison.Ordinal);
        Assert.Contains("claude_max", combined, StringComparison.Ordinal);
        Assert.Contains("chat", combined, StringComparison.Ordinal);
        Assert.Contains("stripe_subscription", combined, StringComparison.Ordinal);
        Assert.Contains("2026-07-29T12:34:56Z", combined, StringComparison.Ordinal);
        Assert.Contains("2026-08-02T03:04:05Z", combined, StringComparison.Ordinal);
        Assert.Contains("applied_ratio", combined, StringComparison.Ordinal);
        Assert.Contains("measured_ratio", combined, StringComparison.Ordinal);
        Assert.Contains(SecretRedactor.Sha256Prefix(accountId.ToString()), combined, StringComparison.Ordinal);

        // Nothing that identifies the account outside the install that produced it.
        Assert.DoesNotContain(accountId.ToString(), combined, StringComparison.Ordinal);
        Assert.DoesNotContain("victim@example.com", combined, StringComparison.Ordinal);
        Assert.False(AnyEmail.IsMatch(combined));
        foreach (var key in new[] { "org_name", "organization_name", "organization_id", "email", "uuid" })
        {
            Assert.DoesNotContain($"\"{key}\"", combined, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void PlanSamplePayload_WritesAbsenceAsAnExplicitNull()
    {
        // A reader has to be able to tell "never measured yet" from "this build does not emit it".
        var account = new Account
        {
            Email = "Account 1",
            SessionKey = "sk",
            OrganizationId = "org-1",
        };
        var reading = new UsageReading(
            new UsageSnapshot { SessionRemaining = 40, WeeklyRemaining = 80 }, null);

        var payload = UsageService.PlanSamplePayload(account, reading, new RatioMeasurement());

        foreach (var key in new[]
                 {
                     "rate_limit_tier", "capabilities", "billing_type",
                     "session_resets_at", "weekly_resets_at", "measured_ratio", "applied_ratio"
                 })
        {
            Assert.True(payload.ContainsKey(key), $"{key} is missing entirely");
            Assert.Null(payload[key]);
        }

        Assert.Equal(40.0, payload["session_remaining"]);
        Assert.Equal(80.0, payload["weekly_remaining"]);
    }

    [Fact]
    public void PlantedSecrets_AreNotWrittenAtAllWhenLoggingIsOff()
    {
        var logger = new DiagnosticsLogger(settings: null, directoryOverride: _dir, enabledOverride: false);

        logger.EmitMilestone("planted", Payload(new Dictionary<string, object?>
        {
            ["sessionKey"] = "sk-ant-OFFGATESECRET"
        }));

        Assert.False(Directory.Exists(_dir));
        Assert.Empty(LogsExporter.EligibleLogFiles(_dir, DateTimeOffset.MinValue));
    }
}
