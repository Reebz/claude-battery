using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;

namespace ClaudeBatteryWin.Views;

/// <summary>
/// Settings surface (U11), the Windows port of the Mac SettingsView. Hosts the launch-at-login,
/// notifications, and session-countdown toggles; the account list with inline nickname edit and
/// two-step remove; the manual cookie-paste sign-in; and the version/update row.
///
/// The window is constructed by the integration layer with the live services. The icon style is
/// fixed for v1 (no picker). Per-account threshold sliders appear only while notifications are
/// enabled, mirroring the Mac (which shows the slider per account only when notificationsEnabled).
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

    /// The account currently awaiting a two-step remove confirm, or null. Mirrors the Mac
    /// confirmRemoveId.
    private Guid? _confirmRemoveId;

    /// The account whose nickname is being edited inline, or null. Drives the label/edit-field swap.
    private Guid? _editingNicknameId;

    public SettingsWindow(
        AccountStore accountStore,
        ManualSignIn manualSignIn,
        AutostartService autostart,
        IAppSettings settings,
        UpdateService updateService)
    {
        _accountStore = accountStore ?? throw new ArgumentNullException(nameof(accountStore));
        _manualSignIn = manualSignIn ?? throw new ArgumentNullException(nameof(manualSignIn));
        _autostart = autostart ?? throw new ArgumentNullException(nameof(autostart));
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _updateService = updateService ?? throw new ArgumentNullException(nameof(updateService));

        InitializeComponent();

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
        _suppressToggleEvents = false;

        RebuildAccountList();
        RefreshUpdateRow();
    }

    // Guards the initial IsChecked assignment in OnLoaded so it does not re-enter the registry/disk.
    private bool _suppressToggleEvents;

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
                Text = account.DisplayName,
                Foreground = (Brush)FindResource("SettingsForegroundBrush"),
                ToolTip = "Click to rename",
                Cursor = Cursors.Hand,
                Tag = account.Id,
            };
            AutomationProperties.SetName(nameLabel, $"Account {account.DisplayName}, click to rename");
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
            AutomationProperties.SetName(remove, $"Remove account {account.DisplayName}");
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

    /// Raised when the user asks to add an account via the WebView2 login flow (U6/U7). The
    /// integration layer wires this to AuthManager.PresentLogin; kept as an event so this window
    /// does not depend on the not-yet-written auth manager.
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
            result = await _manualSignIn.SignInAsync(pasted);
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
        if (OrgPicker.SelectedItem is not Organization org)
        {
            return;
        }

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
                ShowManualStatus($"Signed in as {result.DisplayName}.", isError: false);
                CookieHeaderBox.Clear();
                OrgPickerPanel.Visibility = Visibility.Collapsed;
                RebuildAccountList();
                break;

            case ManualSignInResult.ResultKind.NeedsOrgChoice:
                ShowManualStatus("Multiple organizations found. Choose one to finish.", isError: false);
                OrgPicker.ItemsSource = result.Orgs;
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

    private void RefreshUpdateRow()
    {
        var available = _updateService.AvailableUpdate;
        if (available is not null)
        {
            UpdateStatus.Text = $"Update available: v{available.Version}";
            UpdateActionButton.Content = $"Update to v{available.Version}";
            UpdateActionButton.Visibility = Visibility.Visible;
        }
        else if (_updateService.HasChecked)
        {
            UpdateStatus.Text = "Up to date.";
            UpdateActionButton.Visibility = Visibility.Collapsed;
        }
        else
        {
            UpdateStatus.Text = "Checking for updates...";
            UpdateActionButton.Visibility = Visibility.Collapsed;
        }
    }

    private async void OnUpdateActionClicked(object sender, RoutedEventArgs e)
    {
        UpdateActionButton.IsEnabled = false;
        try
        {
            await _updateService.ApplyUpdateAsync();
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
