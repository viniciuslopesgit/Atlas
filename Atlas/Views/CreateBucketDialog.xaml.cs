using Atlas.Models;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Atlas.Views;

public partial class CreateBucketDialog : Window
{
    // ── Result ────────────────────────────────────────────────────
    public bool Confirmed { get; private set; }
    public CreateBucketOptions? Result { get; private set; }

    // ── Regions ───────────────────────────────────────────────────
    private static readonly (string Id, string Label)[] Regions =
    [
        ("us-east-1",      "US East (N. Virginia)          us-east-1"),
        ("us-east-2",      "US East (Ohio)                 us-east-2"),
        ("us-west-1",      "US West (N. California)        us-west-1"),
        ("us-west-2",      "US West (Oregon)               us-west-2"),
        ("ca-central-1",   "Canada (Central)               ca-central-1"),
        ("eu-west-1",      "Europe (Ireland)               eu-west-1"),
        ("eu-west-2",      "Europe (London)                eu-west-2"),
        ("eu-west-3",      "Europe (Paris)                 eu-west-3"),
        ("eu-central-1",   "Europe (Frankfurt)             eu-central-1"),
        ("eu-central-2",   "Europe (Zurich)                eu-central-2"),
        ("eu-north-1",     "Europe (Stockholm)             eu-north-1"),
        ("eu-south-1",     "Europe (Milan)                 eu-south-1"),
        ("eu-south-2",     "Europe (Spain)                 eu-south-2"),
        ("ap-northeast-1", "Asia Pacific (Tokyo)           ap-northeast-1"),
        ("ap-northeast-2", "Asia Pacific (Seoul)           ap-northeast-2"),
        ("ap-northeast-3", "Asia Pacific (Osaka)           ap-northeast-3"),
        ("ap-southeast-1", "Asia Pacific (Singapore)       ap-southeast-1"),
        ("ap-southeast-2", "Asia Pacific (Sydney)          ap-southeast-2"),
        ("ap-southeast-3", "Asia Pacific (Jakarta)         ap-southeast-3"),
        ("ap-south-1",     "Asia Pacific (Mumbai)          ap-south-1"),
        ("ap-south-2",     "Asia Pacific (Hyderabad)       ap-south-2"),
        ("ap-east-1",      "Asia Pacific (Hong Kong)       ap-east-1"),
        ("me-south-1",     "Middle East (Bahrain)          me-south-1"),
        ("me-central-1",   "Middle East (UAE)              me-central-1"),
        ("af-south-1",     "Africa (Cape Town)             af-south-1"),
        ("sa-east-1",      "South America (São Paulo)      sa-east-1"),
        ("il-central-1",   "Israel (Tel Aviv)              il-central-1"),
    ];

    private readonly List<(TextBox Key, TextBox Value)> _tagRows = [];
    private bool _suppressBlockSync;

    // ── Constructor ───────────────────────────────────────────────
    public CreateBucketDialog(string defaultRegion)
    {
        InitializeComponent();

        // Populate regions
        foreach (var (id, label) in Regions)
            CmbRegion.Items.Add(new ComboBoxItem { Content = label, Tag = id });

        // Pre-select the default region
        var match = CmbRegion.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(i => (string)i.Tag == defaultRegion)
            ?? CmbRegion.Items[0] as ComboBoxItem;
        CmbRegion.SelectedItem = match;

        // Focus name field after load
        Loaded += (_, _) =>
        {
            TxtBucketName.Focus();
            UpdateRegionBadge();
        };
    }

    // ── Region display ────────────────────────────────────────────
    private void CmbRegion_SelectionChanged(object sender, SelectionChangedEventArgs e)
        => UpdateRegionBadge();

    private void UpdateRegionBadge()
    {
        var regionId = SelectedRegionId();
        RegionBadgeText.Text = $"Region: {regionId}";
    }

    private string SelectedRegionId()
        => (CmbRegion.SelectedItem as ComboBoxItem)?.Tag as string ?? "us-east-1";

    // ── Bucket name validation ────────────────────────────────────
    private static readonly Regex ValidName = new(@"^[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]$");
    private static readonly Regex NoConsecutivePeriods = new(@"\.\.");
    private static readonly Regex NoIpAddress = new(@"^\d+\.\d+\.\d+\.\d+$");

    private void TxtBucketName_TextChanged(object sender, TextChangedEventArgs e)
        => ValidateName(TxtBucketName.Text.Trim());

    private bool ValidateName(string name)
    {
        string? error = null;

        if (name.Length < 3)
            error = "Bucket name must be at least 3 characters.";
        else if (name.Length > 63)
            error = "Bucket name must be 63 characters or fewer.";
        else if (!ValidName.IsMatch(name))
            error = "Only lowercase letters (a-z), numbers, hyphens (-) and periods (.) allowed. Must start and end with a letter or number.";
        else if (NoConsecutivePeriods.IsMatch(name))
            error = "Bucket name cannot contain consecutive periods (..).";
        else if (NoIpAddress.IsMatch(name))
            error = "Bucket name cannot be formatted as an IP address (e.g. 192.168.0.1).";

        TxtNameError.Text       = error ?? string.Empty;
        TxtNameError.Visibility = error != null ? Visibility.Visible : Visibility.Collapsed;
        return error == null;
    }

