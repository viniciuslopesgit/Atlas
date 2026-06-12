using Atlas.ViewModels;
using Microsoft.Win32;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;

namespace Atlas.Views;

public partial class TerraformView : UserControl
{
    public TerraformView()
    {
        InitializeComponent();

        // Auto-scroll do terminal quando novo output é adicionado.
        // Subscreve ao ViewModel após o DataContext ficar disponível.
        DataContextChanged += OnDataContextChanged;
        Unloaded           += OnUnloaded;
    }

    // ── Browse folder ─────────────────────────────────────────────────────

    private void BrowsePath_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog
        {
            Title            = "Select Terraform project root folder",
            Multiselect      = false,
        };

        if (dialog.ShowDialog(Window.GetWindow(this)) == true)
        {
            if (DataContext is TerraformViewModel vm)
                vm.SetNewRootPath(dialog.FolderName);
        }
    }

    // ── Auto-scroll terminal ──────────────────────────────────────────────

    private TerraformViewModel? _vm;

    private void OnDataContextChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (_vm is not null)
            _vm.PropertyChanged -= OnVmPropertyChanged;

        _vm = DataContext as TerraformViewModel;

        if (_vm is not null)
            _vm.PropertyChanged += OnVmPropertyChanged;
    }

    private void OnVmPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(TerraformViewModel.TerminalOutput))
        {
            // Faz scroll para o fim do terminal sempre que o output muda.
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, () =>
            {
                TerminalScroller?.ScrollToEnd();
            });
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_vm is not null)
        {
            _vm.PropertyChanged -= OnVmPropertyChanged;
            _vm = null;
        }
    }
}
