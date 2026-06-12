using System.Windows;
using System.Windows.Input;

namespace Atlas.Views;

/// <summary>
/// Asks for a stack name + destination folder before kicking off the
/// import pipeline. <see cref="StackName"/>/<see cref="ProjectPath"/>
/// are null when the user cancels.
/// </summary>
public partial class CreateStackDialog : Window
{
    public string? StackName   { get; private set; }
    public string? ProjectPath { get; private set; }

    private string? _selectedPath;

    public CreateStackDialog()
    {
        InitializeComponent();
        Loaded += (_, _) => TxtStackName.Focus();
    }

    private void BrowseFolder_Click(object sender, RoutedEventArgs e)
    {
        var picker = new Microsoft.Win32.OpenFolderDialog
        {
            Title = "Select destination folder for imported Terraform files"
        };
        if (picker.ShowDialog() == true)
        {
            _selectedPath = picker.FolderName;
            PathText.Text = picker.FolderName;
            PathText.Foreground = (System.Windows.Media.Brush)FindResource("TextPrimaryBrush");
        }
    }

    private void Create_Click(object sender, RoutedEventArgs e)
    {
        var name = TxtStackName.Text.Trim();
        if (string.IsNullOrWhiteSpace(name))
        {
            ShowFeedback("Please enter a stack name.");
            return;
        }
        if (string.IsNullOrWhiteSpace(_selectedPath))
        {
            ShowFeedback("Please select a destination folder.");
            return;
        }

        StackName   = name;
        ProjectPath = _selectedPath;
        Close();
    }

    private void ShowFeedback(string message)
    {
        FeedbackText.Text = message;
        Feedback.Background = new System.Windows.Media.SolidColorBrush(
            System.Windows.Media.Color.FromArgb(25, 248, 113, 113));
        Feedback.Visibility = Visibility.Visible;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();

    private void DragHandle_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed) DragMove();
    }
}
