namespace ClaudeBatteryWin.Models;

/// <summary>
/// The login flow state machine (U6/U7). Mirrors the Mac <c>LoginState</c> enum in
/// Services/AuthManager.swift, kept as a discriminated kind plus an optional error message
/// rather than a Swift associated-value enum (C# records carry the payload).
///
/// The login window only tears down after org discovery succeeds; every failure edge moves
/// to <see cref="Error"/> and resets the capture guard. A guard left set once caused a
/// permanent re-auth lockout on macOS.
/// </summary>
public enum LoginStateKind
{
    Idle,
    SigningIn,
    Capturing,
    OrgDiscovery,
    Picker,
    Active,
    Error
}

/// <summary>
/// Login state with an optional human-readable error. <see cref="Message"/> is non-null only
/// when <see cref="Kind"/> is <see cref="LoginStateKind.Error"/>.
/// </summary>
public sealed record LoginState(LoginStateKind Kind, string? Message = null)
{
    public static readonly LoginState Idle = new(LoginStateKind.Idle);
    public static readonly LoginState SigningIn = new(LoginStateKind.SigningIn);
    public static readonly LoginState Capturing = new(LoginStateKind.Capturing);
    public static readonly LoginState OrgDiscovery = new(LoginStateKind.OrgDiscovery);
    public static readonly LoginState Picker = new(LoginStateKind.Picker);
    public static readonly LoginState Active = new(LoginStateKind.Active);

    public static LoginState ErrorWith(string message) => new(LoginStateKind.Error, message);

    /// True only in the error state. The capture funnel checks this so a cancelled or failed
    /// login cannot auto-recapture the still-present session cookie while an error card shows.
    public bool IsError => Kind == LoginStateKind.Error;
}
