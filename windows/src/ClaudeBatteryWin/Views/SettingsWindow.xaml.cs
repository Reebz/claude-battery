using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;

namespace ClaudeBatteryWin.Views;

/// <summary>
/// Settings surface (U11), the Windows port of the Mac SettingsView. Hosts the launch-at-login,
/// notifications (plus a test-toast button when the host supplies a sender), and session-countdown
/// toggles; the account list with inline nickname edit and two-step remove; the manual cookie-paste
/// sign-in; and the version/update row.
///
/// The window is constructed by the integration layer with the live services. The icon style is
/// fixed for v1 (no picker). Per-account threshold sliders appear only while notifications are
/// enabled, mirroring the Mac (which shows the slider per account only when notificationsEnabled).
///
/// The account list follows the store: <see cref="AccountStore.ActiveAccountChanged"/> (raised on
/// add, remove, switch and re-auth) rebuilds the list while the window is open, so an account added
/// through the WebView2 login or a switch made from the flyout shows up without reopening Settings.
/// <see cref="RefreshAccounts"/> and <see cref="RefreshUpdateRow"/> are the explicit hooks for the
/// integration layer to push a refresh (e.g. when a background update check completes).
///
/// Bindings are wired in code rather than via a separate view-model: the account rows need a
/// DataTemplate-style swap between a label and an edit field (the active edit field gets a Fluent
/// AccentColor border), which is clearest built imperatively here. The testable logic
/// (manual-sign-in validation, the notify dedup, autostart writes) lives in the injected services
/// (<see cref="ManualSignIn"/>, <see cref="Notifier"/>, <see cref="AutostartService"/>), so this
/// code-behind is thin glue with no business rules of its own.
/// </summary>
public partial class SettingsWindow : Window
{
    private readonly AccountStore _accountStore;
    private readonly ManualSignIn _manualSignIn;
    private readonly AutostartService _autostart;
    private readonly IAppSettings _settings;
    private readonly UpdateService _updateService;

    /// Sends a test toast through the host's real toast sink and reports whether Windows accepted
    /// it. Null on builds without a sink (author/non-Windows), which hides the button.
    private readonly Func<bool>? _sendTestToast;

    /// Asks Windows whether it would deliver a toast, without sending one (R45). Null on builds
    /// without a sink, where the blocked line simply never shows.
    private readonly Func<ToastPermission>? _readToastPermission;

    /// The account currently awaiting a two-step remove confirm, or null. Mirrors the Mac
    /// confirmRemoveId.
    private Guid? _confirmRemoveId;

    /// The account whose nickname is being edited inline, or null. Drives the label/edit-field swap.
    private Guid? _editingNicknameId;

    /// Set when the window is opened via the "Sign in manually" affordance: once loaded, scroll the
    /// manual cookie-paste section into view and focus the paste box (U4). False for the normal open.
    private bool _focusManualSignInPending;

