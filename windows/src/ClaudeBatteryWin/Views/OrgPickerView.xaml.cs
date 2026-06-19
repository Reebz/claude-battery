using System.Windows;
using ClaudeBatteryWin.Models;
using ClaudeBatteryWin.Services;

namespace ClaudeBatteryWin.Views;

/// <summary>
/// The multi-org picker window (U7), shown when discovery returns multiple orgs with no existing
/// account to auto-match. It disambiguates duplicate display names ("Organization", or two orgs
/// sharing a name) exactly as the Mac picker did, and returns the chosen org or null on cancel.
/// </summary>
public partial class OrgPickerView : Window
{
    private readonly IReadOnlyList<Organization> _orgs;

    /// The org the user chose, or null if the picker was cancelled.
    public Organization? SelectedOrg { get; private set; }

    public OrgPickerView(IReadOnlyList<Organization> orgs)
    {
        _orgs = orgs;
        InitializeComponent();

        foreach (var label in BuildDisambiguatedLabels(orgs))
        {
            OrgCombo.Items.Add(label);
        }

        if (OrgCombo.Items.Count > 0)
        {
            OrgCombo.SelectedIndex = 0;
        }
    }

    /// <summary>
    /// Picker labels with the Mac disambiguation: a generic "Organization" name becomes
    /// "Organization N" by position; two real orgs sharing a display name get a "(2)", "(3)" suffix
    /// by order of appearance. Pure + static so it is unit-testable without a window.
    /// </summary>
    public static IReadOnlyList<string> BuildDisambiguatedLabels(IReadOnlyList<Organization> orgs)
    {
        var labels = new List<string>(orgs.Count);
        for (var index = 0; index < orgs.Count; index++)
        {
            var org = orgs[index];
            string title;
            if (org.DisplayName == "Organization")
            {
                title = $"Organization {index + 1}";
            }
            else
            {
                title = org.DisplayName;
                var duplicateCount = 0;
                for (var j = 0; j < index; j++)
                {
                    if (orgs[j].DisplayName == org.DisplayName)
                    {
                        duplicateCount++;
                    }
                }

                if (duplicateCount > 0)
                {
                    title = $"{title} ({duplicateCount + 1})";
                }
            }

            labels.Add(title);
        }

        return labels;
    }

    private void OnSelectClicked(object sender, RoutedEventArgs e)
    {
        var index = OrgCombo.SelectedIndex;
        SelectedOrg = index >= 0 && index < _orgs.Count ? _orgs[index] : null;
        DialogResult = SelectedOrg is not null;
        Close();
    }

    private void OnCancelClicked(object sender, RoutedEventArgs e)
    {
        SelectedOrg = null;
        DialogResult = false;
        Close();
    }
}

/// <summary>
/// The production <see cref="IOrgPicker"/>: hosts <see cref="OrgPickerView"/> as a modal dialog and
/// awaits the user's choice. <see cref="CancelPending"/> honors the resume-once contract: a teardown
/// (login window closed / timed out) closes the open dialog so the awaiting discovery task resumes
/// with null instead of leaking - exactly as the Mac <c>resumeOrgPicker</c> did.
/// </summary>
public sealed class OrgPicker : IOrgPicker
{
    private readonly Func<Window?> _ownerProvider;
    private OrgPickerView? _open;

    /// <param name="ownerProvider">
    /// Returns the window to center the picker over (the login window). May return null; the picker
    /// then centers on screen.
    /// </param>
    public OrgPicker(Func<Window?> ownerProvider)
    {
        _ownerProvider = ownerProvider ?? throw new ArgumentNullException(nameof(ownerProvider));
    }

    public Task<Organization?> PickAsync(IReadOnlyList<Organization> orgs, CancellationToken cancellationToken)
    {
        var view = new OrgPickerView(orgs);
        if (_ownerProvider() is { } owner)
        {
            view.Owner = owner;
        }

        _open = view;

        // If the discovery token is cancelled (timeout/teardown) while the dialog is up, close it so
        // ShowDialog returns and we resolve null.
        using var registration = cancellationToken.Register(() =>
        {
            view.Dispatcher.Invoke(() =>
            {
                if (view.IsLoaded)
                {
                    view.Close();
                }
            });
        });

        view.ShowDialog();
        _open = null;
        return Task.FromResult(view.SelectedOrg);
    }

    public void CancelPending()
    {
        var open = _open;
        if (open is null)
        {
            return;
        }

        open.Dispatcher.Invoke(() =>
        {
            if (open.IsLoaded)
            {
                open.Close();
            }
        });
    }
}
