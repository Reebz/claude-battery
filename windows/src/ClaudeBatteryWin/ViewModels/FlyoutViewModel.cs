using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Windows.Input;
using ClaudeBatteryWin.Icons;
using ClaudeBatteryWin.Models;

namespace ClaudeBatteryWin.ViewModels;

/// <summary>
/// The eight popover content states, in the exact selection order of the Mac
/// <c>UsagePopoverView.body</c> (Views/UsagePopoverView.swift). The view-model resolves one of
/// these from its inputs every time a source changes; the XAML shows the matching panel. The
/// FlyoutStateTests assert this resolution (a state-machine table test), never the rendered pixels.
///
/// Order is load-bearing, mirroring the Mac if/else cascade exactly:
/// <list type="number">
///   <item><see cref="SigningIn"/> -- login state is signing-in.</item>
///   <item><see cref="LoginError"/> -- login state is an error (carries <see cref="FlyoutViewModel.LoginErrorMessage"/>).</item>
///   <item><see cref="Unauthenticated"/> -- no active account.</item>
///   <item><see cref="ReauthRequired"/> -- no active account AND a saved account's security data
///   (DPAPI blob) could not be read (profile copy / SID change); distinct from a plain signed-out
///   user so the flyout can say WHY (U6/R4). A Windows-only addition with no Mac analog.</item>
///   <item><see cref="Authenticated"/> -- a usable usage snapshot exists.</item>
///   <item><see cref="AuthFailed"/> -- 401/403 surfaced (session expired).</item>
///   <item><see cref="Error"/> -- >= 10 consecutive hard failures with no snapshot.</item>
///   <item><see cref="Loading"/> -- a poll is in flight, no prior snapshot.</item>
/// </list>
/// The Mac also distinguishes the login-error card from the failure-error card; that is the
/// <see cref="LoginError"/> vs <see cref="Error"/> split here. The cascade names the seven Mac
/// branches (signing-in, login-error, unauthenticated, authenticated, auth-failed, failure-error,
/// loading -- the "error" the plan lists twice is login-error and failure-error) plus the
/// Windows-only <see cref="ReauthRequired"/> DPAPI-drop branch.
/// </summary>
public enum FlyoutContentState
{
    SigningIn,
    LoginError,
    Unauthenticated,
    ReauthRequired,
    Authenticated,
    AuthFailed,
    Error,
    Loading
}

/// <summary>
/// The remaining-percent color bucket, ported from the Mac <c>batteryColor(remainingPercent:)</c>
/// thresholds: clamp 0-100, then <c>&lt;20</c> red, <c>&lt;45</c> orange, else green. Returned as a
/// bucket (not a WPF brush) so the gauge/bar/model color choice is unit-testable without pumping
/// the UI; the XAML maps each bucket to a <c>DynamicResource</c> brush at the binding boundary.
/// Shares its numeric cutoffs with <see cref="DualHorizontalRenderer.BatteryColor"/> so the tray
/// icon and the flyout cannot drift apart.
/// </summary>
public enum UsageColor
{
    Red,
    Orange,
    Green,

    /// <summary>Secondary grey. The pace word uses it when there is no pace to grade.</summary>
    Muted
}

/// <summary>
/// The spend color bucket, ported verbatim from the Mac <c>spendColor(for:)</c> (the credits row):
/// <c>&gt;=80</c> red, <c>&gt;=50</c> orange, else cyan. Distinct from <see cref="UsageColor"/>
/// because spend carries the opposite semantics (high = closer to the limit = red), so a near-limit
/// credits bar reads red rather than the remaining-scale green.
/// </summary>
public enum SpendColor
{
    Cyan,
    Orange,
    Red
}

/// <summary>
/// One dial's display data (R26, R27, R51, R52).
///
/// Two rings: how much quota is left on the outside, how much of the window is left on the inside.
/// The gap between them is the pace, which is what the word underneath names. Under that, a run-out
/// estimate when there is one worth showing, and the reset countdown, which is always there.
/// </summary>
public sealed record GaugeCard
{
    public required string Title { get; init; }

    /// <summary>Quota remaining, which is what the outer ring draws and the centre label prints.</summary>
    public required double RemainingPercent { get; init; }

    /// <summary>Colour of the outer ring: the pace, with a red floor under twenty percent.</summary>
    public required UsageColor Color { get; init; }

    /// <summary>Five for the session dial, seven for the weekly one. Four and six notches are drawn:
    /// the ends of the arc are not notches.</summary>
    public required int TickCount { get; init; }

    /// <summary>How much of the window is left. Null hides the inner ring, because there is no
    /// honest way to draw an unknown one.</summary>
    public double? TimeRemainingPercent { get; init; }

    public bool HasTimeRing => TimeRemainingPercent is not null;

    /// <summary>"&lt;n&gt;%" beside the small clock in the middle. Empty when there is no time ring.</summary>
    public string TimeRemainingLabel =>
        TimeRemainingPercent is { } value ? $"{(int)Math.Round(value)}%" : string.Empty;

    /// <summary>How usage is running against the clock.</summary>
    public required PaceStatus Pace { get; init; }

    /// <summary>The pace word. Empty hides the line.</summary>
    public string PaceCaption { get; init; } = string.Empty;

    public bool HasPaceCaption => PaceCaption.Length > 0;

    /// <summary>Colour of the pace word, which shares the ring's red floor so the two agree.</summary>
    public UsageColor PaceCaptionColor { get; init; } = UsageColor.Muted;