    public SettingsWindow(
        AccountStore accountStore,
        ManualSignIn manualSignIn,
        AutostartService autostart,
        IAppSettings settings,
        UpdateService updateService,
        Func<bool>? sendTestToast = null,
        Func<ToastPermission>? readToastPermission = null)
    {
        _accountStore = accountStore ?? throw new ArgumentNullException(nameof(accountStore));
        _manualSignIn = manualSignIn ?? throw new ArgumentNullException(nameof(manualSignIn));
        _autostart = autostart ?? throw new ArgumentNullException(nameof(autostart));
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _updateService = updateService ?? throw new ArgumentNullException(nameof(updateService));
        _sendTestToast = sendTestToast;
        _readToastPermission = readToastPermission;

        InitializeComponent();

        // Follow the store while open so an account added via the login window, or a switch made
        // from the flyout, shows up here without a reopen. Unsubscribe on close: the window is
        // recreated per open (App nulls its reference on Closed) and must not outlive itself.
        _accountStore.ActiveAccountChanged += OnStoreChanged;
        Closed += (_, _) => _accountStore.ActiveAccountChanged -= OnStoreChanged;

        // Reflect current state into the toggles WITHOUT firing the Checked/Unchecked handlers (set
        // the field before the window is loaded so the handler's guard sees them initialized).
        Loaded += OnLoaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _suppressToggleEvents = true;
        LaunchAtLoginToggle.IsChecked = _autostart.IsEnabled;
        NotificationsToggle.IsChecked = _settings.NotificationsEnabled;
        CountdownToggle.IsChecked = _settings.ShowSessionCountdown;
        DiagnosticsToggle.IsChecked = _settings.DiagnosticsEnabled;
        IconStylePicker.ItemsSource = Icons.TrayIconStyles.AllNames;
        IconStylePicker.SelectedItem = Icons.TrayIconStyles.NameOf(_settings.IconStyle);
        _suppressToggleEvents = false;

        RefreshNotificationsBlockedLine();
        TrayPinHelp.Text = ClaudeBatteryWin.App.TrayNoticeBody;

        // The test-toast button only makes sense when the host wired a real sender.
        TestNotificationButton.Visibility = _sendTestToast is null ? Visibility.Collapsed : Visibility.Visible;

        // Assembly version, not Assembly.Location / FileVersionInfo: those are empty or throw under
        // PublishSingleFile (the shipped raw exe). ToString(3) drops the trailing revision.
        VersionLabel.Text = $"Claude Battery v{typeof(App).Assembly.GetName().Version?.ToString(3)}";

        CookieHeaderHelp.Text = CookieHeaderHelpText;

        RebuildAccountList();
        RefreshUpdateRow();

        if (_focusManualSignInPending)
        {
            _focusManualSignInPending = false;
            // Defer to after layout so BringIntoView has a realized visual tree to scroll within.
            Dispatcher.BeginInvoke(new Action(ApplyManualSignInFocus), DispatcherPriority.Loaded);
        }
    }

    /// <summary>
    /// Request that the manual cookie-paste section be scrolled into view and focused once the window
    /// is shown. The login error surface's "Sign in manually" affordance routes here (U4) so a stuck
    /// user lands directly on the paste box; the normal Settings open does not call this.
    /// </summary>
    public void FocusManualSignIn()
    {
        if (IsLoaded)
        {
            ApplyManualSignInFocus();
        }
        else
        {
            _focusManualSignInPending = true;
        }
    }

    private void ApplyManualSignInFocus()
    {
        CookieHeaderBox.BringIntoView();
        CookieHeaderBox.Focus();
    }

    // Guards the initial IsChecked assignment in OnLoaded so it does not re-enter the registry/disk.
    private bool _suppressToggleEvents;

    /// The organizations offered by the last paste that needed a choice, in the order the picker
    /// shows them. The picker itself holds labels, so the choice is resolved back by position.
    private IReadOnlyList<Organization>? _orgChoices;

    // MARK: - Toggles

    private void OnLaunchAtLoginToggled(object sender, RoutedEventArgs e)
    {
        if (_suppressToggleEvents)
        {
            return;
        }

        var requested = LaunchAtLoginToggle.IsChecked == true;
        var actual = _autostart.SetEnabled(requested);

        // If the registry write failed, snap the toggle back to reality (the Mac re-reads status on
        // a thrown register/unregister and rebinds the toggle to it).
        if (actual != requested)
        {
            _suppressToggleEvents = true;
            LaunchAtLoginToggle.IsChecked = actual;
            _suppressToggleEvents = false;
        }
    }

    private void OnNotificationsToggled(object sender, RoutedEventArgs e)
    {
        if (_suppressToggleEvents)
        {
            return;
        }

        var enabled = NotificationsToggle.IsChecked == true;
        _settings.NotificationsEnabled = enabled;

        // Enabling registers toast capability so the AUMID resolves before the first alert. A
        // failure is non-fatal (the Notifier's sink reports not-delivered and never latches), so
        // the toggle stays on.
        if (enabled)
        {
            RegisterToastCapability();
        }

        // The per-account threshold sliders only show while notifications are on.
        RebuildAccountList();
    }

