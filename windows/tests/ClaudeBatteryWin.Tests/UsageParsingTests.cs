using System.Text.Json;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Tolerant-parsing tests for U4: <c>resets_at</c> across ISO8601 / int epoch / string epoch /
/// missing; both the legacy-tier and the newer <c>limits[]</c>/<c>spend</c> payloads decoding to
/// the same <see cref="UsageSnapshot"/> shape; and the credits/spend derivation. Mirrors the Mac
/// <c>ResetDate</c> and <c>UsageData.init(from:)</c> behavior (Services/UsageService.swift).
/// </summary>
public class UsageParsingTests
{
    // 2026-06-19T12:00:00Z as a UNIX epoch in seconds.
    private const long EpochSeconds = 1_781_870_400;
    private static readonly DateTimeOffset Expected =
        DateTimeOffset.FromUnixTimeSeconds(EpochSeconds);

    // MARK: - resets_at across forms

    [Fact]
    public void ResetsAt_ParsesIso8601_Plain()
    {
        var iso = Expected.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ");
        var doc = JsonDocument.Parse($"\"{iso}\"");
        var parsed = ResetDateParser.Parse(doc.RootElement);
        Assert.NotNull(parsed);
        Assert.Equal(Expected, parsed!.Value.ToUniversalTime());
    }

    [Fact]
    public void ResetsAt_ParsesIso8601_FractionalSeconds()
    {
        var iso = "2026-06-19T12:00:00.123Z";
        var doc = JsonDocument.Parse($"\"{iso}\"");
        var parsed = ResetDateParser.Parse(doc.RootElement);
        Assert.NotNull(parsed);
        Assert.Equal(new DateTimeOffset(2026, 6, 19, 12, 0, 0, 123, TimeSpan.Zero),
            parsed!.Value.ToUniversalTime());
    }

    [Fact]
    public void ResetsAt_ParsesIntegerEpoch_Seconds()
    {
        var doc = JsonDocument.Parse(EpochSeconds.ToString());
        var parsed = ResetDateParser.Parse(doc.RootElement);
        Assert.NotNull(parsed);
        Assert.Equal(Expected, parsed!.Value.ToUniversalTime());
    }

    [Fact]
    public void ResetsAt_ParsesIntegerEpoch_Milliseconds()
    {
        // Values >= 1e11 are treated as milliseconds (Mac dateFromEpoch cutoff).
        var millis = EpochSeconds * 1000L;
        var doc = JsonDocument.Parse(millis.ToString());
        var parsed = ResetDateParser.Parse(doc.RootElement);
        Assert.NotNull(parsed);
        Assert.Equal(Expected, parsed!.Value.ToUniversalTime());
    }

    [Fact]
    public void ResetsAt_ParsesStringEpoch()
    {
        var doc = JsonDocument.Parse($"\"{EpochSeconds}\"");
        var parsed = ResetDateParser.Parse(doc.RootElement);
        Assert.NotNull(parsed);
        Assert.Equal(Expected, parsed!.Value.ToUniversalTime());
    }

    [Fact]
    public void ResetsAt_MissingOrNull_IsNull_NotThrow()
    {
        var nullDoc = JsonDocument.Parse("null");
        Assert.Null(ResetDateParser.Parse(nullDoc.RootElement));

        // An absent field: the parser never sees a property, but ParseString of empty is null.
        Assert.Null(ResetDateParser.ParseString(null));
        Assert.Null(ResetDateParser.ParseString(""));
        Assert.Null(ResetDateParser.ParseString("   "));
    }

    [Fact]
    public void ResetsAt_OutOfRangeEpoch_IsNull()
    {
        // Below ~2001 and above ~2100 degrade to "unavailable" rather than a trap-prone date.
        Assert.Null(ResetDateParser.FromEpoch(0));
        Assert.Null(ResetDateParser.FromEpoch(5_000_000_000)); // ~2128 in seconds
        Assert.Null(ResetDateParser.FromEpoch(double.NaN));
        Assert.Null(ResetDateParser.FromEpoch(double.PositiveInfinity));
    }

