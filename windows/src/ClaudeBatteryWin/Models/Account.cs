namespace ClaudeBatteryWin.Models;

/// <summary>
/// A signed-in claude.ai account. Mirrors the Mac <c>Account</c> struct
/// (Services/StorageService.swift) field-for-field. The AccountStore holds up to
/// <see cref="Services.AccountStore.MaxAccounts"/> of them, with organization-id uniqueness
/// enforced on add.
///
/// Persistence differs from the Mac: <see cref="SessionKey"/> and <see cref="AllCookieHeader"/>
/// are DPAPI-encrypted at rest (U5), not stored in plaintext. The model itself carries the
/// cleartext values in memory; the SecretStore handles the on-disk encryption boundary.
///
/// Default values match the Mac initializer: notification threshold 20.0, did-notify false.
/// </summary>
public sealed record Account
{
    public Guid Id { get; init; } = Guid.NewGuid();

    /// Account email, used as the default display name. May be a placeholder like "Account 1"
    /// for migrated single-account installs.
    public required string Email { get; init; }

    /// The HttpOnly <c>sessionKey</c> cookie value. DPAPI-encrypted at rest.
    public required string SessionKey { get; init; }

    /// The claude.ai organization UUID this account monitors. Unique across accounts.
    public required string OrganizationId { get; init; }

    /// Optional user-chosen nickname (trimmed, max 30 chars). Null falls back to <see cref="Email"/>.
    public string? Nickname { get; init; }

    /// <summary>
    /// The WebView2 session User-Agent captured at login (<c>AuthManager.CapturedUserAgent</c>),
    /// seeded into the cold-start polling transport on restore so the poll's UA matches the login
    /// session's verbatim (a Cloudflare necessity). NON-SECRET: a User-Agent is a public request
    /// header every browser echoes, so it rides in plaintext <c>accounts.json</c> metadata, NOT the
    /// DPAPI blob (it is not added to <see cref="SessionKey"/>/<see cref="AllCookieHeader"/>). Null
    /// for accounts persisted before this field existed; those fall back to the app's
    /// <c>DefaultUserAgent</c> until the next login captures and persists a real UA.
    /// </summary>
    public string? UserAgent { get; init; }

    public DateTimeOffset AddedDate { get; init; } = DateTimeOffset.UtcNow;

    /// Weekly-remaining percentage below which a low-usage toast fires (R19). Default 20.
    public double NotificationThreshold { get; init; } = 20.0;

    /// Dedup latch for the low-usage notification. Set on confirmed delivery, cleared when
    /// remaining climbs back to/above the threshold (U11).
    public bool DidNotifyBelowThreshold { get; init; }

    /// <summary>
    /// Full <c>.claude.ai</c> Cookie header captured from the login WebView at login time.
    /// Format: "name1=value1; name2=value2; ...". Primes the shared cookie container when this
    /// account becomes active, so authenticated API requests carry the full cookie set
    /// (including Cloudflare <c>__cf_bm</c>) rather than <see cref="SessionKey"/> alone.
    /// Null for accounts with no captured header; those fall back to sessionKey-only.
    /// DPAPI-encrypted at rest.
    /// </summary>
    public string? AllCookieHeader { get; init; }

    /// <summary>
    /// The organization's own name, captured at sign-in. What tells two organizations of the same
    /// account apart in every list that shows them (R20). Null for accounts stored before this
    /// existed, and for an organization that publishes no name.
    /// </summary>
    public string? OrganizationName { get; init; }

    /// <summary>
    /// Which plan this organization is on, from <c>rate_limit_tier</c> on the organizations response,
    /// refreshed on every sign-in and re-authentication (R9). This is what makes the weekly-to-session
    /// conversion possible; null means the app shows the true session number rather than guessing.
    /// </summary>
    public string? RateLimitTier { get; init; }

    /// <summary>Plan capabilities, carried for the diagnostics record. Nothing in the dial reads it.</summary>
    public IReadOnlyList<string>? Capabilities { get; init; }

    /// <summary>How this organization pays, carried for the diagnostics record. It cannot identify a
    /// plan on its own, since two plans can share a payment method.</summary>
    public string? BillingType { get; init; }

    /// <summary>When the plan fields above were last refreshed.</summary>
    public DateTimeOffset? PlanUpdatedAt { get; init; }

    /// <summary>
    /// What this account has learned about its own weekly-to-session conversion (R13). Null until the
    /// first poll folds a reading in, and cleared when the stored plan changes from one known plan to
    /// a different one, because a measurement taken on the old plan says nothing about the new one.
    /// </summary>
    public RatioMeasurement? RatioMeasurement { get; init; }

    /// What shows in the account list and notifications: the nickname when set, else the email.
    public string DisplayName => Nickname ?? Email;
}