    /// <summary>"Out in ~2h 15m", or empty when there is nothing sound to project.</summary>
    public string RunOutLine { get; init; } = string.Empty;

    public bool HasRunOutLine => RunOutLine.Length > 0;

    /// <summary>"Resets in 2h 14m", or "Reset time unavailable".</summary>
    public string Countdown { get; init; } = string.Empty;

    /// <summary>
    /// True when this dial is showing a value capped by the weekly quota rather than its own window.
    /// </summary>
    public bool IsWeeklyLimited { get; init; }

    /// <summary>
    /// The whole dial as one spoken sentence (R37). A screen reader announces each dial once instead
    /// of reading four disconnected fragments, which is why the lines themselves are hidden from it.
    /// </summary>
    public string AccessibilityLabel { get; init; } = string.Empty;

    /// "<n>%" centre label for the outer ring.
    public string PercentLabel => $"{(int)Math.Round(RemainingPercent)}%";
}

/// <summary>
/// One "All Models" bar row. Mirrors the Mac <c>ModelBar</c> + <c>modelBars(for:)</c>: the first
/// row is the synthetic "All Models" bar from the real weekly aggregate (never fabricated, KTD6),
/// followed by the per-model bars in API order. <see cref="Id"/> keeps two scoped limits that share
/// a display name (and any model literally named "All Models") as distinct keys.
/// </summary>
public sealed record ModelBarRow
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required double RemainingPercent { get; init; }
    public required UsageColor Color { get; init; }

    public string PercentLabel => $"{(int)Math.Round(RemainingPercent)}%";
}

/// <summary>
/// The Credits row display data, mirroring the Mac <c>usageCreditsSection</c> (KTD5/KTD7). The bar
/// fill carries SPEND semantics (colored by <see cref="SpendColor"/>) and is present only in the
/// enabled state; the status segment flexes/truncates while the balance is right-pinned and never
/// truncates. Detail lines (monthly limit, resets) follow only in the enabled state.
/// </summary>
public sealed record CreditsRow
{
    /// True when a credits/spend line should render at all (the snapshot carried a credits model).
    public bool HasCredits { get; init; }

    public CreditsStateKind StateKind { get; init; } = CreditsStateKind.None;

    /// Bar fill percent (spend), clamped 0-100; null leaves an empty track. Enabled state only.
    public double? BarPercent { get; init; }
    public SpendColor? BarColor { get; init; }

    /// The flexing status text ("$12.00 spent · 60% used" enabled, or the disabled reason).
    public string StatusText { get; init; } = string.Empty;
    public SpendColor StatusColor { get; init; } = SpendColor.Cyan;

    /// The right-pinned prepaid balance, already currency-formatted; null hides the balance segment.
    public string? BalanceText { get; init; }

    // Enabled-state detail lines (the Mac shows these below the combined row).
    public string? MonthlySpendLimitText { get; init; }
    public string ResetsText { get; init; } = string.Empty;
    public bool HasMonthlySpendLimit => MonthlySpendLimitText is not null;

    /// <summary>True when there is a reset date to show. Independent of whether a cap is set: credits
    /// reset on the same day either way (R33).</summary>
    public bool HasResetsText => ResetsText.Length > 0;

    public static readonly CreditsRow None = new() { HasCredits = false };
}

/// <summary>
/// One row in the account list. Mirrors the Mac <c>AccountListSection.accountRow</c>: a display
/// name, the active dot, and the underlying id so a click can switch.
/// </summary>
public sealed record AccountRow
{
    public required Guid Id { get; init; }
    public required string DisplayName { get; init; }
    public required bool IsActive { get; init; }

    /// <summary>True while this row is being renamed, which swaps its label for an edit field (R36).</summary>
    public bool IsEditing { get; init; }

    public bool IsNotEditing => !IsEditing;
}

/// <summary>
/// Observable view-model for the flyout popover (U10). It is the single state machine the borderless
/// <c>FlyoutWindow</c> binds against: it observes <see cref="UsageService"/>, <see cref="AccountStore"/>,
/// the login state, and <see cref="UpdateService"/>, and exposes a resolved <see cref="State"/> plus
/// the per-section display models the XAML renders. Mirrors the Mac <c>UsagePopoverView</c> content
/// states, color scales, gauge/bar geometry, and countdown/reset formats.
///
/// <para>
/// <b>Why a view-model and not bindings straight off the services.</b> The Mac view derived its
/// branch inline in <c>body</c>. On Windows the same derivation lives here so it is unit-testable
/// (FlyoutStateTests drives the inputs and asserts <see cref="State"/> and the section models) and
/// so the XAML stays declarative. The view-model never owns transport, polling, or auth logic; it
/// reads the already-resolved <see cref="UsageSnapshot"/> and account state and shapes them for
/// display.
/// </para>
///
/// <para>
/// <b>signing-in dismissal suppression.</b> <see cref="SuppressDismissOnDeactivate"/> is true while
/// the login state is signing-in / capturing / org-discovery, so the flyout window does not close
/// itself when focus moves to the login window (the Mac kept the popover open behind the login
/// sheet). The window code-behind reads this on Deactivated.
/// </para>
///
/// <para>
/// <b>Threading.</b> Constructed and mutated on the UI thread, like the Mac <c>@MainActor</c> view.
/// The service callbacks (<see cref="UsageService.StateChanged"/>, <see cref="AccountStore.ActiveAccountChanged"/>)
/// may arrive on a background thread; the integration layer marshals <see cref="Refresh"/> onto the
/// dispatcher. The pure resolution functions are static and side-effect-free so the tests need no
/// dispatcher.
/// </para>
/// </summary>
public sealed class FlyoutViewModel : INotifyPropertyChanged
{
    /// Session window length: 5h, consistent with the 5-tick session gauge. Verbatim Mac value.
    public const double SessionWindowSeconds = 5 * 3600;

