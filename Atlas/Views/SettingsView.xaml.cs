using System.Windows.Controls;
using Atlas.ViewModels;

namespace Atlas.Views;

public partial class SettingsView : UserControl
{
    public SettingsView()
    {
        InitializeComponent();
        // Bridge PasswordBox to ViewModel (PasswordBox doesn't support binding for security reasons)
        Loaded += (_, _) =>
        {
            if (DataContext is SettingsViewModel vm)
                PbSecretKey.PasswordChanged += (_, _) => vm.NewSecretKey = PbSecretKey.Password;
        };
    }
}
