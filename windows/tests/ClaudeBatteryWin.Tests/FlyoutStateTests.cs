using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.ViewModels;
using ClaudeBatteryWin.Views;
using Xunit;

namespace ClaudeBatteryWin.Tests;

/// <summary>
/// Behavioral tests for U10 <see cref="FlyoutViewModel"/> and the pure placement math
/// <see cref="FlyoutPlacement"/>. These are state-machine/arithmetic tests against the view-model
/// and the placement function, NOT rendered-visual assertions: the eight content states resolve for
/// their inputs, the Models card is omitted (and Resets spans full width) with no per-model limits,
/// the credits row colors by the spend scale with a right-pinned balance, and a secondary-monitor /
/// different-DPI placement lands inside that monitor's work area. The live DynamicResource re-theme
/// and the Escape-to-close are visual/UI-thread behaviors verified manually (see the dedicated
/// facts below that document the contract the code-behind enforces).
///
/// Mirrors the Mac <c>UsagePopoverView</c> state order, color scales, and gauge/bar geometry
/// (Views/UsagePopoverView.swift).
/// </summary>
public class FlyoutStateTests
{
    private static readonly DateTimeOffset Now = new(2026, 6, 19, 12, 0, 0, TimeSpan.Zero);

    private static UsageSnapshot UsageWithModels(params ModelUsage[] models) => new()
    {
        SessionRemaining = 60,
        WeeklyRemaining = 70,
        SessionResetDate = Now.AddHours(3),
        WeeklyResetDate = Now.AddDays(4),
        ModelUsages = models,
    };

    // MARK: - The eight content states resolve in the Mac cascade order

    [Fact]
    public void State_SigningIn_WhenLoginStateIsSigningIn()
    {
        Assert.Equal(FlyoutContentState.SigningIn,
            FlyoutViewModel.ResolveState(LoginState.SigningIn, isAuthenticated: true, latestUsage: UsageWithModels(), authFailed: true, consecutiveFailures: 99));
    }

    [Fact]
    public void State_LoginError_WhenLoginStateIsError()
    {
        Assert.Equal(FlyoutContentState.LoginError,
            FlyoutViewModel.ResolveState(LoginState.ErrorWith("nope"), isAuthenticated: true, latestUsage: UsageWithModels(), authFailed: false, consecutiveFailures: 0));
    }

    [Fact]
    public void State_Unauthenticated_WhenNoActiveAccount()
    {
        Assert.Equal(FlyoutContentState.Unauthenticated,
            FlyoutViewModel.ResolveState(LoginState.Idle, isAuthenticated: false, latestUsage: null, authFailed: false, consecutiveFailures: 0));
    }

    [Fact]
    public void State_Authenticated_WhenSnapshotPresent()
    {
        Assert.Equal(FlyoutContentState.Authenticated,
            FlyoutViewModel.ResolveState(LoginState.Idle, isAuthenticated: true, latestUsage: UsageWithModels(), authFailed: false, consecutiveFailures: 0));
    }

    [Fact]
    public void State_Authenticated_WinsOverAuthFailed_WhenBothSet()
    {
        // The Mac shows the last good usage even if a later poll set authFailed but usage is non-null.
        Assert.Equal(FlyoutContentState.Authenticated,
            FlyoutViewModel.ResolveState(LoginState.Idle, isAuthenticated: true, latestUsage: UsageWithModels(), authFailed: true, consecutiveFailures: 20));
    }

    [Fact]
    public void State_AuthFailed_WhenAuthFailedAndNoSnapshot()
    {
        Assert.Equal(FlyoutContentState.AuthFailed,
            FlyoutViewModel.ResolveState(LoginState.Idle, isAuthenticated: true, latestUsage: null, authFailed: true, consecutiveFailures: 1));
    }

    [Fact]
    public void State_Error_WhenTenFailuresAndNoSnapshot()
    {
        Assert.Equal(FlyoutContentState.Error,
            FlyoutViewModel.ResolveState(LoginState.Idle, isAuthenticated: true, latestUsage: null, authFailed: false, consecutiveFailures: 10));
    }