    /// Weekly window length: 7 days. Verbatim Mac value.
    public const double WeeklyWindowSeconds = 7 * 24 * 3600;

    /// <summary>Quota notches on the Session dial. Shared with the Mac through
    /// <c>parity-constants.json</c>.</summary>
    public const int SessionTickCount = 5;

    /// <inheritdoc cref="SessionTickCount"/>
    public const int WeeklyTickCount = 7;

    private readonly Func<DateTimeOffset> _now;

    // When true, input setters skip their per-setter Refresh so a batch of inputs (App's
    // SyncViewModelFromServices sets ~10 at once) collapses to ONE Refresh on EndUpdate, instead of
    // N full PropertyChanged(null) re-evaluations (U16/#26).
    private bool _refreshSuspended;

    // The current inputs, set by the integration layer through the setters / Refresh. Defaults
    // describe a freshly launched, signed-out, never-polled app.
    private LoginState _loginState = LoginState.Idle;
    private bool _isAuthenticated;
    private bool _securityDataUnreadable;
    private UsageReading? _latestReading;
    private string _signInConfirmation = string.Empty;
    private bool _authFailed;
    private int _consecutiveFailures;
    private DateTimeOffset? _lastSuccessfulFetch;
    private IReadOnlyList<Account> _accounts = Array.Empty<Account>();
    private Guid? _activeAccountId;
    private bool _canAddAccount = true;
    private string? _availableUpdateVersion;

    public FlyoutViewModel(Func<DateTimeOffset>? now = null)
    {
        _now = now ?? (() => DateTimeOffset.UtcNow);
        SwitchAccountCommand = new RelayCommand(p =>
        {
            if (p is Guid id)
            {
                SwitchAccountRequested?.Invoke(id);
            }
        });

        BeginRenameCommand = new RelayCommand(p =>
        {
            if (p is Guid id)
            {
                BeginRename(id);
            }
        });
    }

    // MARK: - Renaming from the panel (R36)

    private Guid? _editingAccountId;

    /// <summary>
    /// Raised when a rename is committed from the panel. The integration layer calls
    /// <c>AccountStore.UpdateNickname</c>; the panel never owns the store.
    /// </summary>
    public event Action<Guid, string>? RenameAccountRequested;

    /// <summary>The command the rename affordance on a row binds to; its parameter is the row id.</summary>
    public ICommand BeginRenameCommand { get; }

    /// <summary>Puts one row into edit mode. Renaming from Settings alone meant leaving the panel to
    /// fix a label the panel is where you read it (R36).</summary>
    public void BeginRename(Guid id)
    {
        _editingAccountId = id;
        MaybeRefresh();
    }

    /// <summary>Applies a rename and leaves edit mode.</summary>
    public void CommitRename(Guid id, string name)
    {
        _editingAccountId = null;
        RenameAccountRequested?.Invoke(id, name);
        MaybeRefresh();
    }

    /// <summary>Leaves edit mode without changing anything.</summary>
    public void CancelRename()
    {
        _editingAccountId = null;
        MaybeRefresh();
    }

    // MARK: - Account switching (U15)

    /// <summary>
    /// Raised when an account row is activated from the flyout, carrying the row's account id. The
    /// integration layer subscribes and calls <c>AccountStore.SwitchTo</c> (the flyout VM never owns
    /// the store). Mirrors the Mac account list switching on tap (issue #15).
    /// </summary>
    public event Action<Guid>? SwitchAccountRequested;

    /// <summary>The command an account row binds to; its parameter is the row's <c>Id</c> (a Guid).</summary>
    public ICommand SwitchAccountCommand { get; }

    /// <summary>
    /// Run a batch of input mutations with per-setter Refresh suspended, then Refresh once. Returns an
    /// IDisposable that resumes and refreshes on Dispose, so a using-block collapses ~10 setters to a
    /// single re-evaluation (U16/#26).
    /// </summary>
    public IDisposable SuspendRefresh()
    {
        _refreshSuspended = true;
        return new RefreshScope(this);
    }

    private void MaybeRefresh()
    {
        if (!_refreshSuspended)
        {
            Refresh();
        }
    }

    private void EndSuspendAndRefresh()
    {
        _refreshSuspended = false;
        Refresh();
    }

    private sealed class RefreshScope : IDisposable
    {
        private readonly FlyoutViewModel _vm;
        private bool _done;

        public RefreshScope(FlyoutViewModel vm) => _vm = vm;

        public void Dispose()
        {
            if (_done)
            {
                return;
            }
            _done = true;
            _vm.EndSuspendAndRefresh();
        }
    }

    // MARK: - Inputs (set by the integration layer; each recomputes the derived state)

    public LoginState LoginState
    {
        get => _loginState;
        set { if (!Equals(_loginState, value)) { _loginState = value; MaybeRefresh(); } }
    }

