using Atlas.Services;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Atlas.Views;

public partial class AddAccountDialog : Window
{
    public bool AccountAdded { get; private set; }

    private readonly IAccountService _accounts;
    private bool _isValidating;

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
        ("sa-east-1",      "São Paulo"),
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
        var secretKey = PbSecretKey.Password;
        var region    = ((CmbRegion.SelectedItem as ComboBoxItem)?.Tag as string) ?? "us-east-1";

        if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(accessKey) || string.IsNullOrWhiteSpace(secretKey))
        {
            ShowFeedback(success: false, "Fill in all required fields before continuing.");
            return;
        }

        SetValidating(true);
        ShowFeedback(success: null, "Validating credentials…");

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
        Close();
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
            FeedbackIcon.Text = ""; // error/x
            FeedbackIcon.Foreground = dangerBrush;
        }
        else
        {
            // neutral (validating…)
            var mutedBrush = (Brush)FindResource("TextMutedBrush");
            FeedbackBorder.Background = (Brush)FindResource("SurfaceBrush");
            FeedbackText.Foreground = mutedBrush;
            FeedbackIcon.Text = ""; // spinner/clock
            FeedbackIcon.Foreground = mutedBrush;
        }
    }
}
