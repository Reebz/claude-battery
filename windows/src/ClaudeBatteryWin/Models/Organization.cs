namespace ClaudeBatteryWin.Models;

/// <summary>
/// One claude.ai organization, as returned by <c>GET /api/organizations</c>. Mirrors the Mac
/// <c>Organization</c> struct (Services/AuthManager.swift). Org discovery (U7) must never
/// hardcode <c>orgs[0]</c> (the Mac multi-org 100%/100% bug): one org auto-selects, multiple
/// present a picker.
///
/// The JSON uses snake_case for <c>billing_type</c> and <c>email_address</c>; the transport
/// (U7) maps those, so the property names here are the C# canonical form.
/// </summary>
public sealed record Organization
{
    /// Organization UUID; persisted as <see cref="Account.OrganizationId"/>.
    public required string Uuid { get; init; }

    public string? Name { get; init; }

    /// JSON key <c>billing_type</c>.
    public string? BillingType { get; init; }

    /// JSON key <c>email_address</c>.
    public string? EmailAddress { get; init; }

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