    public bool IsAuthenticated
    {
        get => _isAuthenticated;
        set { if (_isAuthenticated != value) { _isAuthenticated = value; MaybeRefresh(); } }
    }

    /// <summary>
    /// True when at least one account was dropped at load because its DPAPI blob would not decrypt
    /// (profile copy, SID change). Latched once at startup by the integration layer, since
    /// <c>AccountStore.DroppedAccountIds</c> is cleared on each load. When set and there is no active
    /// account, the flyout shows the distinct <see cref="FlyoutContentState.ReauthRequired"/> surface
    /// instead of the plain <see cref="FlyoutContentState.Unauthenticated"/> one (U6/R4).
    /// </summary>
    public bool SecurityDataUnreadable
    {
        get => _securityDataUnreadable;
        set { if (_securityDataUnreadable != value) { _securityDataUnreadable = value; MaybeRefresh(); } }
    }

    /// <summary>
    /// The latest reading: the poll's numbers plus the conversion that applies to them. The Session
    /// dial reads its display value from here so it cannot disagree with the tray (KTD9).
    /// </summary>
    public UsageReading? LatestReading
    {
        get => _latestReading;
        set { _latestReading = value; MaybeRefresh(); }
    }

    /// <summary>The raw numbers from the latest reading, for the surfaces that need them unconverted.</summary>
    public UsageSnapshot? LatestUsage => _latestReading?.Snapshot;

    public bool AuthFailed
    {
        get => _authFailed;
        set { if (_authFailed != value) { _authFailed = value; MaybeRefresh(); } }
    }

    public int ConsecutiveFailures
    {
        get => _consecutiveFailures;
        set { if (_consecutiveFailures != value) { _consecutiveFailures = value; MaybeRefresh(); } }
    }

    public DateTimeOffset? LastSuccessfulFetch
    {
        get => _lastSuccessfulFetch;
        set
        {
            _lastSuccessfulFetch = value;
            if (!_refreshSuspended)
            {
                RaiseChanged(nameof(LastUpdatedText));
                RaiseChanged(nameof(FooterText));
            }
        }
    }

    public IReadOnlyList<Account> Accounts
    {
        get => _accounts;
        set { _accounts = value ?? Array.Empty<Account>(); MaybeRefresh(); }
    }

    public Guid? ActiveAccountId
    {
        get => _activeAccountId;
        set { _activeAccountId = value; MaybeRefresh(); }
    }

    public bool CanAddAccount
    {
        get => _canAddAccount;
        set { if (_canAddAccount != value) { _canAddAccount = value; MaybeRefresh(); } }
    }

    /// The available update version (from <see cref="UpdateService.AvailableUpdate"/>), or null when
    /// up to date / not checked. Non-null swaps the version row into the "vX available" link.
    public string? AvailableUpdateVersion
    {
        get => _availableUpdateVersion;
        set { if (_availableUpdateVersion != value) { _availableUpdateVersion = value; MaybeRefresh(); } }
    }

    // MARK: - Resolved state

    /// The resolved content state, recomputed on every input change. The window swaps panels off it.
    public FlyoutContentState State { get; private set; } = FlyoutContentState.Unauthenticated;

    /// The login-error message, non-empty only in <see cref="FlyoutContentState.LoginError"/>.
    public string LoginErrorMessage { get; private set; } = string.Empty;

    /// <summary>
    /// What the last sign-in repaired, when it repaired more than the account it signed in to (R16).
    /// Empty the rest of the time, which hides the line.
    /// </summary>
    public string SignInConfirmation
    {
        get => _signInConfirmation;
        set
        {
            if (_signInConfirmation != value)
            {
                _signInConfirmation = value;
                MaybeRefresh();
            }
        }
    }

    public bool HasSignInConfirmation => _signInConfirmation.Length > 0;

    /// <summary>
    /// True while a login is in progress (signing-in / capturing / org-discovery), so the window
    /// suppresses its Deactivated dismissal -- otherwise the signing-in spinner is lost the moment
    /// focus moves to the login window. Mirrors the Mac flag set before opening the login window and
    /// cleared on capture/cancel.
    /// </summary>
    public bool SuppressDismissOnDeactivate => _loginState.IsLoginInProgress;

    // MARK: - Authenticated-section models (null/empty outside the authenticated state)

    public GaugeCard? SessionCard { get; private set; }
    public GaugeCard? WeeklyCard { get; private set; }
    public CreditsRow Credits { get; private set; } = CreditsRow.None;

    /// True when there are per-model bars, which is what decides whether the Models card appears at
    /// all. The separate Resets card is gone: each dial carries its own countdown now (R52).
    public bool HasModelBars { get; private set; }

    public ObservableCollection<ModelBarRow> ModelBars { get; } = new();

    /// True when the multi-account list section shows (more than one account). Mac parity.
    public bool ShowAccountList { get; private set; }

    /// True when the subtle single-line "Add Account" link shows (exactly one account, slot free).
    public bool ShowAddAccountLink { get; private set; }

    public ObservableCollection<AccountRow> AccountRows { get; } = new();

    // MARK: - Version / update row

    /// True when an update is available -- the version row becomes a download link rather than the
    /// "last updated" text. Mirrors the Mac update-row branch.
    public bool HasUpdate => _availableUpdateVersion is not null;

    /// "v1.51 available - Download" link text. Empty when no update. Mac parity (the link copy).
    public string UpdateLinkText =>
        _availableUpdateVersion is { } v ? $"v{v} available - Download" : string.Empty;

