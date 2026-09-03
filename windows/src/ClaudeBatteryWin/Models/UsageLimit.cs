namespace ClaudeBatteryWin.Models;

/// <summary>
/// One entry in the newer <c>/usage</c> <c>limits[]</c> array. Mirrors the Mac
/// <c>UsageLimit</c> (Services/UsageService.swift). <see cref="Kind"/> distinguishes
/// <c>session</c>, <c>weekly_all</c>, and <c>weekly_scoped</c> (per-model) windows;
/// <c>scope.model.display_name</c> labels a per-model bar.
///
/// Every field is optional/lenient so a shape drift degrades to null rather than throwing the
/// whole <c>/usage</c> decode (KTD1). The parsing layer (U4) is responsible for tolerant
/// decode; this record is the contract for the decoded result.
/// </summary>
public sealed record UsageLimit
{
    public string? Kind { get; init; }
    public string? Group { get; init; }
    public double? Percent { get; init; }
    public string? Severity { get; init; }

    /// Tolerantly parsed across ISO8601 (with/without fractional seconds), UNIX epoch as a
    /// number, and epoch as a numeric string (issue #23, KTD2). Null when absent or unparseable.
    public DateTimeOffset? ResetsAt { get; init; }

    public LimitScope? Scope { get; init; }
    public bool? IsActive { get; init; }
}

/// <summary>Scope of a <see cref="UsageLimit"/>. Mirrors the Mac <c>LimitScope</c>.</summary>
public sealed record LimitScope
{
    public ModelScope? Model { get; init; }
    public string? Surface { get; init; }
}

/// <summary>A model reference inside a <see cref="LimitScope"/>. Mirrors the Mac <c>ModelScope</c>.</summary>
public sealed record ModelScope
{
    public string? Id { get; init; }
    public string? DisplayName { get; init; }
}
