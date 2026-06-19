namespace ClaudeBatteryWin.Models;

/// <summary>
/// What the tray icon and flyout should depict for the active account. The renderer (U9)
/// and the flyout view-model (U10) both switch on this. Mirrors the Mac's icon/popover
/// content states (Views/MenuBarController.swift, Views/UsagePopoverView.swift).
/// </summary>
public enum RenderState
{
    /// No account yet: prompt to sign in.
    Unauthenticated,

    /// A login WebView is open and capture is in progress.
    SigningIn,

    /// Usage fetched and current.
    Authenticated,

    /// A poll is in flight and there is no usable prior snapshot to show.
    Loading,

    /// The last successful fetch is older than the staleness threshold (660s).
    Stale,

    /// The API returned 401/403: the account needs re-authentication (R10).
    AuthFailed,

    /// A non-auth failure (network, decode, repeated 5xx) with no usable snapshot.
    Error
}