    /// <summary>
    /// The footer line: the running version and how fresh the reading is (R54). The version is read
    /// from the one place the whole app reads it, so the panel, the tray menu and the About row can
    /// never disagree.
    /// </summary>
    public string FooterText
    {
        get
        {
            var version = Services.AppVersionInfo.Version;
            return version == "unknown" ? LastUpdatedText : $"v{version} \u00b7 {LastUpdatedText}";
        }
    }

    /// "Updated just now" / "Updated N minutes ago" / "Not yet updated". Verbatim Mac copy and
    /// thresholds (Views/UsagePopoverView.swift <c>lastUpdatedText</c>).
    public string LastUpdatedText
    {
        get
        {
            if (_lastSuccessfulFetch is not { } last)
            {
                return "Not yet updated";
            }
            var seconds = (int)(_now() - last).TotalSeconds;
            if (seconds < 60)
            {
                return "Updated just now";
            }
            var minutes = seconds / 60;
            return minutes == 1 ? "Updated 1 minute ago" : $"Updated {minutes} minutes ago";
        }
    }

    /// The Windows analog of the Mac "Right-click the battery icon in your menu bar for Settings."
    /// hint -- Windows has a tray icon, not a menu bar.
    public const string SettingsHint = "Right-click the tray icon for Settings.";

    /// <summary>
    /// The distinct re-auth detail copy shown when a saved account's security data could not be read
    /// on this PC (a DPAPI drop: profile copy / SID change), so it is not mistaken for the
    /// session-restore bug (U6/R4). The flyout's ReauthRequired panel binds this via <c>x:Static</c>,
    /// so the rendered copy and the tested copy are one string.
    /// </summary>
    public const string ReauthRequiredHint =
        "Your saved security data could not be read on this PC. Please sign in again.";

    // MARK: - Re-resolution

    /// <summary>
    /// Recompute <see cref="State"/> and every section model from the current inputs and raise
    /// change notifications. The integration layer calls this when a service event arrives (already
    /// marshaled onto the UI thread); the setters call it on each input change.
    /// </summary>
    public void Refresh()
    {
        State = ResolveState(_loginState, _isAuthenticated, _latestReading?.Snapshot, _authFailed, _consecutiveFailures, _securityDataUnreadable);
        LoginErrorMessage = _loginState.Kind == LoginStateKind.Error ? _loginState.Message ?? string.Empty : string.Empty;

        if (State == FlyoutContentState.Authenticated && _latestReading is { } reading)
        {
            BuildAuthenticatedSections(reading);
        }
        else
        {
            ClearAuthenticatedSections();
        }

        RaiseChanged(null); // null property name => "all properties changed", per WPF convention.
    }

    private void BuildAuthenticatedSections(UsageReading reading)
    {
        var usage = reading.Snapshot;
        var now = _now();

        // The dial shows the display value: when the week converts to less session than the session
        // window itself has left, the week is what is actually stopping the user (R10, R11). Pace and
        // the run-out still read the raw session value, which is the true five-hour window (KTD9).
        var sessionPace = DialForecast.SessionPace(reading, now);
        SessionCard = MakeGaugeCard(
            title: "Session",
            remaining: reading.SessionDisplayRemaining,
            rawRemaining: usage.SessionRemaining,
            resetsAt: usage.SessionResetDate,
            windowSeconds: SessionWindowSeconds,
            tickCount: SessionTickCount,
            pace: sessionPace,
            isWeeklyLimited: reading.IsSessionWeeklyLimited,
            now: now);

        WeeklyCard = MakeGaugeCard(
            title: "Weekly",
            remaining: usage.WeeklyRemaining,
            rawRemaining: usage.WeeklyRemaining,
            resetsAt: usage.WeeklyResetDate,
            windowSeconds: WeeklyWindowSeconds,
            tickCount: WeeklyTickCount,
            pace: DialForecast.Pace(usage.WeeklyRemaining, usage.WeeklyResetDate, WeeklyWindowSeconds, now),
            isWeeklyLimited: false,
            now: now);

        Credits = MakeCreditsRow(usage.Credits, now);

        // Model bars: the synthetic "All Models" row (real weekly aggregate, never fabricated)
        // followed by the per-model bars in order. The Models card is omitted entirely and Resets
        // spans full width when there are no per-model limits (KTD3) -- so HasModelBars gates on the
        // raw per-model list, NOT on the always-present "All Models" row.
        HasModelBars = usage.ModelUsages.Count > 0;
        ModelBars.Clear();
        if (HasModelBars)
        {
            foreach (var bar in ModelBarRows(usage))
            {
                ModelBars.Add(bar);
            }
        }

        // Account list visibility mirrors the Mac: the list shows with >1 account; the subtle link
        // shows with exactly 1 account and a free slot.
        ShowAccountList = _accounts.Count > 1;
        ShowAddAccountLink = _accounts.Count == 1 && _canAddAccount;
        AccountRows.Clear();
        if (ShowAccountList)
        {
            foreach (var account in _accounts)
            {
                AccountRows.Add(new AccountRow
                {
                    Id = account.Id,
                    // Two organizations of one login share an address, so the rows would otherwise
                    // be two identical lines (R20).
                    DisplayName = Services.AccountStore.DisambiguatedName(account, _accounts),
                    IsActive = account.Id == _activeAccountId,
                    IsEditing = account.Id == _editingAccountId,
                });
            }
        }
    }

