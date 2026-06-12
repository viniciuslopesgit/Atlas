using Atlas.Services;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Atlas.Views;

public partial class AddAccountDialog : Window
{
    public bool    AccountAdded { get; private set; }
    public string? NextAction   { get; private set; }
    public string? StackName    { get; private set; }
    public string? ProjectPath  { get; private set; }

    private readonly IAccountService _accounts;
    private bool _isValidating;
    private bool _secretVisible;
    private string? _importProjectPath;

    private static readonly (string Code, string Short)[] Regions =
    [
        ("us-east-1",      "N. Virginia"),
        ("us-east-2",      "Ohio"),
        ("us-west-1",      "N. California"),
        ("us-west-2",      "Oregon"),
        ("ca-central-1",   "Canada Central"),
        ("eu-west-1",      "Ireland"),
        ("eu-west-2",      "London"),
        ("eu-west-3",      "Paris"),
        ("eu-central-1",   "Frankfurt"),
        ("eu-north-1",     "Stockholm"),
        ("ap-southeast-1", "Singapore"),
        ("ap-southeast-2", "Sydney"),
        ("ap-northeast-1", "Tokyo"),
        ("ap-northeast-2", "Seoul"),
        ("ap-south-1",     "Mumbai"),
        ("sa-east-1",      "Sao Paulo"),
    ];

    public AddAccountDialog(IAccountService accounts)
    {
        _accounts = accounts;
        InitializeComponent();

        foreach (var (code, shortName) in Regions)
            CmbRegion.Items.Add(new ComboBoxItem { Content = $"{shortName}  {code}", Tag = code });

        CmbRegion.SelectedIndex = 0;

        BtnAdd.Background = (Brush)FindResource("AccentBrush");

        Loaded += (_, _) => TxtName.Focus();
    }

    private async void Add_Click(object sender, RoutedEventArgs e)
    {
        var name      = TxtName.Text.Trim();
        var accessKey = TxtAccessKey.Text.Trim();
        var secretKey = _secretVisible ? TxtSecretKey.Text : PbSecretKey.Password;
        var region    = ((CmbRegion.SelectedItem as ComboBoxItem)?.Tag as string) ?? "us-east-1";

        if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(accessKey) || string.IsNullOrWhiteSpace(secretKey))
        {
            ShowFeedback(success: false, "Fill in all required fields before continuing.");
            return;
        }

        SetValidating(true);
        ShowFeedback(success: null, "Validating credentials...");

        bool valid;
        try
        {
            valid = await _accounts.ValidateCredentialsAsync(accessKey, secretKey, region);
        }
        catch (Exception ex)
        {
            SetValidating(false);
            ShowFeedback(success: false, $"Error: {ex.Message}");
            return;
        }

        if (!valid)
        {
            SetValidating(false);
            ShowFeedback(success: false, "Invalid credentials. Verify your Access Key and Secret Key.");
            return;
        }