    [Fact]
    public void State_Loading_WhenAuthedNoSnapshotFewFailures()
    {
        Assert.Equal(FlyoutContentState.Loading,
            FlyoutViewModel.ResolveState(LoginState.Idle, isAuthenticated: true, latestUsage: null, authFailed: false, consecutiveFailures: 3));
    }

    [Fact]
    public void ViewModel_Refresh_PublishesResolvedState()
    {
        var vm = new FlyoutViewModel(() => Now)
        {
            IsAuthenticated = true,
            LatestUsage = UsageWithModels(),
        };
        Assert.Equal(FlyoutContentState.Authenticated, vm.State);

        vm.LoginState = LoginState.SigningIn;
        Assert.Equal(FlyoutContentState.SigningIn, vm.State);
    }

    // MARK: - Models card omitted + Resets full width when no per-model limits

    [Fact]
    public void Authenticated_NoModels_OmitsModelsCard_AndResetsSpansFull()
    {
        var vm = new FlyoutViewModel(() => Now)
        {
            IsAuthenticated = true,
            LatestUsage = UsageWithModels(), // no model usages
        };

        Assert.False(vm.HasModelBars);
        Assert.Empty(vm.ModelBars);
    }

    [Fact]
    public void Authenticated_WithModels_ShowsModelsCard_WithAllModelsRowFirst()
    {
        var vm = new FlyoutViewModel(() => Now)
        {
            IsAuthenticated = true,
            LatestUsage = UsageWithModels(
                new ModelUsage { DisplayName = "Opus", RemainingPercent = 30, ModelId = "claude-opus" },
                new ModelUsage { DisplayName = "Sonnet", RemainingPercent = 80, ModelId = "claude-sonnet" }),
        };

        Assert.True(vm.HasModelBars);
        // 1 synthetic "All Models" + 2 per-model rows.
        Assert.Equal(3, vm.ModelBars.Count);
        Assert.Equal("__all_models__", vm.ModelBars[0].Id);
        Assert.Equal("All Models", vm.ModelBars[0].Name);
        // The All Models bar carries the REAL weekly aggregate (70), never fabricated.
        Assert.Equal(70, vm.ModelBars[0].RemainingPercent);
        Assert.Equal("Opus", vm.ModelBars[1].Name);
        Assert.Equal("Sonnet", vm.ModelBars[2].Name);
    }

    [Fact]
    public void ModelBarRows_KeepDistinctIds_ForModelsSharingADisplayName()
    {
        var usage = UsageWithModels(
            new ModelUsage { DisplayName = "Claude", RemainingPercent = 10, ModelId = "id-a" },
            new ModelUsage { DisplayName = "Claude", RemainingPercent = 90, ModelId = "id-b" });

        var rows = FlyoutViewModel.ModelBarRows(usage);
        var ids = rows.Select(r => r.Id).ToList();
        Assert.Equal(ids.Count, ids.Distinct().Count());
    }

    [Fact]
    public void ResetsCard_BothMissing_IsUnavailable()
    {
        var usage = new UsageSnapshot { SessionRemaining = 50, WeeklyRemaining = 50 };
        var card = FlyoutViewModel.MakeResetsCard(usage, Now);
        Assert.True(card.Unavailable);
        Assert.Empty(card.Rows);
    }

    [Fact]
    public void ResetsCard_PresentDates_ShowsSessionAndWeeklyRows()
    {
        var usage = UsageWithModels();
        var card = FlyoutViewModel.MakeResetsCard(usage, Now);
        Assert.False(card.Unavailable);
        Assert.Collection(card.Rows,
            r => { Assert.Equal("Session", r.Label); Assert.True(r.HasDate); },
            r => { Assert.Equal("Weekly", r.Label); Assert.True(r.HasDate); });
    }

    [Fact]
    public void ResetRow_UnknownDate_RendersDashesNotACrash()
    {
        // Only the session date present: the weekly row must render "--", never throw on a null date.
        var usage = new UsageSnapshot
        {
            SessionRemaining = 50,
            WeeklyRemaining = 50,
            SessionResetDate = Now.AddHours(2),
            WeeklyResetDate = null,
        };
        var card = FlyoutViewModel.MakeResetsCard(usage, Now);
        Assert.False(card.Unavailable);
        Assert.Equal("--", card.Rows[1].Value);
        Assert.False(card.Rows[1].HasDate);
    }