    private void ClearAuthenticatedSections()
    {
        SessionCard = null;
        WeeklyCard = null;
        Credits = CreditsRow.None;
        HasModelBars = false;
        ModelBars.Clear();
        ShowAccountList = false;
        ShowAddAccountLink = false;
        AccountRows.Clear();
    }

    // MARK: - Pure resolution (static, side-effect-free -- the FlyoutStateTests target these)

    /// <summary>
    /// Resolve the content state from the inputs, in the exact Mac if/else cascade order
    /// (Views/UsagePopoverView.swift body). Pure and static so the state table is testable without
    /// constructing the view-model or pumping the UI.
    /// </summary>
    public static FlyoutContentState ResolveState(
        LoginState loginState,
        bool isAuthenticated,
        UsageSnapshot? latestUsage,
        bool authFailed,
        int consecutiveFailures,
        bool securityDataUnreadable = false)
    {
        // 1. login in progress (signing-in / capturing / org-discovery / picker) wins over everything,
        // like the Mac. Keys on the SAME predicate as SuppressDismissOnDeactivate so the flyout cannot
        // suppress its dismissal while showing a non-signing-in panel during org-discovery/picker.
        if (loginState.IsLoginInProgress)
        {
            return FlyoutContentState.SigningIn;
        }
        // 2. login error.
        if (loginState.Kind == LoginStateKind.Error)
        {
            return FlyoutContentState.LoginError;
        }
        // 2b. security data unreadable + no active account: a DPAPI drop (profile copy / SID change),
        // distinct from a plain signed-out user so the flyout can say WHY re-auth is needed (U6/R4).
        // Ordered BEFORE the Unauthenticated arm; an authenticated survivor (a second account that
        // loaded fine) is isAuthenticated and never reaches here.
        if (securityDataUnreadable && !isAuthenticated)
        {
            return FlyoutContentState.ReauthRequired;
        }
        // 3. unauthenticated.
        if (!isAuthenticated)
        {
            return FlyoutContentState.Unauthenticated;
        }
        // 4. authenticated (a usable snapshot exists).
        if (latestUsage is not null)
        {
            return FlyoutContentState.Authenticated;
        }
        // 5. auth failed (401/403, no snapshot).
        if (authFailed)
        {
            return FlyoutContentState.AuthFailed;
        }
        // 6. failure error (>= 10 consecutive hard failures, no snapshot).
        if (consecutiveFailures >= 10)
        {
            return FlyoutContentState.Error;
        }
        // 7. loading (a poll is in flight, nothing yet).
        return FlyoutContentState.Loading;
    }

    /// <summary>
    /// Remaining-percent color bucket. Ports the Mac <c>batteryColor</c> thresholds exactly (clamp
    /// 0-100; <c>&lt;20</c> red, <c>&lt;45</c> orange, else green) and routes through the same
    /// numeric cutoffs as <see cref="DualHorizontalRenderer.BatteryColor"/> via a shared assertion in
    /// the renderer; kept as an enum so the bucket is testable without WPF brushes.
    /// </summary>
    public static UsageColor RemainingColor(double remainingPercent)
    {
        var clamped = Math.Max(0, Math.Min(100, remainingPercent));
        if (clamped < 20)
        {
            return UsageColor.Red;
        }
        if (clamped < 45)
        {
            return UsageColor.Orange;
        }
        return UsageColor.Green;
    }

    /// <summary>
    /// Spend color bucket, ported verbatim from the Mac <c>spendColor(for:)</c>: <c>&gt;=80</c> red,
    /// <c>&gt;=50</c> orange, else cyan. Note this is NOT clamped (spend percent is uncapped, KTD7):
    /// an over-limit 120% still maps to red, matching the Mac.
    /// </summary>
    public static SpendColor SpendColorFor(double percent)
    {
        if (percent >= 80)
        {
            return SpendColor.Red;
        }
        if (percent >= 50)
        {
            return SpendColor.Orange;
        }
        return SpendColor.Cyan;
    }

    /// <summary>
    /// Time remaining in the window as a percent (counts down 100 -> 0), clamped 0-100. The API
    /// supplies only <c>resetsAt</c> (the window end); the start is derived as
    /// <c>resetsAt - window</c> (KTD10). Returns null when <c>resetsAt</c> is null or there is no
    /// positive, finite, in-range countdown, so callers omit the bar (KTD4). Verbatim port of the
    /// Mac <c>timeRemainingPercent</c>.
    /// </summary>
    public static double? TimeRemainingPercent(DateTimeOffset? resetsAt, double windowSeconds, DateTimeOffset now)
    {
        if (resetsAt is not { } reset)
        {
            return null;
        }
        var remaining = CountdownFormat.RemainingSeconds(reset, now);
        if (remaining is null)
        {
            return null;
        }
        var percent = remaining.Value / windowSeconds * 100;
        return Math.Max(0, Math.Min(100, percent));
    }