        _accounts.AddAccount(name, accessKey, secretKey, region);
        AccountAdded = true;
        SetValidating(false);
        TransitionToNextStep();
    }

    private void TransitionToNextStep()
    {
        HeaderTitle.Text = "Account Connected";
        PageForm.Visibility = Visibility.Collapsed;
        FeedbackBorder.Visibility = Visibility.Collapsed;
        FooterPage1.Visibility = Visibility.Collapsed;
        PageNext.Visibility = Visibility.Visible;
        FooterPage2.Visibility = Visibility.Visible;
    }

    private void NextAction_Click(object sender, RoutedEventArgs e)
    {
        var action = (sender as Button)?.Tag as string;
        if (action == "import")
        {
            TransitionToImportSetup();
            return;
        }
        NextAction = action;
        Close();
    }

    private void TransitionToImportSetup()
    {
        HeaderTitle.Text = "Import from AWS";
        PageNext.Visibility = Visibility.Collapsed;
        FooterPage2.Visibility = Visibility.Collapsed;
        PageImport.Visibility = Visibility.Visible;
        FooterPage3.Visibility = Visibility.Visible;
        BtnCreateImport.Background = (System.Windows.Media.Brush)FindResource("AccentBrush");
        ImportStackName.Focus();
    }

    private void BackToNextStep_Click(object sender, RoutedEventArgs e)
    {
        HeaderTitle.Text = "Account Connected";
        PageImport.Visibility = Visibility.Collapsed;
        FooterPage3.Visibility = Visibility.Collapsed;
        PageNext.Visibility = Visibility.Visible;
        FooterPage2.Visibility = Visibility.Visible;
    }

    private void BrowseImportFolder_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Microsoft.Win32.OpenFolderDialog
        {
            Title = "Select destination folder for imported Terraform files"
        };
        if (picker.ShowDialog() == true)
        {
            _importProjectPath = picker.FolderName;
            ImportPathText.Text = picker.FolderName;
            ImportPathText.Foreground = (System.Windows.Media.Brush)FindResource("TextPrimaryBrush");
        }
    }

    private void CreateImport_Click(object sender, RoutedEventArgs e)
    {
        var name = ImportStackName.Text.Trim();
        if (string.IsNullOrWhiteSpace(name))
        {
            ShowImportFeedback("Please enter a stack name.");
            return;
        }
        if (string.IsNullOrWhiteSpace(_importProjectPath))
        {
            ShowImportFeedback("Please select a destination folder.");
            return;
        }
        StackName   = name;
        ProjectPath = _importProjectPath;
        NextAction  = "import";
        Close();
    }

    private void ShowImportFeedback(string message)
    {
        ImportFeedbackText.Text = message;
        ImportFeedback.Background = new System.Windows.Media.SolidColorBrush(
            System.Windows.Media.Color.FromArgb(25, 248, 113, 113));
        ImportFeedback.Visibility = Visibility.Visible;
    }

    private void Skip_Click(object sender, RoutedEventArgs e) => Close();

    private void BtnToggleSecret_Click(object sender, RoutedEventArgs e)
    {
        _secretVisible = !_secretVisible;
        if (_secretVisible)
        {
            TxtSecretKey.Text = PbSecretKey.Password;
            PbSecretKey.Visibility = Visibility.Collapsed;
            TxtSecretKey.Visibility = Visibility.Visible;
            ToggleSecretIcon.Data = (System.Windows.Media.Geometry)FindResource("Icon.EyeOff");
            TxtSecretKey.Focus();
        }
        else
        {
            PbSecretKey.Password = TxtSecretKey.Text;
            TxtSecretKey.Visibility = Visibility.Collapsed;
            PbSecretKey.Visibility = Visibility.Visible;
            ToggleSecretIcon.Data = (System.Windows.Media.Geometry)FindResource("Icon.Eye");
            PbSecretKey.Focus();
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();

    private void DragHandle_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed) DragMove();
    }

    private void SetValidating(bool validating)
    {
        _isValidating    = validating;
        BtnAdd.IsEnabled = !validating;
        BtnCancel.IsEnabled = !validating;
    }

    private void ShowFeedback(bool? success, string message)
    {
        FeedbackBorder.Visibility = Visibility.Visible;
        FeedbackText.Text = message;

        if (success == true)
        {
            var successBrush = (Brush)FindResource("SuccessBrush");
            FeedbackBorder.Background = new SolidColorBrush(Color.FromArgb(25,
                ((SolidColorBrush)successBrush).Color.R,
                ((SolidColorBrush)successBrush).Color.G,
                ((SolidColorBrush)successBrush).Color.B));
            FeedbackText.Foreground = successBrush;
            FeedbackIcon.Text = ""; // checkmark
            FeedbackIcon.Foreground = successBrush;
        }
        else if (success == false)
        {
            var dangerBrush = (Brush)FindResource("DangerBrush");
            FeedbackBorder.Background = new SolidColorBrush(Color.FromArgb(25,
                ((SolidColorBrush)dangerBrush).Color.R,
                ((SolidColorBrush)dangerBrush).Color.G,
                ((SolidColorBrush)dangerBrush).Color.B));
            FeedbackText.Foreground = dangerBrush;
            FeedbackIcon.Text = ""; // error
            FeedbackIcon.Foreground = dangerBrush;
        }
        else
        {
            var mutedBrush = (Brush)FindResource("TextMutedBrush");
            FeedbackBorder.Background = (Brush)FindResource("SurfaceBrush");
            FeedbackText.Foreground = mutedBrush;
            FeedbackIcon.Text = ""; // spinner
            FeedbackIcon.Foreground = mutedBrush;
        }
    }
}

