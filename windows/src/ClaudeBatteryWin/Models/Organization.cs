using System.Text.Json.Serialization;

namespace ClaudeBatteryWin.Models;

/// <summary>
/// One claude.ai organization, as returned by <c>GET /api/organizations</c>. Mirrors the Mac
/// <c>Organization</c> struct (Services/AuthManager.swift). Org discovery (U7) must never
/// hardcode <c>orgs[0]</c> (the Mac multi-org 100%/100% bug): one org auto-selects, multiple
/// present a picker.
///
/// The JSON uses snake_case for <c>billing_type</c>, <c>email_address</c> and
/// <c>rate_limit_tier</c>; the transport (U7) maps those, so the property names here are the C#
/// canonical form.
///
/// Every optional field is read through <see cref="TolerantJsonConverter{T}"/>: a field that arrives
/// in an unexpected shape reads as absent instead of failing the whole response and turning a
/// sign-in into a connection error (R15, KTD11). Only <see cref="Uuid"/> is strict, because an
/// organization with no id cannot be stored or polled.
/// </summary>
public sealed record Organization
{
    /// Organization UUID; persisted as <see cref="Account.OrganizationId"/>.
    public required string Uuid { get; init; }

    [JsonConverter(typeof(TolerantJsonConverter<string>))]
    public string? Name { get; init; }

    /// JSON key <c>billing_type</c>.
    [JsonConverter(typeof(TolerantJsonConverter<string>))]
    public string? BillingType { get; init; }

    /// JSON key <c>email_address</c>.
    [JsonConverter(typeof(TolerantJsonConverter<string>))]
    public string? EmailAddress { get; init; }

    /// <summary>
    /// JSON key <c>rate_limit_tier</c>. Which plan this organization is on, which is what makes the
    /// weekly-to-session conversion possible (R9). Null means the app will not guess: the Session
    /// dial shows the true session number instead.
    /// </summary>
    [JsonConverter(typeof(TolerantJsonConverter<string>))]
    public string? RateLimitTier { get; init; }

    /// <summary>
    /// Plan capabilities, carried for the diagnostics record only. Nothing in the dial or conversion
    /// logic reads it.
    /// </summary>
    [JsonConverter(typeof(TolerantJsonConverter<List<string>>))]
    public List<string>? Capabilities { get; init; }

    /// <summary>
    /// Picker label. Mirrors the Mac <c>displayName</c>: a sanitized name (newlines and
    /// LTR/RTL marks stripped, capped at 100 chars) when present, else the capitalized billing
    /// type, else the literal "Organization".
    /// </summary>
    public string DisplayName
    {
        get
        {
            if (!string.IsNullOrEmpty(Name))
            {
                var sanitized = new string(Name
                    .Where(c => c != '\n' && c != '\r' && c != '‏' && c != '‎')
                    .ToArray());
                return sanitized.Length > 100 ? sanitized[..100] : sanitized;
            }

            if (!string.IsNullOrEmpty(BillingType))
            {
                return char.ToUpperInvariant(BillingType[0]) + BillingType[1..];
            }

            return "Organization";
        }
    }
}
