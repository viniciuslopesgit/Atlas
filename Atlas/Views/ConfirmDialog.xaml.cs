using Atlas.Services;
using System.Windows;
using System.Windows.Media;

namespace Atlas.Views;

public partial class ConfirmDialog : Window
{
    public bool Confirmed { get; private set; }

    public ConfirmDialog(string title, string message, string instanceList, DialogKind kind)
    {
        InitializeComponent();

        TitleText.Text   = title;
        MessageText.Text = message;

        InstanceListText.Text = instanceList;
        InstanceListBorder.Visibility = string.IsNullOrWhiteSpace(instanceList)
            ? Visibility.Collapsed
            : Visibility.Visible;

        ApplyKind(kind);
    }

    private void ApplyKind(DialogKind kind)
    {
        switch (kind)
        {
            case DialogKind.Danger:
                var danger = (SolidColorBrush)FindResource("DangerBrush");
                IconBorder.Background    = new SolidColorBrush(Color.FromArgb(30, danger.Color.R, danger.Color.G, danger.Color.B));
                IconText.Text            = "⚠";
                IconText.Foreground      = danger;
                ConfirmButton.Background = danger;
                ConfirmText.Text         = "Confirm";
                break;

            case DialogKind.Info:
                var warn = (SolidColorBrush)FindResource("DangerBrush");
                IconBorder.Background    = new SolidColorBrush(Color.FromArgb(30, warn.Color.R, warn.Color.G, warn.Color.B));
                IconText.Text            = "✕";
                IconText.Foreground      = warn;
                ConfirmButton.Background = (SolidColorBrush)FindResource("AccentBrush");
                ConfirmText.Text         = "OK";
                CancelButton.Visibility  = Visibility.Collapsed;
                break;

            default:
                var accent = (SolidColorBrush)FindResource("AccentBrush");
                IconBorder.Background    = new SolidColorBrush(Color.FromArgb(30, accent.Color.R, accent.Color.G, accent.Color.B));
                IconText.Text            = "▶";
                IconText.Foreground      = accent;
                ConfirmButton.Background = accent;
                ConfirmText.Text         = "Confirm";
                break;
        }
    }

    private void Confirm_Click(object sender, RoutedEventArgs e)
    {
        Confirmed = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        Confirmed = false;
        Close();
    }

    private void DragHandle_MouseLeftButtonDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (e.ButtonState == System.Windows.Input.MouseButtonState.Pressed)
            DragMove();
    }
}