    [Fact]
    public void ResetsAt_UnparseableString_IsNull_NotThrow()
    {
        var doc = JsonDocument.Parse("\"not-a-date\"");
        Assert.Null(ResetDateParser.Parse(doc.RootElement));
    }

    [Fact]
    public void Snapshot_MissingResetField_YieldsUnavailable_NeverCrashes()
    {
        // A weekly_all limit with utilization but no resets_at: snapshot still resolves, reset is
        // null ("reset times unavailable"), no exception.
        const string json = """
        {
          "limits": [
            { "kind": "session", "percent": 10 },
            { "kind": "weekly_all", "percent": 40 }
          ]
        }
        """;
        var response = UsageResponseParser.Parse(json);
        var snapshot = UsageSnapshotResolver.Resolve(response, credits: null);
        Assert.Null(snapshot.SessionResetDate);
        Assert.Null(snapshot.WeeklyResetDate);
        Assert.Equal(90, snapshot.SessionRemaining);
        Assert.Equal(60, snapshot.WeeklyRemaining);
    }

    // MARK: - Both payload shapes decode to the same snapshot

    [Fact]
    public void LegacyTier_And_LimitsShape_ResolveToSameSnapshot()
    {
        // Legacy per-tier body: session via five_hour, weekly via seven_day, per-model via
        // seven_day_opus/seven_day_sonnet.
        const string legacy = """
        {
          "five_hour":        { "utilization": 25, "resets_at": 1781870400 },
          "seven_day":        { "utilization": 40, "resets_at": 1781870400 },
          "seven_day_opus":   { "utilization": 30, "resets_at": 1781870400 },
          "seven_day_sonnet": { "utilization": 10, "resets_at": 1781870400 }
        }
        """;

        // Newer limits[] body carrying the same numbers. weekly_scoped models use a different
        // identity (model id), so we compare the value-bearing fields, not the full record.
        const string limits = """
        {
          "limits": [
            { "kind": "session",   "percent": 25, "resets_at": 1781870400 },
            { "kind": "weekly_all", "percent": 40, "resets_at": 1781870400 },
            { "kind": "weekly_scoped", "percent": 30, "resets_at": 1781870400,
              "scope": { "model": { "id": "opus-id",   "display_name": "Opus" } } },
            { "kind": "weekly_scoped", "percent": 10, "resets_at": 1781870400,
              "scope": { "model": { "id": "sonnet-id", "display_name": "Sonnet" } } }
          ]
        }
        """;

        var fromLegacy = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse(legacy), null);
        var fromLimits = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse(limits), null);

        Assert.Equal(fromLegacy.SessionRemaining, fromLimits.SessionRemaining);
        Assert.Equal(fromLegacy.WeeklyRemaining, fromLimits.WeeklyRemaining);
        Assert.Equal(75, fromLimits.SessionRemaining);
        Assert.Equal(60, fromLimits.WeeklyRemaining);
        Assert.Equal(fromLegacy.SessionResetDate, fromLimits.SessionResetDate);
        Assert.Equal(fromLegacy.WeeklyResetDate, fromLimits.WeeklyResetDate);

        // Same model display names and remaining values from either shape.
        var legacyModels = fromLegacy.ModelUsages
            .Select(m => (m.DisplayName, m.RemainingPercent)).OrderBy(t => t.DisplayName).ToList();
        var limitsModels = fromLimits.ModelUsages
            .Select(m => (m.DisplayName, m.RemainingPercent)).OrderBy(t => t.DisplayName).ToList();
        Assert.Equal(legacyModels, limitsModels);
    }

    [Fact]
    public void LimitsShape_PreferredOverLegacy_WhenBothPresent()
    {
        // When a body carries both shapes, the resolver prefers limits[] (KTD1).
        const string both = """
        {
          "five_hour": { "utilization": 99 },
          "seven_day": { "utilization": 99 },
          "limits": [
            { "kind": "session",   "percent": 25 },
            { "kind": "weekly_all", "percent": 40 }
          ]
        }
        """;
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse(both), null);
        Assert.Equal(75, snapshot.SessionRemaining); // 100-25, not 100-99
        Assert.Equal(60, snapshot.WeeklyRemaining);  // 100-40, not 100-99
    }

    [Fact]
    public void Remaining_IsClampedTo0And100()
    {
        const string json = """
        {
          "limits": [
            { "kind": "session",    "percent": 150 },
            { "kind": "weekly_all", "percent": -20 }
          ]
        }
        """;
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse(json), null);
        Assert.Equal(0, snapshot.SessionRemaining);   // clamp(100-150)
        Assert.Equal(100, snapshot.WeeklyRemaining);  // clamp(100-(-20))
    }

    [Fact]
    public void NoData_YieldsEmptyModels_AndFullRemaining()
    {
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse("{}"), null);
        Assert.Equal(100, snapshot.SessionRemaining);
        Assert.Equal(100, snapshot.WeeklyRemaining);
        Assert.Empty(snapshot.ModelUsages);
        Assert.Null(snapshot.Credits);
    }

    [Fact]
    public void WeeklyScoped_MissingDisplayNameOrPercent_HidesBar_NotFake100()
    {
        // KTD3: an absent model hides its bar rather than faking a 100% remaining bar.
        const string json = """
        {
          "limits": [
            { "kind": "weekly_scoped", "percent": 20,
              "scope": { "model": { "display_name": "Opus", "id": "opus" } } },
            { "kind": "weekly_scoped", "percent": 30 },
            { "kind": "weekly_scoped",
              "scope": { "model": { "display_name": "NoPercent" } } }
          ]
        }
        """;
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse(json), null);
        Assert.Single(snapshot.ModelUsages);
        Assert.Equal("Opus", snapshot.ModelUsages[0].DisplayName);
        Assert.Equal(80, snapshot.ModelUsages[0].RemainingPercent);
    }

    [Fact]
    public void ModelUsage_PrefersModelId_OverDisplayName_ForIdentity()
    {
        const string json = """
        {
          "limits": [
            { "kind": "weekly_scoped", "percent": 20,
              "scope": { "model": { "display_name": "Claude", "id": "model-a" } } },
            { "kind": "weekly_scoped", "percent": 30,
              "scope": { "model": { "display_name": "Claude", "id": "model-b" } } }
          ]
        }
        """;
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse(json), null);
        Assert.Equal(2, snapshot.ModelUsages.Count);
        // Two scoped limits sharing a display name do not collide because id is the identity.
        Assert.Equal(new[] { "model-a", "model-b" },
            snapshot.ModelUsages.Select(m => m.Id).OrderBy(s => s).ToArray());
    }

    // MARK: - Lenient field handling

    [Fact]
    public void MalformedFieldTypes_DegradeToNull_NotThrow()
    {
        // Wrong-typed fields must not throw; they decode to null and the snapshot still resolves.
        const string json = """
        {
          "five_hour": { "utilization": "not-a-number", "resets_at": {} },
          "spend": { "percent": "oops", "enabled": "yes" }
        }
        """;
        var response = UsageResponseParser.Parse(json);
        var snapshot = UsageSnapshotResolver.Resolve(response, null);
        // utilization unparseable -> treated as 0 used -> 100 remaining (Mac ?? 0 behavior).
        Assert.Equal(100, snapshot.SessionRemaining);
        // enabled not a real bool -> null -> disabled branch.
        Assert.NotNull(snapshot.Credits);
        Assert.Equal(CreditsStateKind.Disabled, snapshot.Credits!.StateKind);
    }

    [Fact]
    public void NumericString_Utilization_IsParsed()
    {
        // The Mac uses try? decode(Double) which does not coerce strings, but the brainstorm shows
        // the API sometimes string-wraps numerics; the lenient reader accepts a numeric string.
        const string json = """{ "seven_day": { "utilization": "40" } }""";
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse(json), null);
        Assert.Equal(60, snapshot.WeeklyRemaining);
    }

    // MARK: - Credits / spend derivation

    [Fact]
    public void Credits_EnabledSpend_ConvertsMinorToMajorOnce()
    {
        // KTD4: amount_minor / 10^exponent, done once. 1234 minor at exponent 2 = 12.34 major.
        const string json = """
        {
          "spend": {
            "enabled": true,
            "percent": 42.5,
            "used":  { "amount_minor": 1234, "currency": "USD", "exponent": 2 },
            "limit": { "amount_minor": 5000, "currency": "USD", "exponent": 2 }
          }
        }
        """;
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse(json), null);
        Assert.NotNull(snapshot.Credits);
        var c = snapshot.Credits!;
        Assert.Equal(CreditsStateKind.Enabled, c.StateKind);
        Assert.Equal(12.34, c.Spent, 3);
        Assert.Equal(50.0, c.SpendLimit!.Value, 3);
        Assert.Equal(42.5, c.SpendPercent, 3);
        Assert.Equal("USD", c.SpendCurrency);
    }

    [Fact]
    public void Credits_DisabledSpend_CarriesReason()
    {
        const string json = """
        { "spend": { "enabled": false, "disabled_reason": "paused_by_admin" } }
        """;
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse(json), null);
        Assert.NotNull(snapshot.Credits);
        Assert.Equal(CreditsStateKind.Disabled, snapshot.Credits!.StateKind);
        Assert.Equal("paused_by_admin", snapshot.Credits.DisabledReason);
    }

    [Fact]
    public void Credits_SpendPercent_IsUncapped()
    {
        // KTD7: percent can exceed 100; the value is preserved (the bar clamps at display).
        const string json = """{ "spend": { "enabled": true, "percent": 137.0 } }""";
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse(json), null);
        Assert.Equal(137.0, snapshot.Credits!.SpendPercent, 3);
    }

    [Fact]
    public void Credits_PrepaidBalance_ShownWhenPositive_Independent_OfSpend()
    {
        // No spend object, but a positive prepaid balance: balance still shows. cents/100 = major.
        var credits = new Credits { Amount = 2500, Currency = "EUR" };
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse("{}"), credits);
        Assert.NotNull(snapshot.Credits);
        Assert.Equal(CreditsStateKind.None, snapshot.Credits!.StateKind);
        Assert.Equal(25.0, snapshot.Credits.BalanceMajor!.Value, 3);
        Assert.Equal("EUR", snapshot.Credits.BalanceCurrency);
    }

    [Fact]
    public void Credits_ZeroOrNegativeBalance_NotShown()
    {
        var zero = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse("{}"),
            new Credits { Amount = 0 });
        Assert.Null(zero.Credits);

        var negative = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse("{}"),
            new Credits { Amount = -100 });
        Assert.Null(negative.Credits);
    }

    [Fact]
    public void Credits_Null_WhenNoSpendAndNoBalance()
    {
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse("{}"), null);
        Assert.Null(snapshot.Credits);
    }

    [Fact]
    public void Credits_EnabledSpend_PlusBalance_BothPresent()
    {
        const string json = """{ "spend": { "enabled": true, "percent": 10 } }""";
        var credits = new Credits { Amount = 1000, Currency = "USD" };
        var snapshot = UsageSnapshotResolver.Resolve(UsageResponseParser.Parse(json), credits);
        Assert.Equal(CreditsStateKind.Enabled, snapshot.Credits!.StateKind);
        Assert.Equal(10.0, snapshot.Credits.BalanceMajor!.Value, 3);
    }

    [Fact]
    public void Money_ToMajor_DefaultsExponentTo2()
    {
        // When exponent is absent, default to 2 (cents), matching the Mac.
        var money = new Money { AmountMinor = 999 };
        Assert.Equal(9.99, money.ToMajor(), 3);
    }
}