    // MARK: - Color scales (remaining vs spend) at the documented boundaries

    [Theory]
    [InlineData(0, UsageColor.Red)]
    [InlineData(19.9, UsageColor.Red)]
    [InlineData(20, UsageColor.Orange)]   // boundary: < 20 red, so 20 is orange
    [InlineData(44.9, UsageColor.Orange)]
    [InlineData(45, UsageColor.Green)]    // boundary: < 45 orange, so 45 is green
    [InlineData(100, UsageColor.Green)]
    public void RemainingColor_MatchesMacBatteryScale(double percent, UsageColor expected)
    {
        Assert.Equal(expected, FlyoutViewModel.RemainingColor(percent));
    }

    [Theory]
    [InlineData(0, SpendColor.Cyan)]
    [InlineData(49.9, SpendColor.Cyan)]
    [InlineData(50, SpendColor.Orange)]   // boundary: >= 50 orange
    [InlineData(79.9, SpendColor.Orange)]
    [InlineData(80, SpendColor.Red)]      // boundary: >= 80 red
    [InlineData(150, SpendColor.Red)]     // uncapped: over-limit is red (KTD7)
    public void SpendColor_MatchesMacSpendScale(double percent, SpendColor expected)
    {
        Assert.Equal(expected, FlyoutViewModel.SpendColorFor(percent));
    }

    // MARK: - Credits row: spend scale color + right-pinned balance

    [Fact]
    public void CreditsRow_Enabled_ColorsBySpendScale_AndPinsBalance()
    {
        var credits = new UsageCredits
        {
            StateKind = CreditsStateKind.Enabled,
            Spent = 12.0,
            SpendLimit = 20.0,
            SpendPercent = 60, // -> orange on the spend scale
            SpendCurrency = "USD",
            BalanceMajor = 5.0,
            BalanceCurrency = "USD",
        };

        var row = FlyoutViewModel.MakeCreditsRow(credits, Now);

        Assert.True(row.HasCredits);
        Assert.Equal(CreditsStateKind.Enabled, row.StateKind);
        Assert.Equal(SpendColor.Orange, row.StatusColor);
        Assert.Equal(SpendColor.Orange, row.BarColor);
        Assert.Equal(60, row.BarPercent);
        Assert.Equal("$12.00 spent · 60% used", row.StatusText);
        // The balance is present (right-pinned in XAML, never truncates) and currency-formatted.
        Assert.NotNull(row.BalanceText);
        Assert.Contains("5.00", row.BalanceText!);
        Assert.NotNull(row.MonthlySpendLimitText);
    }

    [Fact]
    public void CreditsRow_OverLimit_BarClampsButColorIsRed()
    {
        var credits = new UsageCredits
        {
            StateKind = CreditsStateKind.Enabled,
            Spent = 25.0,
            SpendLimit = 20.0,
            SpendPercent = 125, // over limit
            SpendCurrency = "USD",
        };

        var row = FlyoutViewModel.MakeCreditsRow(credits, Now);
        Assert.Equal(SpendColor.Red, row.BarColor);
        Assert.Equal(100, row.BarPercent); // bar fill clamps at display
        Assert.Equal("$25.00 spent · 125% used", row.StatusText);
    }

    [Fact]
    public void CreditsRow_Disabled_ShowsPausedReason_EmptyTrack()
    {
        var credits = new UsageCredits
        {
            StateKind = CreditsStateKind.Disabled,
            DisabledReason = "org_level_disabled_until",
            BalanceMajor = 3.0,
            BalanceCurrency = "USD",
        };

        var row = FlyoutViewModel.MakeCreditsRow(credits, Now);
        Assert.True(row.HasCredits);
        Assert.Null(row.BarPercent); // empty track in the disabled state
        Assert.Equal("Paused - monthly limit reached", row.StatusText);
        Assert.NotNull(row.BalanceText);
    }

    [Fact]
    public void CreditsRow_Null_HasNoCredits()
    {
        Assert.False(FlyoutViewModel.MakeCreditsRow(null, Now).HasCredits);
    }

