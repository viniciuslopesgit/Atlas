using Atlas.ViewModels;
using System.Windows.Controls;

namespace Atlas.Views;

public partial class SettingsView : UserControl
{
    public SettingsView()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            if (DataContext is SettingsViewModel vm)
                PbSecretKey.PasswordChanged += (_, _) => vm.NewSecretKey = PbSecretKey.Password;
        };
    }
}
