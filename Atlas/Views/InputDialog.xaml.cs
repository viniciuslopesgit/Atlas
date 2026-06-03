using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace Atlas.Views;

public partial class InputDialog : Window
{
    public bool Confirmed { get; private set; }
    public string InputText => InputBox.Text.Trim();

    public InputDialog(string title, string message, string placeholder, string confirmLabel)
    {
        InitializeComponent();

        TitleText.Text   = title;
        MessageText.Text = message;
        InputBox.Text    = placeholder;

        var accent = (SolidColorBrush)FindResource("AccentBrush");
        IconBorder.Background    = new SolidColorBrush(Color.FromArgb(30, accent.Color.R, accent.Color.G, accent.Color.B));
        IconText.Foreground      = accent;
        ConfirmButton.Background = accent;
        ConfirmText.Text         = confirmLabel;

        Loaded += (_, _) =>
        {
            InputBox.Focus();
            InputBox.SelectAll();
        };
    }

    private void Confirm_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(InputBox.Text)) return;
        Confirmed = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        Confirmed = false;
        Close();
    }

    private void InputBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) Confirm_Click(sender, e);
        else if (e.Key == Key.Escape) Cancel_Click(sender, e);
    }

    private void DragHandle_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed)
            DragMove();
    }
}