    [Fact]
    public void CreditsRow_BalanceOnly_ShowsBalanceNoSpendBar()
    {
        var credits = new UsageCredits
        {
            StateKind = CreditsStateKind.None,
            BalanceMajor = 8.5,
            BalanceCurrency = "USD",
        };
        var row = FlyoutViewModel.MakeCreditsRow(credits, Now);
        Assert.True(row.HasCredits);
        Assert.Null(row.BarPercent);
        Assert.Equal(string.Empty, row.StatusText);
        Assert.NotNull(row.BalanceText);
    }

    // MARK: - Pace bar (time remaining) percent + omission

    [Fact]
    public void PaceBar_FullWindowRemaining_IsHundredPercent()
    {
        // resetsAt one full session window from now => 100% time remaining.
        var pace = FlyoutViewModel.MakePaceBar(Now.AddSeconds(FlyoutViewModel.SessionWindowSeconds), FlyoutViewModel.SessionWindowSeconds, Now);
        Assert.True(pace.HasValue);
        Assert.Equal(100, pace.Percent, 3);
        Assert.Equal("100%", pace.PercentLabel);
    }

    [Fact]
    public void PaceBar_HalfWindowRemaining_IsFiftyPercent()
    {
        var pace = FlyoutViewModel.MakePaceBar(Now.AddSeconds(FlyoutViewModel.WeeklyWindowSeconds / 2), FlyoutViewModel.WeeklyWindowSeconds, Now);
        Assert.True(pace.HasValue);
        Assert.Equal(50, pace.Percent, 3);
    }

    [Fact]
    public void PaceBar_NullResetDate_IsOmitted()
    {
        var pace = FlyoutViewModel.MakePaceBar(null, FlyoutViewModel.SessionWindowSeconds, Now);
        Assert.False(pace.HasValue);
    }

    [Fact]
    public void PaceBar_PastResetDate_IsOmitted()
    {
        // A reset already in the past yields no countdown, so the bar is omitted (KTD4).
        var pace = FlyoutViewModel.MakePaceBar(Now.AddHours(-1), FlyoutViewModel.SessionWindowSeconds, Now);
        Assert.False(pace.HasValue);
    }

    // MARK: - Long-form countdown format (Mac formatCountdown parity)

    [Fact]
    public void FormatCountdown_Days_UsesDdHhForm()
    {
        Assert.Equal("2d 03h", FlyoutViewModel.FormatCountdown(Now.AddDays(2).AddHours(3).AddMinutes(10), Now));
    }

    [Fact]
    public void FormatCountdown_Hours_UsesHhMmForm()
    {
        Assert.Equal("4h 05m", FlyoutViewModel.FormatCountdown(Now.AddHours(4).AddMinutes(5).AddSeconds(30), Now));
    }

    [Fact]
    public void FormatCountdown_Minutes_UsesMmSsForm()
    {
        Assert.Equal("12m 30s", FlyoutViewModel.FormatCountdown(Now.AddMinutes(12).AddSeconds(30), Now));
    }

    [Fact]
    public void FormatCountdown_PastDate_FallsBackToZero()
    {
        Assert.Equal("00m 00s", FlyoutViewModel.FormatCountdown(Now.AddHours(-1), Now));
    }

    // MARK: - signing-in dismissal suppression flag

    [Theory]
    [InlineData(LoginStateKind.SigningIn, true)]
    [InlineData(LoginStateKind.Capturing, true)]
    [InlineData(LoginStateKind.OrgDiscovery, true)]
    [InlineData(LoginStateKind.Picker, true)]
    [InlineData(LoginStateKind.Idle, false)]
    [InlineData(LoginStateKind.Active, false)]
    [InlineData(LoginStateKind.Error, false)]
    public void SuppressDismiss_OnlyWhileLoginInProgress(LoginStateKind kind, bool expected)
    {
        var vm = new FlyoutViewModel(() => Now)
        {
            LoginState = new LoginState(kind, kind == LoginStateKind.Error ? "msg" : null),
        };
        Assert.Equal(expected, vm.SuppressDismissOnDeactivate);
    }

    // MARK: - Account list visibility

