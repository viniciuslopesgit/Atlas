using Atlas.Services.AWS;
using Microsoft.Win32;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Atlas.Views;

public partial class CreateKeyPairDialog : Window
{
    public bool   Confirmed   { get; private set; }
    public string KeyPairName { get; private set; } = string.Empty;

    private readonly IEc2Service _ec2;

    public CreateKeyPairDialog(IEc2Service ec2)
    {
        InitializeComponent();
        _ec2 = ec2;

        RdoPpk.Checked += (_, _) => PnlPpkNote.Visibility = Visibility.Visible;
        RdoPem.Checked += (_, _) => PnlPpkNote.Visibility = Visibility.Collapsed;

        Loaded += (_, _) => TxtName.Focus();
    }

    private void DragHandle_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed) DragMove();
    }

    private async void Create_Click(object sender, RoutedEventArgs e)
    {
        var name = TxtName.Text.Trim();
        if (string.IsNullOrEmpty(name))
        {
            TxtNameError.Text       = "Key pair name is required.";
            TxtNameError.Visibility = Visibility.Visible;
            return;
        }
        TxtNameError.Visibility = Visibility.Collapsed;
        TxtError.Visibility     = Visibility.Collapsed;

        var isPpk   = RdoPpk.IsChecked == true;
        var keyType = RdoEd25519.IsChecked == true ? "ed25519" : "rsa";
        var ext     = isPpk ? ".ppk" : ".pem";

        var save = new SaveFileDialog
        {
            Title      = "Save private key",
            FileName   = name,
            DefaultExt = ext,
            Filter     = isPpk ? "PuTTY Key File (*.ppk)|*.ppk|All Files (*.*)|*.*"
                                : "PEM File (*.pem)|*.pem|All Files (*.*)|*.*"
        };

        if (save.ShowDialog() != true) return;

        BtnCreate.IsEnabled   = false;
        TxtBtnLabel.Text      = "Creating…";

        try
        {
            var (keyMaterial, _) = await _ec2.CreateKeyPairAsync(name, keyType);
            System.IO.File.WriteAllText(save.FileName, keyMaterial);

            KeyPairName = name;
            Confirmed   = true;
            Close();
        }
        catch (Exception ex)
        {
            TxtError.Text       = $"Failed to create key pair: {ex.Message}";
            TxtError.Visibility = Visibility.Visible;
        }
        finally
        {
            BtnCreate.IsEnabled = true;
            TxtBtnLabel.Text    = "Create key pair";
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        Confirmed = false;
        Close();
    }
}
