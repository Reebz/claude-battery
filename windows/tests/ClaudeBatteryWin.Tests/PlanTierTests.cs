using System.IO;
using System.Net;
using System.Text.Json;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// U3: the app learns which plan each organization is on, and the organizations response stops being
/// able to fail a whole sign-in over one wrong-typed field.
///
/// Two things are proven here. First, decoding degrades per field: an unexpected shape reads as
/// absent and the sign-in continues, while a missing organization id still fails, because an
/// organization with no id cannot be stored or polled. Second, the plan-change rule, which is the
/// only condition that discards an account's measured conversion ratio.
/// </summary>
public sealed class PlanTierTests : IDisposable
{
    private readonly string _root;

    public PlanTierTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "cbw-plantier-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_root))
            {
                Directory.Delete(_root, recursive: true);
            }
        }
        catch (IOException)
        {
        }
    }

    private string SecretsDir => Path.Combine(_root, "secrets");

    private string MetadataPath => Path.Combine(_root, "accounts.json");

    private AccountStore NewStore(CookieContainer? jar = null) =>
        new(jar ?? new CookieContainer(), new SecretStore(SecretsDir), MetadataPath);

    /// The same options the transport uses, so these tests decode exactly what production decodes.
    private static readonly JsonSerializerOptions ApiOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        PropertyNameCaseInsensitive = true,
        NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowReadingFromString,
    };

    private static List<Organization>? DecodeOrgs(string json) =>
        JsonSerializer.Deserialize<List<Organization>>(json, ApiOptions);

    private static Account SeedAccount(string org = "org-1", string? tier = null, RatioMeasurement? measurement = null) => new()
    {
        Email = "user@example.com",
        SessionKey = "sk-seed",
        OrganizationId = org,
        AllCookieHeader = "sessionKey=sk-seed",
        RateLimitTier = tier,
        RatioMeasurement = measurement,
    };

    private static RatioMeasurement Measurement(double session = 400, double weekly = 32) => new()
    {
        LastSessionRemaining = 50,
        LastWeeklyRemaining = 60,
        SessionPointsConsumed = session,
        WeeklyPointsConsumed = weekly,
    };

    // --- Decoding ------------------------------------------------------------------------------

    [Fact]
    public void OrganizationsResponse_WithPlanFields_Decodes()
    {
        var orgs = DecodeOrgs("""
            [{"uuid":"org-1","name":"Acme","rate_limit_tier":"default_claude_max_5x",
              "capabilities":["claude_max","chat"],"billing_type":"stripe_subscription",
              "email_address":"user@acme.com"}]
            """);

        var org = Assert.Single(orgs!);
        Assert.Equal("default_claude_max_5x", org.RateLimitTier);
        Assert.Equal(new[] { "claude_max", "chat" }, org.Capabilities);
        Assert.Equal("stripe_subscription", org.BillingType);
        Assert.Equal("user@acme.com", org.EmailAddress);
    }

    [Fact]
    public void MacOrgsFixture_DecodesWithEveryOptionalFieldAbsent()
    {
        Assert.True(RepoFixtures.Available, "the Mac fixtures are part of this repository");

        var orgs = DecodeOrgs(RepoFixtures.Read("orgs_multiple.json"))!;

        Assert.Equal(2, orgs.Count);
        Assert.Equal(new[] { "org-abc-123-def-456", "org-xyz-789-ghi-012" }, orgs.Select(o => o.Uuid).ToArray());
        Assert.All(orgs, o =>
        {
            Assert.Null(o.RateLimitTier);
            Assert.Null(o.Capabilities);
            Assert.Null(o.Name);
        });
    }

    [Theory]
    [InlineData("\"rate_limit_tier\":5")]
    [InlineData("\"rate_limit_tier\":{\"name\":\"pro\"}")]
    [InlineData("\"rate_limit_tier\":[\"pro\"]")]
    [InlineData("\"capabilities\":[{\"name\":\"claude_max\"}]")]
    [InlineData("\"capabilities\":\"claude_max\"")]
    [InlineData("\"name\":42")]
    [InlineData("\"billing_type\":true")]
    [InlineData("\"email_address\":[]")]
    public void WrongTypedOptionalField_ReadsAsAbsentAndTheRestOfTheResponseSurvives(string malformed)
    {
        // Covers R15: the whole sign-in used to fail as a connection error over a field the app only
        // carries into a diagnostics record.
        var orgs = DecodeOrgs($"[{{\"uuid\":\"org-1\",{malformed}}},{{\"uuid\":\"org-2\",\"name\":\"Second\"}}]")!;

        Assert.Equal(2, orgs.Count);
        Assert.Equal("org-1", orgs[0].Uuid);
        Assert.Equal("Second", orgs[1].Name);
    }

    [Fact]
    public void WrongTypedTier_LeavesTheTierNullRatherThanGuessing()
    {
        var orgs = DecodeOrgs("[{\"uuid\":\"org-1\",\"rate_limit_tier\":5}]")!;
        Assert.Null(orgs[0].RateLimitTier);
    }

    [Fact]
    public void OrganizationWithNoId_FailsToDecode() =>
        Assert.ThrowsAny<JsonException>(() => DecodeOrgs("[{\"name\":\"no id here\"}]"));

    // --- UpdatePlan ----------------------------------------------------------------------------

    [Fact]
    public void UpdatePlan_WritesThroughToDisk()
    {
        var store = NewStore();
        store.UpsertAccount(SeedAccount());
        var id = store.Accounts[0].Id;

        store.UpdatePlan(id, "default_claude_max_5x", new[] { "claude_max" }, "stripe_subscription");

        Assert.Equal("default_claude_max_5x", store.Accounts[0].RateLimitTier);

        var reloaded = NewStore();
        Assert.Equal("default_claude_max_5x", reloaded.Accounts[0].RateLimitTier);
        Assert.Equal(new[] { "claude_max" }, reloaded.Accounts[0].Capabilities);
        Assert.Equal("stripe_subscription", reloaded.Accounts[0].BillingType);
        Assert.NotNull(reloaded.Accounts[0].PlanUpdatedAt);
    }

    [Fact]
    public void UpdatePlan_WithNulls_ClearsAStoredPlan()
    {
        var store = NewStore();
        store.UpsertAccount(SeedAccount(tier: "default_claude_max_20x"));
        var id = store.Accounts[0].Id;
        store.UpdatePlan(id, "default_claude_max_20x", new[] { "claude_max" });

        store.UpdatePlan(id, null, null);

        Assert.Null(store.Accounts[0].RateLimitTier);
        Assert.Null(store.Accounts[0].Capabilities);
    }

    [Fact]
    public void UpdatePlan_ForAnUnknownId_ChangesNothing()
    {
        var store = NewStore();
        store.UpsertAccount(SeedAccount(tier: "default_claude_pro"));

        store.UpdatePlan(Guid.NewGuid(), "default_claude_max_5x", null);

        Assert.Single(store.Accounts);
        Assert.Equal("default_claude_pro", store.Accounts[0].RateLimitTier);
    }

    [Fact]
    public void UpdatePlan_LeavesCredentialsAlone()
    {
        var store = NewStore();
        store.UpsertAccount(SeedAccount());
        var id = store.Accounts[0].Id;

        store.UpdatePlan(id, "default_claude_pro", null);

        Assert.Equal("sk-seed", store.Accounts[0].SessionKey);
        Assert.Equal("sessionKey=sk-seed", store.Accounts[0].AllCookieHeader);
    }

    [Fact]
    public void TierChangingBetweenTwoKnownPlans_DiscardsTheMeasurement()
    {
        // Covers AE13: a measurement taken on Max 5x says nothing about Max 20x.
        var store = NewStore();
        store.UpsertAccount(SeedAccount(tier: "default_claude_max_5x", measurement: Measurement()));
        var id = store.Accounts[0].Id;

        store.UpdatePlan(id, "default_claude_max_20x", null);

        Assert.Null(store.Accounts[0].RatioMeasurement);
        Assert.Null(NewStore().Accounts[0].RatioMeasurement); // cleared on disk too
    }

    [Fact]
    public void TheSameTierAgain_LeavesTheMeasurementAlone()
    {
        var store = NewStore();
        store.UpsertAccount(SeedAccount(tier: "default_claude_max_5x", measurement: Measurement()));

        store.UpdatePlan(store.Accounts[0].Id, "default_claude_max_5x", null);

        Assert.Equal(32, store.Accounts[0].RatioMeasurement!.WeeklyPointsConsumed);
    }

    [Fact]
    public void LearningTheTierForTheFirstTime_LeavesTheMeasurementAlone()
    {
        var store = NewStore();
        store.UpsertAccount(SeedAccount(tier: null, measurement: Measurement()));

        store.UpdatePlan(store.Accounts[0].Id, "default_claude_max_20x", null);

        Assert.Equal("default_claude_max_20x", store.Accounts[0].RateLimitTier);
        Assert.Equal(32, store.Accounts[0].RatioMeasurement!.WeeklyPointsConsumed);
    }

    [Fact]
    public void ATierGoingMissing_LeavesTheMeasurementAlone()
    {
        // A field that stopped arriving means the response changed, not that the user changed plan.
        var store = NewStore();
        store.UpsertAccount(SeedAccount(tier: "default_claude_max_5x", measurement: Measurement()));

        store.UpdatePlan(store.Accounts[0].Id, null, null);

        Assert.Null(store.Accounts[0].RateLimitTier);
        Assert.Equal(32, store.Accounts[0].RatioMeasurement!.WeeklyPointsConsumed);
    }

    // --- The three sign-in routes --------------------------------------------------------------

    [Fact]
    public async Task SigningInThroughTheWindow_StoresThePlan()
    {
        var api = new FakeClaudeApi
        {
            Orgs = new[]
            {
                new Organization
                {
                    Uuid = "org-1",
                    EmailAddress = "user@acme.com",
                    RateLimitTier = "default_claude_max_5x",
                    Capabilities = new List<string> { "claude_max" },
                    BillingType = "stripe_subscription",
                }
            }
        };
        var store = NewStore();
        var web = new FakeLoginWebView();
        var manager = new AuthManager(api, store, new FakeLoginWebViewFactory(web), new FakeOrgPicker());

        manager.PresentLogin();
        web.RaiseCookiesObserved(new[]
        {
            AuthManagerTests.Cookie("sessionKey", "sk-live"),
            AuthManagerTests.Cookie("__cf_bm", "cf"),
        });
        await manager.LastDiscoveryTask!;

        var account = Assert.Single(store.Accounts);
        Assert.Equal("default_claude_max_5x", account.RateLimitTier);
        Assert.Equal(new[] { "claude_max" }, account.Capabilities);
        Assert.Equal("stripe_subscription", account.BillingType);
    }

    [Fact]
    public async Task ReAuthenticatingThroughTheWindow_RefreshesTheStoredPlan()
    {
        var store = NewStore();
        store.UpsertAccount(SeedAccount(org: "org-1", tier: "default_claude_pro"));

        var api = new FakeClaudeApi
        {
            Orgs = new[]
            {
                new Organization { Uuid = "org-1", RateLimitTier = "default_claude_max_20x" }
            }
        };
        var web = new FakeLoginWebView();
        var manager = new AuthManager(api, store, new FakeLoginWebViewFactory(web), new FakeOrgPicker());

        manager.PresentLogin();
        web.RaiseCookiesObserved(new[]
        {
            AuthManagerTests.Cookie("sessionKey", "sk-fresh"),
            AuthManagerTests.Cookie("__cf_bm", "cf"),
        });
        await manager.LastDiscoveryTask!;

        Assert.Equal("default_claude_max_20x", Assert.Single(store.Accounts).RateLimitTier);
    }

    [Fact]
    public async Task PastingACookieHeader_RefreshesTheStoredPlan()
    {
        var store = NewStore();
        store.UpsertAccount(SeedAccount(org: "org-1", tier: "default_claude_pro", measurement: Measurement()));

        var api = new FakeClaudeApi
        {
            Orgs = new[]
            {
                new Organization { Uuid = "org-1", RateLimitTier = "default_claude_max_20x" }
            }
        };

        var result = await new ManualSignIn(api, store).SignInAsync("sessionKey=sk-pasted; __cf_bm=cf");

        Assert.Equal(ManualSignInResult.ResultKind.Success, result.Kind);
        var account = Assert.Single(store.Accounts);
        Assert.Equal("default_claude_max_20x", account.RateLimitTier);
        // The plan moved between two known plans, so what was measured on the old one is discarded.
        Assert.Null(account.RatioMeasurement);
    }

    // --- Persistence ---------------------------------------------------------------------------

    [Fact]
    public void AccountsFileWrittenBeforeThisRelease_LoadsWithNulls()
    {
        Directory.CreateDirectory(_root);
        File.WriteAllText(MetadataPath, """
            {
              "ActiveAccountId": "11111111-1111-1111-1111-111111111111",
              "Accounts": [
                {
                  "Id": "11111111-1111-1111-1111-111111111111",
                  "Email": "old@example.com",
                  "SessionKey": "",
                  "OrganizationId": "org-old",
                  "AddedDate": "2026-01-01T00:00:00+00:00",
                  "NotificationThreshold": 20.0,
                  "DidNotifyBelowThreshold": false
                }
              ]
            }
            """);

        var account = Assert.Single(NewStore().Accounts);
        Assert.Null(account.RateLimitTier);
        Assert.Null(account.Capabilities);
        Assert.Null(account.BillingType);
        Assert.Null(account.PlanUpdatedAt);
        Assert.Null(account.RatioMeasurement);
        Assert.Null(account.OrganizationName);
    }

    [Fact]
    public void MeasurementSurvivesAStorageRoundTrip()
    {
        var store = NewStore();
        store.UpsertAccount(SeedAccount(tier: "default_claude_pro", measurement: new RatioMeasurement
        {
            LastSessionRemaining = 92,
            LastSessionResetsAt = new DateTimeOffset(2026, 7, 29, 12, 34, 56, TimeSpan.Zero),
            LastWeeklyRemaining = 62,
            LastWeeklyResetsAt = new DateTimeOffset(2026, 8, 2, 3, 4, 5, TimeSpan.Zero),
            SessionPointsConsumed = 8,
            WeeklyPointsConsumed = 1,
        }));

        // Reset times have to survive, or every relaunch looks like a window rollover.
        var reloaded = Assert.Single(NewStore().Accounts).RatioMeasurement!;
        Assert.Equal(new DateTimeOffset(2026, 7, 29, 12, 34, 56, TimeSpan.Zero), reloaded.LastSessionResetsAt);
        Assert.Equal(new DateTimeOffset(2026, 8, 2, 3, 4, 5, TimeSpan.Zero), reloaded.LastWeeklyResetsAt);
        Assert.Equal(8, reloaded.SessionPointsConsumed);
        Assert.Equal(1, reloaded.WeeklyPointsConsumed);
    }

    [Fact]
    public void ARelaunchWithALockedAccountsFile_DoesNotCostTheAccountItsPlanOrMeasurement()
    {
        // Launch once and store a plan and a measurement.
        var first = NewStore();
        first.UpsertAccount(SeedAccount(org: "org-1", tier: "default_claude_max_5x", measurement: Measurement()));

        // Relaunch while accounts.json is locked, so the store starts empty and knows the on-disk
        // list is intact but unreadable.
        AccountStore second;
        using (var _ = new FileStream(MetadataPath, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            second = NewStore();
            Assert.Empty(second.Accounts);
        }

        // Sign in to the same organization again once the lock is gone. The fresh account supersedes
        // the on-disk one, and has to inherit what that one had learned.
        second.UpsertAccount(SeedAccount(org: "org-1"));

        var survivor = Assert.Single(second.Accounts);
        Assert.Equal("default_claude_max_5x", survivor.RateLimitTier);
        Assert.Equal(32, survivor.RatioMeasurement!.WeeklyPointsConsumed);
    }
}