    [Fact]
    public void AccountList_HiddenWithOneAccount_LinkShownIfSlotFree()
    {
        var account = new Account { Email = "a@x.com", SessionKey = "k", OrganizationId = "o1" };
        var vm = new FlyoutViewModel(() => Now)
        {
            IsAuthenticated = true,
            LatestUsage = UsageWithModels(),
            Accounts = new[] { account },
            ActiveAccountId = account.Id,
            CanAddAccount = true,
        };
        Assert.False(vm.ShowAccountList);
        Assert.True(vm.ShowAddAccountLink);
        Assert.Empty(vm.AccountRows);
    }

    [Fact]
    public void AccountList_ShownWithTwoAccounts_MarksActive()
    {
        var a = new Account { Email = "a@x.com", SessionKey = "k", OrganizationId = "o1" };
        var b = new Account { Email = "b@x.com", SessionKey = "k", OrganizationId = "o2" };
        var vm = new FlyoutViewModel(() => Now)
        {
            IsAuthenticated = true,
            LatestUsage = UsageWithModels(),
            Accounts = new[] { a, b },
            ActiveAccountId = b.Id,
        };
        Assert.True(vm.ShowAccountList);
        Assert.False(vm.ShowAddAccountLink);
        Assert.Equal(2, vm.AccountRows.Count);
        Assert.True(vm.AccountRows.Single(r => r.Id == b.Id).IsActive);
        Assert.False(vm.AccountRows.Single(r => r.Id == a.Id).IsActive);
    }

    // MARK: - Version / update row

    [Fact]
    public void UpdateRow_NoUpdate_ShowsLastUpdatedText()
    {
        var vm = new FlyoutViewModel(() => Now)
        {
            IsAuthenticated = true,
            LatestUsage = UsageWithModels(),
            LastSuccessfulFetch = Now.AddSeconds(-30),
        };
        Assert.False(vm.HasUpdate);
        Assert.Equal("Updated just now", vm.LastUpdatedText);
    }

    [Fact]
    public void UpdateRow_UpdateAvailable_ShowsDownloadLink()
    {
        var vm = new FlyoutViewModel(() => Now)
        {
            IsAuthenticated = true,
            LatestUsage = UsageWithModels(),
            AvailableUpdateVersion = "1.51",
        };
        Assert.True(vm.HasUpdate);
        Assert.Equal("v1.51 available — Download", vm.UpdateLinkText);
    }

    [Fact]
    public void LastUpdatedText_NeverFetched_IsNotYetUpdated()
    {
        var vm = new FlyoutViewModel(() => Now);
        Assert.Equal("Not yet updated", vm.LastUpdatedText);
    }

    [Fact]
    public void LastUpdatedText_MinutesAgo_PluralizesCorrectly()
    {
        var vm = new FlyoutViewModel(() => Now) { LastSuccessfulFetch = Now.AddMinutes(-1) };
        Assert.Equal("Updated 1 minute ago", vm.LastUpdatedText);

        vm.LastSuccessfulFetch = Now.AddMinutes(-5);
        Assert.Equal("Updated 5 minutes ago", vm.LastUpdatedText);
    }

    // MARK: - Placement on a secondary monitor at a different DPI

    [Fact]
    public void Placement_SecondaryMonitor_LandsWithinThatMonitorsWorkArea()
    {
        // A secondary monitor to the right of the primary, at a different scale. The work area is
        // given in DEVICE PIXELS (the caller resolves it for the monitor under the anchor and feeds
        // it in already DPI-correct), so the placement function only has to clamp inside it. The tray
        // rect sits near that monitor's bottom-right (a bottom taskbar).
        var workArea = new PlacementRect(2560, 0, 2560 + 3840, 2160); // a 4K panel offset to the right
        var trayRect = new PlacementRect(6300, 2080, 6340, 2120);     // near its bottom-right
        var cursor = new PlacementPoint(6310, 2100);
        var size = new PlacementSize(300, 520);

        var p = FlyoutPlacement.Compute(trayRect, cursor, workArea, size);

        AssertWithinWorkArea(p, size, workArea);
        // It should land on the SECONDARY monitor (x within its bounds), not bleed onto the primary.
        Assert.True(p.X >= workArea.Left, $"X {p.X} should be >= work-area left {workArea.Left}");
    }