    private void OnCountdownToggled(object sender, RoutedEventArgs e)
    {
        if (_suppressToggleEvents)
        {
            return;
        }

        _settings.ShowSessionCountdown = CountdownToggle.IsChecked == true;
    }

    private void OnIconStyleChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressToggleEvents)
        {
            return;
        }

        _settings.IconStyle = Icons.TrayIconStyles.Parse(IconStylePicker.SelectedItem as string);
    }

    /// <summary>
    /// How to find the cookie header, for a user who has never opened developer tools. Ported from
    /// the Mac word for word, with the Windows shortcut in place of the Mac one. Internal so the
    /// exact wording is pinned by a test rather than only by reading the XAML.
    /// </summary>
    internal const string CookieHeaderHelpText =
        "1. Sign in to claude.ai in your browser.\n" +
        "2. Open Developer Tools (F12) and select the Network tab.\n" +
        "3. Refresh the page, then click any request to claude.ai.\n" +
        "4. Under Request Headers, copy the entire value of the \"Cookie\" header.\n" +
        "5. Paste it above. Paste it only here, never into a web page.";

    private void OnDiagnosticsToggled(object sender, RoutedEventArgs e)
    {
        if (_suppressToggleEvents)
        {
            return;
        }

        _settings.DiagnosticsEnabled = DiagnosticsToggle.IsChecked == true;
    }

    /// <summary>
    /// Build the redacted archive and let the user save it. Each outcome gets its own message: an
    /// empty export, a refused export, and a failed export mean different things and a user who is
    /// told the wrong one wastes a round trip (R57).
    /// </summary>
    private void OnExportLogsClicked(object sender, RoutedEventArgs e)
    {
        var result = LogsExporter.Export(
            DiagnosticsLogger.DefaultLogDirectory,
            LogsExporter.ProductionInstallDate(),
            ChooseExportDestination);

        ApplyExportResult(result);
    }

    private static string? ChooseExportDestination(string suggestedName)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Save Diagnostic Logs",
            FileName = suggestedName,
            AddExtension = false,
            OverwritePrompt = true
        };
        return dialog.ShowDialog() == true ? dialog.FileName : null;
    }

    /// <summary>Maps one export outcome onto the status line and the issues link. Internal so the
    /// message text is pinned by a test rather than only by reading the XAML.</summary>
    internal static (string? Status, bool IsError, bool ShowLink) ExportStatus(ExportResult result) => result switch
    {
        ExportResult.Success success =>
            ($"Saved to {System.IO.Path.GetFileName(success.SavedPath)}. Please attach it to a GitHub issue.", false, true),
        ExportResult.Cancelled => (null, false, false),
        ExportResult.NothingToExport =>
            ("No diagnostic logs yet. Turn on logging, reproduce the problem, then export.", false, false),
        ExportResult.InstallDateUnreadable =>
            ("Couldn't determine the install date, so export is disabled for safety. Reinstall Claude Battery, then export again.", true, false),
        ExportResult.Failure failure => (failure.Message, true, false),
        _ => (null, false, false)
    };

    private void ApplyExportResult(ExportResult result)
    {
        var (status, isError, showLink) = ExportStatus(result);
        if (status is null)
        {
            return; // cancelled: leave whatever was already showing
        }

        DiagnosticsStatus.Text = status;
        DiagnosticsStatus.Foreground = (Brush)FindResource(
            isError ? "SettingsErrorTextBrush" : "SettingsSuccessTextBrush");
        DiagnosticsStatus.Visibility = Visibility.Visible;
        DiagnosticsIssuesLink.Visibility = showLink ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>
    /// The sentence shown when Windows is blocking the app's notifications (R45).
    ///
    /// Pure and internal so the wording is pinned by a test. The three "off" switches in Windows get
    /// one sentence between them, because the answer is the same for all three: go and look in the
    /// Windows notification settings. A permission read that cannot answer says nothing at all,
    /// rather than telling the user something is wrong when it may not be.
    /// </summary>
    internal static string? NotificationsBlockedMessage(ToastPermission permission) =>
        ToastPermissions.IsBlocked(permission)
            ? "Windows is currently blocking notifications from Claude Battery, so low usage alerts won't appear."
            : null;

    /// <summary>Where the blocked line's link goes: the Windows notification settings page.</summary>
    internal const string NotificationSettingsUri = "ms-settings:notifications";

    /// <summary>The support link the Mac's coffee button opens (R48), kept byte-identical.</summary>
    internal const string SupportUrl = "https://www.buymeacoffee.com/reebz";

    /// <summary>The support button's label, as on the Mac (R48).</summary>
    internal const string SupportButtonText = "Buy me a coffee!";

    private void RefreshNotificationsBlockedLine()
    {
        var permission = ReadPermissionSafely();
        var message = NotificationsBlockedMessage(permission);
        if (message is null)
        {
            NotificationsBlockedLine.Visibility = Visibility.Collapsed;
            return;
        }

        NotificationsBlockedText.Text = message + " ";
        NotificationsBlockedLine.Visibility = Visibility.Visible;
    }

    /// A permission read must never take the Settings window down with it (KTD12).
    private ToastPermission ReadPermissionSafely()
    {
        if (_readToastPermission is null)
        {
            return ToastPermission.Unknown;
        }

        try
        {
            return _readToastPermission();
        }
        catch (Exception)
        {
            return ToastPermission.Unknown;
        }
    }

    private void OnNotificationSettingsLinkClicked(object sender, RoutedEventArgs e) =>
        OpenExternal(NotificationSettingsUri);

    private void OnSupportClicked(object sender, RoutedEventArgs e) => OpenExternal(SupportUrl);

    private static void OpenExternal(string target)
    {
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or System.IO.FileNotFoundException)
        {
        }
    }

    private void OnIssuesLinkClicked(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo(LogsExporter.IssuesUrl) { UseShellExecute = true });
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or System.IO.FileNotFoundException)
        {
        }
    }

    /// <summary>
    /// Fire one toast through the host's real sink so a tester can confirm Windows accepts the app's
    /// notifications right now, instead of waiting for usage to drop below a threshold. The sink
    /// reports false (never throws) when Windows rejected or silently dropped the toast.
    /// </summary>
    private void OnTestNotificationClicked(object sender, RoutedEventArgs e)
    {
        if (_sendTestToast is null)
        {
            return;
        }

        bool delivered;
        try
        {
            delivered = _sendTestToast();
        }
        catch (Exception)
        {
            delivered = false;
        }

        var text = delivered
            ? "Sent."
            : "Windows did not accept the toast. Check Settings > System > Notifications for a 'Claude Battery' entry.";
        TestNotificationStatus.Text = text;
        TestNotificationStatus.Foreground = (Brush)FindResource(delivered ? "SettingsSuccessTextBrush" : "SettingsErrorTextBrush");
        TestNotificationStatus.Visibility = Visibility.Visible;
        AutomationProperties.SetName(TestNotificationStatus, text);
    }

    /// <summary>
    /// Register the process AUMID so toasts resolve to the installed Start-menu shortcut's identity.
    /// Best-effort; isolated here so the WinRT-only call does not break the non-Windows author/test
    /// build (it is compiled in only on the Windows-versioned TFM).
    /// </summary>
    private static void RegisterToastCapability()
    {
#if WINDOWS10_0_19041_0_OR_GREATER
        WinRtToastSink.EnsureRegistered();
#endif
    }

    // MARK: - Account list

    /// <summary>
    /// Rebuild the account list from the store. Explicit hook for the integration layer (e.g. after
    /// a login completes); the store's <see cref="AccountStore.ActiveAccountChanged"/> already
    /// drives the same rebuild while the window is open.
    /// </summary>
    public void RefreshAccounts() => RebuildAccountList();

    /// <summary>
    /// Store change -> rebuild on the UI thread. The store raises synchronously on the caller's
    /// thread (which can be a poll or login continuation), hence BeginInvoke. Skipped while a
    /// nickname edit is in progress so a half-typed name is not thrown away by the rebuild.
    /// </summary>
    private void OnStoreChanged()
    {
        Dispatcher.BeginInvoke(new Action(() =>
        {
            if (!IsLoaded || _editingNicknameId is not null)
            {
                return;
            }

            RebuildAccountList();
        }));
    }

    private void RebuildAccountList()
    {
        AccountList.Items.Clear();

        var accounts = _accountStore.Accounts;
        NoAccountsLabel.Visibility = accounts.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        foreach (var account in accounts)
        {
            AccountList.Items.Add(BuildAccountRow(account));
        }

        AddAccountButton.IsEnabled = _accountStore.CanAddAccount;
    }

    private UIElement BuildAccountRow(Account account)
    {
        var isActive = account.Id == _accountStore.ActiveAccountId;
        var notificationsOn = _settings.NotificationsEnabled;

        var outer = new StackPanel { Margin = new Thickness(0, 4, 0, 4) };

        // --- top row: status dot, name (label OR inline edit field), action buttons ------------
        var topRow = new Grid();
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var dot = new Ellipse
        {
            Width = 8,
            Height = 8,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
            Fill = isActive ? Brushes.LimeGreen : Brushes.Gray,
        };
        Grid.SetColumn(dot, 0);
        topRow.Children.Add(dot);

        // The label/edit-field swap (the Mac DataTemplate swap). Editing this account shows a
        // TextBox with an active Fluent AccentColor border; otherwise a click-to-edit label.
        FrameworkElement nameElement;
        if (_editingNicknameId == account.Id)
        {
            var editBorder = new Border
            {
                BorderThickness = new Thickness(1),
                BorderBrush = (Brush)FindResource("SettingsAccentBrush"),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(4, 1, 4, 1),
                VerticalAlignment = VerticalAlignment.Center,
            };
            var editBox = new TextBox
            {
                Text = account.Nickname ?? string.Empty,
                BorderThickness = new Thickness(0),
                Background = Brushes.Transparent,
                Foreground = (Brush)FindResource("SettingsForegroundBrush"),
                Tag = account.Id,
            };
            AutomationProperties.SetName(editBox, "Account nickname");
            editBox.KeyDown += OnNicknameKeyDown;
            editBox.LostFocus += OnNicknameCommit;
            editBox.Loaded += (_, _) => { editBox.Focus(); editBox.SelectAll(); };
            editBorder.Child = editBox;
            nameElement = editBorder;
        }
        else
        {
            var nameStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var nameLabel = new TextBlock
            {
                Text = _accountStore.DisambiguatedName(account),
                Foreground = (Brush)FindResource("SettingsForegroundBrush"),
                ToolTip = "Click to rename",
                Cursor = Cursors.Hand,
                Tag = account.Id,
            };
            AutomationProperties.SetName(nameLabel, $"Account {_accountStore.DisambiguatedName(account)}, click to rename");
            nameLabel.MouseLeftButtonUp += OnNicknameLabelClicked;
            nameStack.Children.Add(nameLabel);

            // When a nickname is set, show the underlying email as a caption (Mac parity).
            if (account.Nickname is not null)
            {
                nameStack.Children.Add(new TextBlock
                {
                    Text = account.Email,
                    FontSize = 11,
                    Foreground = (Brush)FindResource("SettingsMutedBrush"),
                });
            }

            nameElement = nameStack;
        }
        Grid.SetColumn(nameElement, 1);
        topRow.Children.Add(nameElement);

        // Action buttons: Remove (two-step). When this account is in confirm mode, show
        // Cancel + Confirm; otherwise a single Remove.
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        Grid.SetColumn(actions, 2);
        if (_confirmRemoveId == account.Id)
        {
            var cancel = new Button
            {
                Content = "Cancel",
                Padding = new Thickness(8, 2, 8, 2),
                Margin = new Thickness(0, 0, 6, 0),
                Tag = account.Id,
            };
            AutomationProperties.SetName(cancel, "Cancel removing this account");
            cancel.Click += OnCancelRemoveClicked;

            var confirm = new Button
            {
                Content = "Confirm",
                Padding = new Thickness(8, 2, 8, 2),
                Foreground = (Brush)FindResource("SettingsDangerBrush"),
                Tag = account.Id,
            };
            AutomationProperties.SetName(confirm, "Confirm removing this account");
            confirm.Click += OnConfirmRemoveClicked;

            actions.Children.Add(cancel);
            actions.Children.Add(confirm);
        }
        else
        {
            var remove = new Button
            {
                Content = "Remove",
                Padding = new Thickness(8, 2, 8, 2),
                Foreground = (Brush)FindResource("SettingsDangerBrush"),
                Tag = account.Id,
            };
            AutomationProperties.SetName(remove, $"Remove account {_accountStore.DisambiguatedName(account)}");
            remove.Click += OnRemoveClicked;
            actions.Children.Add(remove);
        }
        topRow.Children.Add(actions);

        outer.Children.Add(topRow);

        // --- threshold slider (only while notifications are on) --------------------------------
        if (notificationsOn)
        {
            var sliderStack = new StackPanel { Margin = new Thickness(16, 4, 0, 0) };
            var thresholdLabel = new TextBlock
            {
                Text = $"Alert below {account.NotificationThreshold:0}%",
                FontSize = 11,
                Foreground = (Brush)FindResource("SettingsMutedBrush"),
            };
            var slider = new Slider
            {
                Minimum = 5,
                Maximum = 50,
                TickFrequency = 5,
                IsSnapToTickEnabled = true,
                Value = account.NotificationThreshold,
                Tag = account.Id,
            };
            AutomationProperties.SetName(slider, $"Notification threshold for {account.DisplayName}");
            slider.ValueChanged += (_, args) =>
            {
                _accountStore.UpdateThreshold(account.Id, args.NewValue);
                thresholdLabel.Text = $"Alert below {args.NewValue:0}%";
            };
            sliderStack.Children.Add(thresholdLabel);
            sliderStack.Children.Add(slider);
            outer.Children.Add(sliderStack);
        }

        return outer;
    }

    // MARK: - Nickname inline edit (the label/edit-field DataTemplate swap)

    private void OnNicknameLabelClicked(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { Tag: Guid id })
        {
            _editingNicknameId = id;
            _confirmRemoveId = null; // editing and confirm-remove are mutually exclusive UI states
            RebuildAccountList();
        }
    }

    private void OnNicknameKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            CommitNickname(sender as TextBox);
        }
        else if (e.Key == Key.Escape)
        {
            _editingNicknameId = null;
            RebuildAccountList();
        }
    }

    private void OnNicknameCommit(object sender, RoutedEventArgs e) => CommitNickname(sender as TextBox);

    private void CommitNickname(TextBox? box)
    {
        if (box is not { Tag: Guid id })
        {
            return;
        }

        // Only commit while still in edit mode for this account; LostFocus can fire during the
        // rebuild itself, and re-committing then would loop.
        if (_editingNicknameId != id)
        {
            return;
        }

        _editingNicknameId = null;
        _accountStore.UpdateNickname(id, box.Text);
        RebuildAccountList();
    }

    // MARK: - Two-step remove

    private void OnRemoveClicked(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: Guid id })
        {
            _confirmRemoveId = id;
            _editingNicknameId = null;
            RebuildAccountList();
        }
    }

    private void OnCancelRemoveClicked(object sender, RoutedEventArgs e)
    {
        _confirmRemoveId = null;
        RebuildAccountList();
    }

    private void OnConfirmRemoveClicked(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: Guid id })
        {
            _confirmRemoveId = null;
            _accountStore.RemoveAccount(id);
            RebuildAccountList();
        }
    }

    // MARK: - Add account / manual sign-in

    /// Raised when the user asks to add an account via the WebView2 login flow (U6/U7). App.xaml.cs
    /// wires this to AuthManager.PresentLogin; kept as an event so this window stays decoupled from
    /// the auth manager.
    public event EventHandler? AddAccountRequested;

    private void OnAddAccountClicked(object sender, RoutedEventArgs e)
        => AddAccountRequested?.Invoke(this, EventArgs.Empty);

    private async void OnValidateAddClicked(object sender, RoutedEventArgs e)
    {
        var pasted = CookieHeaderBox.Password;
        if (string.IsNullOrEmpty(pasted))
        {
            return;
        }

        SetManualBusy(true);
        OrgPickerPanel.Visibility = Visibility.Collapsed;
        ManualSignInResult result;
        try
        {
            // ConfigureAwait(true): explicit UI-thread resume for this async-void handler (the U7
            // convention), so SetManualBusy/ApplyManualResult below run on the UI thread.
            result = await _manualSignIn.SignInAsync(pasted).ConfigureAwait(true);
        }
        catch (Exception)
        {
            result = ManualSignInResult.ConnectionError;
        }
        SetManualBusy(false);
        ApplyManualResult(result);
    }

    private void OnUseOrgClicked(object sender, RoutedEventArgs e)
    {
        var index = OrgPicker.SelectedIndex;
        if (_orgChoices is null || index < 0 || index >= _orgChoices.Count)
        {
            return;
        }

        var org = _orgChoices[index];
        OrgPickerPanel.Visibility = Visibility.Collapsed;
        ApplyManualResult(_manualSignIn.CompleteWithChosenOrg(org));
    }

    private void SetManualBusy(bool busy)
    {
        ValidateAddButton.IsEnabled = !busy;
        ManualSpinner.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ApplyManualResult(ManualSignInResult result)
    {
        switch (result.Kind)
        {
            case ManualSignInResult.ResultKind.Success:
                ShowManualStatus(
                    AuthManager.SignInConfirmation(result.DisplayName ?? string.Empty, result.RefreshedCount),
                    isError: false);
                CookieHeaderBox.Clear();
                OrgPickerPanel.Visibility = Visibility.Collapsed;
                RebuildAccountList();
                break;

            case ManualSignInResult.ResultKind.AlreadySignedInAllOrgs:
                // Everything this paste could reach was already stored, so it repaired them instead
                // of adding anything - and deliberately did not move the user off what they were
                // viewing (R24).
                ShowManualStatus(
                    AuthManager.RepairConfirmation(result.RefreshedCount, result.ActiveAccountRefreshed),
                    isError: false);
                CookieHeaderBox.Clear();
                OrgPickerPanel.Visibility = Visibility.Collapsed;
                RebuildAccountList();
                break;

            case ManualSignInResult.ResultKind.NeedsOrgChoice:
                ShowManualStatus("Multiple organizations found. Choose one to finish.", isError: false);
                _orgChoices = result.Orgs;
                OrgPicker.ItemsSource = OrgPickerView.BuildDisambiguatedLabels(
                    result.Orgs ?? Array.Empty<Organization>(),
                    _accountStore.Accounts.Select(a => a.OrganizationId).ToList());
                if (result.Orgs is { Count: > 0 })
                {
                    OrgPicker.SelectedIndex = 0;
                }
                OrgPickerPanel.Visibility = Visibility.Visible;
                break;

            case ManualSignInResult.ResultKind.InvalidInput:
                ShowManualStatus(
                    "That doesn't look like a cookie header. Paste the full Cookie value, or your sessionKey.",
                    isError: true);
                break;

            case ManualSignInResult.ResultKind.AuthFailed:
                ShowManualStatus(
                    result.SuggestFullHeader
                        ? "Couldn't verify. A bare sessionKey is usually blocked by Cloudflare, so paste the full Cookie header instead."
                        : "Couldn't verify those cookies. They may have expired. Sign in to claude.ai again and copy a fresh header.",
                    isError: true);
                break;

            case ManualSignInResult.ResultKind.NoOrganizations:
                ShowManualStatus(
                    "No Claude organizations were found for this account. A Pro or Max plan may be required.",
                    isError: true);
                break;

            case ManualSignInResult.ResultKind.AccountLimitReached:
                ShowManualStatus(
                    $"You can have up to {AccountStore.MaxAccounts} accounts. Remove one first.",
                    isError: true);
                break;

            case ManualSignInResult.ResultKind.ConnectionError:
                ShowManualStatus("Connection error. Please try again.", isError: true);
                break;

            case ManualSignInResult.ResultKind.SaveFailed:
                ShowManualStatus(
                    "Couldn't save the account. Check that your user folder is writable, then try again.",
                    isError: true);
                break;
        }
    }

    private void ShowManualStatus(string text, bool isError)
    {
        ManualStatus.Text = text;
        ManualStatus.Foreground = (Brush)FindResource(isError ? "SettingsErrorTextBrush" : "SettingsSuccessTextBrush");
        ManualStatus.Visibility = Visibility.Visible;
        AutomationProperties.SetName(ManualStatus, text);
    }

    // MARK: - Version / update row

    /// The GitHub Releases page the raw-exe build points at, since it cannot self-update.
    private const string ReleasesPageUrl = "https://github.com/Reebz/claude-battery/releases";

    /// <summary>
    /// Re-read the update service and repaint the About row. Internal so the integration layer can
    /// call it when a background check completes while the window is open. The status text comes
    /// from <see cref="UpdateService.UpdateRowText"/> (available > not-installed > checked > failed
    /// > checking); the button is "Update to vX" for a known update, "Open releases page" on a build
    /// the updater cannot manage, and hidden otherwise.
    /// </summary>
    internal void RefreshUpdateRow()
    {
        var available = _updateService.AvailableUpdate;
        var installed = _updateService.IsUpdaterInstalled;

        UpdateStatus.Text = UpdateService.UpdateRowText(
            installed,
            available?.Version,
            _updateService.HasChecked,
            _updateService.LastCheckFailed);

        if (available is not null)
        {
            UpdateActionButton.Content = $"Update to v{available.Version}";
            UpdateActionButton.Visibility = Visibility.Visible;
        }
        else if (!installed)
        {
            UpdateActionButton.Content = "Open releases page";
            UpdateActionButton.Visibility = Visibility.Visible;
        }
        else
        {
            UpdateActionButton.Visibility = Visibility.Collapsed;
        }
    }

    private async void OnUpdateActionClicked(object sender, RoutedEventArgs e)
    {
        if (!_updateService.IsUpdaterInstalled)
        {
            // Raw exe: nothing to apply, hand the user to the download page instead.
            try
            {
                Process.Start(new ProcessStartInfo(ReleasesPageUrl) { UseShellExecute = true });
            }
            catch (Exception)
            {
                UpdateStatus.Text = $"Couldn't open the browser. Visit {ReleasesPageUrl}";
            }
            return;
        }

        UpdateActionButton.IsEnabled = false;
        try
        {
            // ConfigureAwait(true): explicit UI-thread resume for this async-void handler (the U7
            // convention from LoginWindow), so the finally re-enables the button on the UI thread.
            await _updateService.ApplyUpdateAsync().ConfigureAwait(true);
            // On a real install ApplyUpdateAsync relaunches and never returns here; if it returns
            // false (dev/test/no-update) just leave the row as-is.
        }
        catch (Exception)
        {
            UpdateStatus.Text = "Update failed. Try again later.";
        }
        finally
        {
            UpdateActionButton.IsEnabled = true;
        }
    }
}