    // ── Block all public access (master toggle) ───────────────────
    private void BlockAll_Checked(object sender, RoutedEventArgs e)
    {
        // Guard against firing during InitializeComponent before child controls exist
        if (_suppressBlockSync || ChkBlockNewAcls == null) return;
        _suppressBlockSync = true;
        ChkBlockNewAcls.IsChecked       = true;
        ChkBlockExistingAcls.IsChecked  = true;
        ChkBlockNewPolicies.IsChecked   = true;
        ChkBlockCrossAccount.IsChecked  = true;
        _suppressBlockSync = false;
    }

    private void BlockAll_Unchecked(object sender, RoutedEventArgs e)
    {
        // do not cascade — let user decide individually
    }

    private void IndividualBlock_Changed(object sender, RoutedEventArgs e)
    {
        if (_suppressBlockSync || ChkBlockAll == null) return;
        _suppressBlockSync = true;
        bool allOn = ChkBlockNewAcls.IsChecked     == true
                  && ChkBlockExistingAcls.IsChecked == true
                  && ChkBlockNewPolicies.IsChecked   == true
                  && ChkBlockCrossAccount.IsChecked  == true;
        ChkBlockAll.IsChecked = allOn;
        _suppressBlockSync = false;
    }

    // ── Encryption selection ──────────────────────────────────────
    private void Encryption_Changed(object sender, RoutedEventArgs e)
    {
        bool kms    = RdoSseKms.IsChecked  == true;
        bool dsse   = RdoDsseKms.IsChecked == true;
        bool needKms = kms || dsse;

        PnlKmsOptions.Visibility  = needKms   ? Visibility.Visible   : Visibility.Collapsed;
        PnlBucketKey.Visibility   = kms        ? Visibility.Visible   : Visibility.Collapsed;
    }

    // ── Object Lock → force versioning ───────────────────────────
    private void ObjectLock_Changed(object sender, RoutedEventArgs e)
    {
        if (RdoVersioningEnable == null) return;
        if (RdoLockEnable.IsChecked == true)
        {
            RdoVersioningEnable.IsChecked  = true;
            RdoVersioningDisable.IsEnabled = false;
        }
        else
        {
            RdoVersioningDisable.IsEnabled = true;
        }
    }

    // ── Tags ──────────────────────────────────────────────────────
    private void AddTag_Click(object sender, RoutedEventArgs e)
    {
        if (_tagRows.Count >= 50) return;

        var keyBox = new TextBox
        {
            Margin      = new Thickness(0, 0, 6, 0),
            Width       = 180,
            Height      = 30,
            ToolTip     = "Tag key"
        };
        var valBox = new TextBox
        {
            Margin  = new Thickness(0),
            Height  = 30,
            ToolTip = "Tag value"
        };
        var removeBtn = new Button
        {
            Style   = (Style)FindResource("GhostButton"),
            Padding = new Thickness(6, 0, 6, 0),
            Margin  = new Thickness(6, 0, 0, 0),
            Height  = 30,
            Content = new TextBlock
            {
                Text       = "",
                FontFamily = new FontFamily("Segoe MDL2 Assets"),
                FontSize   = 11,
                Foreground = (Brush)FindResource("DangerBrush")
            }
        };

        var row = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(180) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        Grid.SetColumn(keyBox,    0);
        Grid.SetColumn(valBox,    1);
        Grid.SetColumn(removeBtn, 2);

        row.Children.Add(keyBox);
        row.Children.Add(valBox);
        row.Children.Add(removeBtn);

        var tagPair = (keyBox, valBox);
        _tagRows.Add(tagPair);
        PnlTags.Children.Add(row);
        TxtTagsHint.Visibility = Visibility.Collapsed;

        removeBtn.Click += (_, _) =>
        {
            PnlTags.Children.Remove(row);
            _tagRows.Remove(tagPair);
            TxtTagsHint.Visibility = _tagRows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        };

        keyBox.Focus();
    }

    // ── Create ────────────────────────────────────────────────────
    private void Create_Click(object sender, RoutedEventArgs e)
    {
        var name = TxtBucketName.Text.Trim();
        if (!ValidateName(name)) return;

        var tags = new Dictionary<string, string>();
        foreach (var (k, v) in _tagRows)
        {
            var key   = k.Text.Trim();
            var value = v.Text.Trim();
            if (!string.IsNullOrEmpty(key))
                tags[key] = value;
        }

        Result = new CreateBucketOptions
        {
            BucketName            = name,
            Region                = SelectedRegionId(),
            AclsEnabled           = RdoAclsEnabled.IsChecked == true,
            BlockNewAcls          = ChkBlockNewAcls.IsChecked     == true,
            BlockExistingAcls     = ChkBlockExistingAcls.IsChecked == true,
            BlockNewPublicPolicies = ChkBlockNewPolicies.IsChecked  == true,
            BlockCrossAccount     = ChkBlockCrossAccount.IsChecked  == true,
            VersioningEnabled     = RdoVersioningEnable.IsChecked  == true,
            Encryption            = RdoSseKms.IsChecked  == true ? BucketEncryptionType.SSE_KMS
                                  : RdoDsseKms.IsChecked == true ? BucketEncryptionType.DSSE_KMS
                                  : BucketEncryptionType.SSE_S3,
            KmsKeyArn             = string.IsNullOrWhiteSpace(TxtKmsKey.Text) ? null : TxtKmsKey.Text.Trim(),
            BucketKeyEnabled      = ChkBucketKey.IsChecked == true,
            Tags                  = tags,
            ObjectLockEnabled     = RdoLockEnable.IsChecked == true
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
        if (e.ButtonState == MouseButtonState.Pressed) DragMove();
    }
}
