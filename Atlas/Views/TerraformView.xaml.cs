using Atlas.ViewModels;
using Microsoft.Win32;
using System.Windows;
using System.Windows.Controls;

namespace Atlas.Views;

public partial class TerraformView : UserControl
{
    public TerraformView()
    {
        InitializeComponent();
    }

    private void BrowseButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Select Terraform project root directory",
        };

        if (dialog.ShowDialog() == true && DataContext is TerraformViewModel vm)
            vm.SetNewRootPath(dialog.FolderName);
    }
}
