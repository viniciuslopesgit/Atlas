using Atlas.Models;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Atlas.Views;

public partial class CreateUserDialog : Window
{
    public bool           Confirmed { get; private set; }
    public CreateUserOptions? Result { get; private set; }

    private int _step = 1;
    private string _generatedPassword = string.Empty;

    private readonly IReadOnlyList<IamGroupModel>  _availableGroups;
    private readonly IReadOnlyList<IamPolicyModel> _availablePolicies;

    // Per-item checkboxes
    private readonly List<(CheckBox Box, string GroupName)>  _groupBoxes  = [];
    private readonly List<(CheckBox Box, string PolicyArn)>  _policyBoxes = [];

    public CreateUserDialog(
        IReadOnlyList<IamGroupModel>  availableGroups,
        IReadOnlyList<IamPolicyModel> availablePolicies)
    {
        InitializeComponent();

        _availableGroups   = availableGroups;
        _availablePolicies = availablePolicies;

        ContentRendered += OnContentRendered;
    }

    private void OnContentRendered(object? sender, EventArgs e)
    {
        _generatedPassword = GeneratePassword();
        TxtGeneratedPass.Text = _generatedPassword;

        BuildGroupsList();
        BuildPoliciesList();

        UpdateStepper();

        Activate();
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Input,
            new Action(() => { TxtUserName.Focus(); }));
    }

    // ── Group / policy checkbox lists ────────────────────────────────────

    private void BuildGroupsList()
    {
        GroupsList.Children.Clear();
        _groupBoxes.Clear();

        foreach (var g in _availableGroups)
        {
            var row = new Grid { Margin = new Thickness(6, 3, 6, 3) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var cb = new CheckBox { Style = (Style)FindResource("FormCheck"), VerticalAlignment = VerticalAlignment.Center };
            var name = new TextBlock
            {
                Text = g.GroupName, FontSize = 13,
                Foreground = (Brush)FindResource("TextPrimaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0),
            };
            var users = new TextBlock
            {
                Text = $"{g.UserCount} users", FontSize = 11,
                Foreground = (Brush)FindResource("TextMutedBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            };

            Grid.SetColumn(cb,    0);
            Grid.SetColumn(name,  1);
            Grid.SetColumn(users, 2);
            row.Children.Add(cb);
            row.Children.Add(name);
            row.Children.Add(users);
            GroupsList.Children.Add(row);
            _groupBoxes.Add((cb, g.GroupName));
        }

        TxtNoGroups.Visibility = _availableGroups.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void BuildPoliciesList()
    {
        PoliciesList.Children.Clear();
        _policyBoxes.Clear();

        foreach (var p in _availablePolicies)
        {
            var row = new Grid { Margin = new Thickness(6, 3, 6, 3) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var cb = new CheckBox { Style = (Style)FindResource("FormCheck"), VerticalAlignment = VerticalAlignment.Center };
            var name = new TextBlock
            {
                Text = p.PolicyName, FontSize = 13,
                Foreground = (Brush)FindResource("TextPrimaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0),
            };
            var attachments = new TextBlock
            {
                Text = $"{p.AttachmentCount} attachments", FontSize = 11,
                Foreground = (Brush)FindResource("TextMutedBrush"),
                VerticalAlignment = VerticalAlignment.Center,
            };

            Grid.SetColumn(cb,          0);
            Grid.SetColumn(name,        1);
            Grid.SetColumn(attachments, 2);
            row.Children.Add(cb);
            row.Children.Add(name);
            row.Children.Add(attachments);
            PoliciesList.Children.Add(row);
            _policyBoxes.Add((cb, p.Arn));
        }

        TxtNoPolicies.Visibility = _availablePolicies.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    // ── Step navigation ───────────────────────────────────────────────────

    private void Next_Click(object sender, RoutedEventArgs e)
    {
        if (_step == 1 && !ValidateStep1()) return;
        if (_step == 3) { Finish(); return; }

        _step++;
        if (_step == 3) PopulateReview();
        UpdateStepper();
    }

    private void Back_Click(object sender, RoutedEventArgs e)
    {
        if (_step <= 1) return;
        _step--;
        UpdateStepper();
    }

    private void UpdateStepper()
    {
        Step1Panel.Visibility = _step == 1 ? Visibility.Visible : Visibility.Collapsed;
        Step2Panel.Visibility = _step == 2 ? Visibility.Visible : Visibility.Collapsed;
        Step3Panel.Visibility = _step == 3 ? Visibility.Visible : Visibility.Collapsed;

        BtnBack.Visibility    = _step > 1  ? Visibility.Visible : Visibility.Collapsed;
        BtnNextText.Text      = _step == 3 ? "Create user" : "Next";

        StepBadge.Text = _step switch
        {
            1 => "Step 1 of 3 — Specify user details",
            2 => "Step 2 of 3 — Set permissions",
            3 => "Step 3 of 3 — Review and create",
            _ => string.Empty
        };

        var accent  = (Brush)FindResource("AccentBrush");
        var border  = (Brush)FindResource("BorderBrush");
        var primary = (Brush)FindResource("TextPrimaryBrush");
        var muted   = (Brush)FindResource("TextMutedBrush");
        var white   = Brushes.White;
        var accentBg = new SolidColorBrush(Color.FromArgb(30,
            ((SolidColorBrush)accent).Color.R,
            ((SolidColorBrush)accent).Color.G,
            ((SolidColorBrush)accent).Color.B));

        void SetCircle(Border circle, TextBlock text, TextBlock label, int num)
        {
            bool active   = _step == num;
            bool complete = _step > num;
            circle.Background   = active || complete ? accent : Brushes.Transparent;
            circle.BorderBrush  = active || complete ? accent : border;
            circle.BorderThickness = new Thickness(active || complete ? 0 : 1.5);
            text.Foreground     = active || complete ? white  : muted;
            text.Text           = complete ? "✓" : num.ToString();
            label.Foreground    = active ? primary : muted;
            label.FontWeight    = active ? FontWeights.SemiBold : FontWeights.Normal;
        }

        SetCircle(Circle1, CircleText1, StepLabel1, 1);
        SetCircle(Circle2, CircleText2, StepLabel2, 2);
        SetCircle(Circle3, CircleText3, StepLabel3, 3);

        StepLine1.Background = _step > 1 ? accent : border;
        StepLine2.Background = _step > 2 ? accent : border;
    }

    // ── Step 1 validation ─────────────────────────────────────────────────

    private void TxtUserName_Changed(object sender, TextChangedEventArgs e)
        => ValidateStep1(showError: false);

    private bool ValidateStep1(bool showError = true)
    {
        var name = TxtUserName.Text.Trim();
        string? error = null;

        if (name.Length == 0)
            error = "Username is required.";
        else if (name.Length > 64)
            error = "Username must be 64 characters or fewer.";
        else if (!System.Text.RegularExpressions.Regex.IsMatch(name, @"^[A-Za-z0-9+=,.@_\-]+$"))
            error = "Invalid characters. Allowed: A-Z, a-z, 0-9, + = , . @ _ -";

        if (showError || error == null)
        {
            TxtNameError.Text       = error ?? string.Empty;
            TxtNameError.Visibility = error != null ? Visibility.Visible : Visibility.Collapsed;
        }

        return error == null;
    }

    // ── Console access toggles ────────────────────────────────────────────

    private void ConsoleAccess_Changed(object sender, RoutedEventArgs e)
    {
        if (PnlConsoleAccess == null) return;
        PnlConsoleAccess.Visibility = ChkConsoleAccess.IsChecked == true
            ? Visibility.Visible : Visibility.Collapsed;
    }

    private void PasswordType_Changed(object sender, RoutedEventArgs e)
    {
        if (PnlCustomPass == null || PnlAutoPass == null) return;
        bool custom = RdoCustomPass.IsChecked == true;
        PnlCustomPass.Visibility = custom ? Visibility.Visible  : Visibility.Collapsed;
        PnlAutoPass.Visibility   = custom ? Visibility.Collapsed : Visibility.Visible;
    }

    private bool _revealPassword;
    private void Reveal_Click(object sender, RoutedEventArgs e)
    {
        _revealPassword = !_revealPassword;
        if (_revealPassword)
        {
            TxtPasswordVisible.Text = TxtPassword.Password;
            TxtPasswordVisibleBorder.Visibility = Visibility.Visible;
            TxtPassword.Visibility              = Visibility.Collapsed;
        }
        else
        {
            TxtPassword.Password                = TxtPasswordVisible.Text;
            TxtPassword.Visibility              = Visibility.Visible;
            TxtPasswordVisibleBorder.Visibility = Visibility.Collapsed;
        }
    }

    private void TxtPassword_Changed(object sender, RoutedEventArgs e)
    {
        if (_revealPassword) TxtPasswordVisible.Text = TxtPassword.Password;
    }

    private void PasswordVisible_Changed(object sender, TextChangedEventArgs e)
    {
        if (_revealPassword) TxtPassword.Password = TxtPasswordVisible.Text;
    }

    private void CopyPassword_Click(object sender, RoutedEventArgs e)
        => Clipboard.SetText(_generatedPassword);

    // ── Permission mode toggle ────────────────────────────────────────────

    private void PermMode_Changed(object sender, RoutedEventArgs e)
    {
        if (PnlGroups == null) return;
        PnlGroups.Visibility         = RdoAddToGroup.IsChecked     == true ? Visibility.Visible : Visibility.Collapsed;
        PnlCopyPerms.Visibility      = RdoCopyPerms.IsChecked      == true ? Visibility.Visible : Visibility.Collapsed;
        PnlAttachPolicies.Visibility = RdoAttachPolicies.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    // ── Review ────────────────────────────────────────────────────────────

    private void PopulateReview()
    {
        ReviewUserName.Text = TxtUserName.Text.Trim();

        if (ChkConsoleAccess.IsChecked == true)
        {
            ReviewConsoleType.Text  = RdoAutoPass.IsChecked == true ? "Autogenerated" : "Custom";
            ReviewPasswordReset.Text = ChkPasswordReset.IsChecked == true ? "Yes" : "No";
        }
        else
        {
            ReviewConsoleType.Text  = "None";
            ReviewPasswordReset.Text = "—";
        }

        var items = new List<string>();

        if (RdoAddToGroup.IsChecked == true)
        {
            ReviewPermType.Text = "Add to group";
            items = _groupBoxes.Where(g => g.Box.IsChecked == true).Select(g => g.GroupName).ToList();
        }
        else if (RdoCopyPerms.IsChecked == true)
        {
            ReviewPermType.Text = "Copy permissions from user";
            var from = TxtCopyFrom.Text.Trim();
            if (!string.IsNullOrEmpty(from)) items.Add(from);
        }
        else if (RdoAttachPolicies.IsChecked == true)
        {
            ReviewPermType.Text = "Attach policies directly";
            items = _policyBoxes.Where(p => p.Box.IsChecked == true)
                                 .Select(p => _availablePolicies.First(x => x.Arn == p.PolicyArn).PolicyName)
                                 .ToList();
            var extra = TxtExtraArn.Text.Trim();
            if (!string.IsNullOrEmpty(extra)) items.Add(extra);
        }
        else
        {
            ReviewPermType.Text = "No permissions assigned";
        }

        ReviewPermList.ItemsSource = items;
        ReviewPermNone.Visibility  = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    // ── Finish ────────────────────────────────────────────────────────────

    private void Finish()
    {
        var name = TxtUserName.Text.Trim();

        string password = string.Empty;
        if (ChkConsoleAccess.IsChecked == true)
        {
            password = RdoAutoPass.IsChecked == true
                ? _generatedPassword
                : (_revealPassword ? TxtPasswordVisible.Text : TxtPassword.Password);
        }

        CreateUserPermissionMode mode;
        var groups     = new List<string>();
        var policyArns = new List<string>();
        string? copyFrom = null;

        if (RdoAddToGroup.IsChecked == true)
        {
            mode   = CreateUserPermissionMode.AddToGroup;
            groups = _groupBoxes.Where(g => g.Box.IsChecked == true).Select(g => g.GroupName).ToList();
        }
        else if (RdoCopyPerms.IsChecked == true)
        {
            mode     = CreateUserPermissionMode.CopyPermissions;
            copyFrom = TxtCopyFrom.Text.Trim();
        }
        else if (RdoAttachPolicies.IsChecked == true)
        {
            mode       = CreateUserPermissionMode.AttachPolicies;
            policyArns = _policyBoxes.Where(p => p.Box.IsChecked == true).Select(p => p.PolicyArn).ToList();
            var extra  = TxtExtraArn.Text.Trim();
            if (!string.IsNullOrEmpty(extra)) policyArns.Add(extra);
        }
        else
        {
            mode = CreateUserPermissionMode.None;
        }

        Result = new CreateUserOptions
        {
            UserName             = name,
            ConsoleAccess        = ChkConsoleAccess.IsChecked == true,
            Password             = password,
            RequirePasswordReset = ChkPasswordReset.IsChecked == true,
            PermissionMode       = mode,
            GroupNames           = groups,
            PolicyArns           = policyArns,
            CopyFromUser         = copyFrom,
        };

        Confirmed = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        Confirmed = false;
        Close();
    }

    private void DragHandle_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed && e.OriginalSource is not Button)
            DragMove();
    }

    // ── Password generator ────────────────────────────────────────────────

    private static string GeneratePassword()
    {
        const string upper   = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        const string lower   = "abcdefghijklmnopqrstuvwxyz";
        const string digits  = "0123456789";
        const string special = "!@#$%^&*_+-=";
        const string all     = upper + lower + digits + special;

        var buf   = RandomNumberGenerator.GetBytes(20);
        var chars = new char[16];

        chars[0] = upper  [buf[0]  % upper.Length];
        chars[1] = lower  [buf[1]  % lower.Length];
        chars[2] = digits [buf[2]  % digits.Length];
        chars[3] = special[buf[3]  % special.Length];
        for (int i = 4; i < 16; i++)
            chars[i] = all[buf[i] % all.Length];

        // Fisher-Yates shuffle using remaining bytes
        for (int i = 15; i > 0; i--)
        {
            int j = buf[i] % (i + 1);
            (chars[i], chars[j]) = (chars[j], chars[i]);
        }

        return new string(chars);
    }
}