    /// <summary>
    /// Assembles one dial: the two ring values, the pace word and its colour, the run-out line, the
    /// countdown, and the sentence a screen reader says. Pure and static so every dial's contents can
    /// be checked without a window.
    /// </summary>
    public static GaugeCard MakeGaugeCard(
        string title,
        double remaining,
        double rawRemaining,
        DateTimeOffset? resetsAt,
        double windowSeconds,
        int tickCount,
        PaceStatus pace,
        bool isWeeklyLimited,
        DateTimeOffset now)
    {
        var timeRemaining = DialForecast.TimeRemainingPercent(resetsAt, windowSeconds, now);
        var lines = DialForecast.DialLines(pace, rawRemaining, resetsAt, windowSeconds, now);

        return new GaugeCard
        {
            Title = title,
            RemainingPercent = remaining,
            Color = DialForecast.RingColor(remaining, pace),
            TickCount = tickCount,
            TimeRemainingPercent = timeRemaining,
            Pace = pace,
            PaceCaption = lines.Caption ?? string.Empty,
            PaceCaptionColor = DialForecast.PaceCaptionColor(remaining, pace),
            RunOutLine = lines.RunOut ?? string.Empty,
            Countdown = lines.Countdown,
            IsWeeklyLimited = isWeeklyLimited,
            AccessibilityLabel = DialForecast.GaugeAccessibilityLabel(title, remaining, timeRemaining, pace, lines),
        };
    }

    /// <summary>
    /// The "All Models" bar (real weekly aggregate, never fabricated, KTD6) followed by the
    /// per-model bars in order. Mirrors the Mac <c>modelBars(for:)</c>; the synthetic row's id is the
    /// reserved <c>__all_models__</c> so a real model named "All Models" cannot collide with it.
    /// </summary>
    public static IReadOnlyList<ModelBarRow> ModelBarRows(UsageSnapshot usage)
    {
        var rows = new List<ModelBarRow>(usage.ModelUsages.Count + 1)
        {
            new()
            {
                Id = "__all_models__",
                Name = "All Models",
                RemainingPercent = usage.WeeklyRemaining,
                Color = RemainingColor(usage.WeeklyRemaining),
            },
        };
        foreach (var model in usage.ModelUsages)
        {
            rows.Add(new ModelBarRow
            {
                Id = model.Id,
                Name = model.DisplayName,
                RemainingPercent = model.RemainingPercent,
                Color = RemainingColor(model.RemainingPercent),
            });
        }
        return rows;
    }