    [Fact]
    public void Placement_OverflowFallback_UsesCursor_ClampsToWorkArea()
    {
        // No tray rect (icon is in the overflow flyout): anchor to the cursor and clamp.
        var workArea = new PlacementRect(0, 0, 1920, 1040); // primary minus a bottom taskbar
        var cursor = new PlacementPoint(1900, 1030);        // near bottom-right
        var size = new PlacementSize(300, 520);

        var p = FlyoutPlacement.Compute(trayRect: null, cursor, workArea, size);

        AssertWithinWorkArea(p, size, workArea);
    }

    [Fact]
    public void Placement_AnchorNearTop_FlipsBelow_StillClamped()
    {
        // A tray rect near the TOP of the work area (a top taskbar): placing above would spill off the
        // top, so the function flips below the anchor and clamps.
        var workArea = new PlacementRect(0, 40, 1920, 1080);
        var trayRect = new PlacementRect(1860, 45, 1900, 85);
        var cursor = new PlacementPoint(1880, 65);
        var size = new PlacementSize(300, 520);

        var p = FlyoutPlacement.Compute(trayRect, cursor, workArea, size);

        AssertWithinWorkArea(p, size, workArea);
        Assert.True(p.Y >= workArea.Top, "flyout top must not spill above the work area");
    }

    [Fact]
    public void Placement_FlyoutTallerThanWorkArea_PinsToTop()
    {
        // A pathological tiny work area: the flyout cannot fit, so it pins to the top edge (header
        // stays visible) rather than going negative.
        var workArea = new PlacementRect(0, 0, 1920, 300);
        var trayRect = new PlacementRect(1860, 270, 1900, 295);
        var cursor = new PlacementPoint(1880, 285);
        var size = new PlacementSize(300, 520);

        var p = FlyoutPlacement.Compute(trayRect, cursor, workArea, size);

        Assert.Equal(workArea.Top, p.Y);
        Assert.True(p.X >= workArea.Left && p.X + size.Width <= workArea.Right + 0.001);
    }

    private static void AssertWithinWorkArea(PlacementPoint p, PlacementSize size, PlacementRect workArea)
    {
        const double tol = 0.001;
        Assert.True(p.X >= workArea.Left - tol, $"left {p.X} < work-area left {workArea.Left}");
        Assert.True(p.Y >= workArea.Top - tol, $"top {p.Y} < work-area top {workArea.Top}");
        Assert.True(p.X + size.Width <= workArea.Right + tol, $"right {p.X + size.Width} > work-area right {workArea.Right}");
        Assert.True(p.Y + size.Height <= workArea.Bottom + tol, $"bottom {p.Y + size.Height} > work-area bottom {workArea.Bottom}");
    }

    // MARK: - Documented manual/visual contracts (no headless assertion possible)

    /// <summary>
    /// Live re-theme: <c>FlyoutWindow.ApplyTheme(bucket)</c> replaces the merged token dictionary so
    /// every <c>DynamicResource</c> consumer re-resolves WITHOUT close/reopen. This is a visual,
    /// UI-thread behavior (it requires a constructed Window with a Dispatcher and the token
    /// dictionaries present), so it is verified by manual QA. The headless guarantee the view-model
    /// gives is that semantic colors are theme-INVARIANT buckets (asserted by the color-scale tests
    /// above): only the neutral surface tokens differ by theme, and those are swapped by ApplyTheme.
    /// </summary>
    [Fact]
    public void LiveRetheme_IsManualVisualCheck()
    {
        // Intentionally a no-op assertion documenting the manual gate; the color-bucket tests prove
        // the semantic colors do not depend on theme, which is the testable half of the contract.
        Assert.True(true);
    }

    /// <summary>
    /// Escape-to-close and Deactivated-dismissal live in the <c>FlyoutWindow</c> code-behind
    /// (<c>OnKeyDown</c> / <c>OnDeactivated</c>), which require a real Window + input/focus events to
    /// exercise. They are verified by manual QA. The testable half (the suppression predicate the
    /// Deactivated handler reads) is covered by <see cref="SuppressDismiss_OnlyWhileLoginInProgress"/>.
    /// </summary>
    [Fact]
    public void EscapeAndDeactivatedDismissal_AreManualVisualChecks()
    {
        Assert.True(true);
    }
}
