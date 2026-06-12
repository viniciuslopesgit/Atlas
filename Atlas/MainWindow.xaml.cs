using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using Atlas.Helpers;
using Atlas.Services;
using Atlas.ViewModels;

namespace Atlas;

public partial class MainWindow : Window
{
    private MainViewModel _vm = null!;

    private double _zoomLevel = 0.8;
    private const double ZoomStep = 0.1;
    private const double ZoomMin  = 0.5;
    private const double ZoomMax  = 2.5;

    public MainWindow(MainViewModel viewModel, IThemeService theme)
    {
        InitializeComponent();
        WindowMaximizeFix.Attach(this);
        _vm = viewModel;
        DataContext = viewModel;
        StateChanged += (_, _) => UpdateMaximizeGlyph();
        ApplyZoom(_zoomLevel);

        // Auto-focus search box whenever the palette opens
        _vm.Palette.PropertyChanged += OnPalettePropertyChanged;
    }

    // ── Custom window-chrome controls ─────────────────────────────────
    private void MinimizeButton_Click(object sender, RoutedEventArgs e)
        => WindowState = WindowState.Minimized;

    private void MaximizeRestoreButton_Click(object sender, RoutedEventArgs e)
        => WindowState = WindowState == WindowState.Maximized
            ? WindowState.Normal
            : WindowState.Maximized;

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private void UpdateMaximizeGlyph()
    {
        MaximizeGlyph.Data = (System.Windows.Media.Geometry)FindResource(
            WindowState == WindowState.Maximized ? "Icon.Minimize2" : "Icon.Maximize2");
        MaximizeButton.ToolTip = WindowState == WindowState.Maximized ? "Restore" : "Maximize";
    }

    // ── Command Palette ───────────────────────────────────────────────

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);
        if (e.Key == Key.K && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
        {
            if (_vm.Palette.IsOpen)
                _vm.Palette.CloseCommand.Execute(null);
            else
                _vm.Palette.Open();
            e.Handled = true;
        }

        if ((Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
        {
            if (e.Key is Key.OemPlus or Key.Add)
            {
                ApplyZoom(_zoomLevel + ZoomStep);
                e.Handled = true;
            }
            else if (e.Key is Key.OemMinus or Key.Subtract)
            {
                ApplyZoom(_zoomLevel - ZoomStep);
                e.Handled = true;
            }
            else if (e.Key is Key.D0 or Key.NumPad0)
            {
                ApplyZoom(1.0);
                e.Handled = true;
            }
        }
    }

    private void ApplyZoom(double level)
    {
        _zoomLevel = Math.Clamp(level, ZoomMin, ZoomMax);
        _zoomLevel = Math.Round(_zoomLevel, 1);
        AppScale.ScaleX = _zoomLevel;
        AppScale.ScaleY = _zoomLevel;
    }

    private void OnPalettePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(CommandPaletteViewModel.IsOpen)) return;
        if (!_vm.Palette.IsOpen) return;

        // Defer focus so the overlay finishes rendering before we grab keyboard
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
        {
            PaletteSearchBox.Focus();
            Keyboard.Focus(PaletteSearchBox);
        });
    }

    private void PaletteSearchBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Escape:
                _vm.Palette.CloseCommand.Execute(null);
                e.Handled = true;
                break;

            case Key.Down:
                _vm.Palette.MoveDown();
                ScrollPaletteToSelected();
                e.Handled = true;
                break;

            case Key.Up:
                _vm.Palette.MoveUp();
                ScrollPaletteToSelected();
                e.Handled = true;
                break;

            case Key.Enter:
                _vm.Palette.ExecuteSelectedCommand.Execute(null);
                e.Handled = true;
                break;
        }
    }

    private void PaletteList_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_vm.Palette.SelectedCommand != null)
            _vm.Palette.ExecuteSelectedCommand.Execute(null);
    }

    private void PaletteBackdrop_MouseDown(object sender, MouseButtonEventArgs e)
        => _vm.Palette.CloseCommand.Execute(null);

    private void PaletteCard_MouseDown(object sender, MouseButtonEventArgs e)
        => e.Handled = true; // stop backdrop from closing when clicking inside the card

    private void BuyLicense_Click(object sender, RoutedEventArgs e)
        => Process.Start(new ProcessStartInfo(
            "https://atlas-cloud.lemonsqueezy.com/checkout/buy/b77ae4c5-789d-4b23-93c4-449f21d6db79")
            { UseShellExecute = true });

    private void ScrollPaletteToSelected()
    {
        var selected = _vm.Palette.SelectedCommand;
        if (selected != null)
            PaletteListView.ScrollIntoView(selected);
    }
}