    /// <summary>
    /// The long-form popover countdown, ported verbatim from the Mac <c>formatCountdown</c>: routes
    /// through the shared guarded core (so a past/non-finite/absurd date is safe) and formats as
    /// <c>"%dd %02dh"</c> when days remain, <c>"%dh %02dm"</c> when hours remain, else
    /// <c>"%dm %02ds"</c>. A null countdown yields the Mac fallback "00m 00s".
    /// </summary>
    public static string FormatCountdown(DateTimeOffset date, DateTimeOffset now)
    {
        var remaining = CountdownFormat.RemainingSeconds(date, now);
        if (remaining is null)
        {
            return "00m 00s";
        }

        var total = (long)remaining.Value;
        var d = total / 86400;
        var h = (total % 86400) / 3600;
        var m = (total % 3600) / 60;
        var s = total % 60;

        if (d > 0)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0}d {1:00}h", d, h);
        }
        if (h > 0)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0}h {1:00}m", h, m);
        }
        return string.Format(CultureInfo.InvariantCulture, "{0}m {1:00}s", m, s);
    }

    /// <summary>
    /// The Credits row, mirroring the Mac <c>usageCreditsSection</c> (KTD5/KTD7). The bar fill shows
    /// spend percent only in the enabled state and is colored by the spend scale; the status segment
    /// shows the spend line (enabled) or the disabled reason; the balance is currency-formatted and
    /// right-pinned. Enabled adds the monthly-limit + resets detail lines.
    /// </summary>
    public static CreditsRow MakeCreditsRow(UsageCredits? credits, DateTimeOffset now)
    {
        if (credits is null)
        {
            return CreditsRow.None;
        }

        string? balanceText = null;
        if (credits.BalanceMajor is { } balance)
        {
            balanceText = FormatCurrency(balance, credits.BalanceCurrency);
        }

        switch (credits.StateKind)
        {
            case CreditsStateKind.Enabled:
            {
                var statusText = UsageCreditsEnabledStatus(
                    FormatCurrency(credits.Spent, credits.SpendCurrency), credits.SpendPercent);
                var resetDate = credits.StateResetDate ?? FirstOfNextMonth(now);
                return new CreditsRow
                {
                    HasCredits = true,
                    StateKind = CreditsStateKind.Enabled,
                    BarPercent = Math.Max(0, Math.Min(100, credits.SpendPercent)),
                    BarColor = SpendColorFor(credits.SpendPercent),
                    StatusText = statusText,
                    StatusColor = SpendColorFor(credits.SpendPercent),
                    BalanceText = balanceText,
                    MonthlySpendLimitText = credits.SpendLimit is { } limit
                        ? FormatCurrency(limit, credits.SpendCurrency)
                        : null,
                    ResetsText = ShortDate(resetDate),
                };
            }

            case CreditsStateKind.Disabled:
                return new CreditsRow
                {
                    HasCredits = true,
                    StateKind = CreditsStateKind.Disabled,
                    BarPercent = null, // empty track in the disabled state
                    BarColor = null,
                    StatusText = UsageCreditsDisabledText(credits.DisabledReason ?? "disabled", credits.StateResetDate),
                    StatusColor = SpendColor.Cyan, // disabled status uses the muted label, not a spend color
                    BalanceText = balanceText,
                };

            default: // None: balance-only (no spend object, positive prepaid balance).
                return new CreditsRow
                {
                    HasCredits = true,
                    StateKind = CreditsStateKind.None,
                    BarPercent = null,
                    BarColor = null,
                    StatusText = string.Empty,
                    BalanceText = balanceText,
                };
        }
    }

    /// <summary>
    /// Enabled-credits status text, e.g. "$12.00 spent · 60% used". <paramref name="spentFormatted"/>
    /// is pre-formatted; <paramref name="percent"/> is uncapped (KTD7) and rounded for display.
    /// Verbatim port of the Mac <c>usageCreditsEnabledStatus</c>.
    /// </summary>
    public static string UsageCreditsEnabledStatus(string spentFormatted, double percent)
        => $"{spentFormatted} spent · {(int)Math.Round(percent)}% used";

    /// <summary>
    /// Maps a <c>spend.disabled_reason</c> to human text. <c>org_level_disabled_until</c> means the
    /// monthly spend limit was reached and credits pause until the next cycle. Verbatim port of the
    /// Mac <c>usageCreditsDisabledText</c>.
    /// </summary>
    public static string UsageCreditsDisabledText(string reason, DateTimeOffset? resetDate)
    {
        var baseText = reason == "org_level_disabled_until" ? "Paused - monthly limit reached" : "Paused";
        return resetDate is { } d ? $"{baseText}, resets {ShortDate(d)}" : baseText;
    }

    /// <summary>
    /// First day of the month following <paramref name="date"/> -- the provisional monthly-credits
    /// reset used for display until a credits-enabled capture confirms the real field (A3). Verbatim
    /// port of the Mac <c>firstOfNextMonth</c>.
    /// </summary>
    public static DateTimeOffset FirstOfNextMonth(DateTimeOffset date)
    {
        var local = date.LocalDateTime;
        var startOfMonth = new DateTime(local.Year, local.Month, 1, 0, 0, 0, DateTimeKind.Local);
        return new DateTimeOffset(startOfMonth.AddMonths(1));
    }

    /// <summary>
    /// A date in the user's own format (R34). A reader in Britain or Germany expects the day before
    /// the month; printing the US order at them is a small thing that reads as wrong every time.
    /// </summary>
    public static string ShortDate(DateTimeOffset date)
        => date.LocalDateTime.ToString("d", CultureInfo.CurrentCulture);

    /// <summary>
    /// Currency-aware formatting. Falls back to USD when the code is missing/empty, matching the Mac
    /// (KTD6); always two fraction digits. Uses the .NET currency symbol for the given ISO code under
    /// the current UI culture so a non-USD account does not render under a US locale's "$".
    /// </summary>
    public static string FormatCurrency(double value, string? code)
    {
        var resolved = string.IsNullOrEmpty(code) ? "USD" : code!;

        // The amount's own currency decides the symbol; the user's region decides everything else -
        // where the symbol sits, which separators group the digits (R34, KTD14). Formatting an
        // Australian balance with a German user's grouping is right; forcing German euros on it is
        // not.
        var format = (NumberFormatInfo)CultureInfo.CurrentCulture.NumberFormat.Clone();
        format.CurrencySymbol = CurrencySymbol(resolved);
        format.CurrencyDecimalDigits = 2;
        return value.ToString("C", format);
    }

    /// <summary>
    /// The symbol for an ISO currency code, taken from whichever region publishes it, so a code the
    /// app has never seen still prints its real symbol rather than the bare letters.
    /// </summary>
    internal static string CurrencySymbol(string isoCode)
    {
        var upper = isoCode.ToUpperInvariant();
        if (SymbolCache.TryGetValue(upper, out var cached))
        {
            return cached;
        }

        var symbol = upper switch
        {
            "USD" => "$",
            "AUD" => "A$",
            "CAD" => "C$",
            "GBP" => "£",
            "EUR" => "€",
            "JPY" => "¥",
            _ => LookUpSymbol(upper) ?? upper + " ",
        };

        SymbolCache[upper] = symbol;
        return symbol;
    }

    private static readonly Dictionary<string, string> SymbolCache = new(StringComparer.Ordinal);

    private static string? LookUpSymbol(string isoCode)
    {
        try
        {
            foreach (var culture in CultureInfo.GetCultures(CultureTypes.SpecificCultures))
            {
                var region = new RegionInfo(culture.Name);
                if (string.Equals(region.ISOCurrencySymbol, isoCode, StringComparison.OrdinalIgnoreCase))
                {
                    return region.CurrencySymbol;
                }
            }
        }
        catch (Exception ex) when (ex is ArgumentException or CultureNotFoundException)
        {
        }
        return null;
    }

    // MARK: - INotifyPropertyChanged

    public event PropertyChangedEventHandler? PropertyChanged;

    private void RaiseChanged([CallerMemberName] string? propertyName = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

/// <summary>
/// Minimal always-executable <see cref="ICommand"/> for view-model commands (the flyout's only
/// command surface so far is the account-row switch, U15). Kept here rather than a Commands/ folder
/// until a second command needs it.
/// </summary>
public sealed class RelayCommand : ICommand
{
    private readonly Action<object?> _execute;

    public RelayCommand(Action<object?> execute) => _execute = execute ?? throw new ArgumentNullException(nameof(execute));

    public bool CanExecute(object? parameter) => true;

    public void Execute(object? parameter) => _execute(parameter);

    // No dynamic CanExecute, so the event is a no-op (satisfies the interface without WPF requery).
    public event EventHandler? CanExecuteChanged
    {
        add { }
        remove { }
    }
}
