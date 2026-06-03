using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Atlas.ViewModels;

namespace Atlas.Views;

public partial class Ec2View : UserControl
{
    private const double DefaultDetailWidth = 400;
    private const double SplitterWidth = 8;
    private const double PanelMinWidth      = 280;
    private const double PanelMaxWidth      = 700;

    private double _savedDetailWidth = DefaultDetailWidth;
    private bool   _panelOpen;

    public Ec2View()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is Ec2ViewModel old)
            old.PropertyChanged -= OnVmPropertyChanged;

        if (e.NewValue is Ec2ViewModel vm)
        {
            vm.PropertyChanged += OnVmPropertyChanged;
            // Sync immediately — HasSelection may already be true if navigating back
            _panelOpen = !vm.HasSelection; // force SetPanelOpen to not short-circuit
            SetPanelOpen(vm.HasSelection);
        }
    }

    private void OnVmPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Ec2ViewModel.HasSelection))
            SetPanelOpen((sender as Ec2ViewModel)?.HasSelection ?? false);
    }

    private void SetPanelOpen(bool open)
    {
        if (open == _panelOpen) return;

        if (open)
        {
            // Restore constraints before expanding so GridSplitter respects them
            DetailColumn.MinWidth = PanelMinWidth;
            DetailColumn.MaxWidth = PanelMaxWidth;
            SplitterColumn.Width  = new GridLength(SplitterWidth);
            DetailColumn.Width    = new GridLength(_savedDetailWidth);
        }
        else
        {
            if (DetailColumn.Width.Value > 0)
                _savedDetailWidth = DetailColumn.Width.Value;

            // Clear constraints first — MinWidth would prevent Width=0 from working
            DetailColumn.MinWidth = 0;
            DetailColumn.MaxWidth = double.PositiveInfinity;
            SplitterColumn.Width  = new GridLength(0);
            DetailColumn.Width    = new GridLength(0);
        }

        _panelOpen = open;
    }

    // ── DataGrid selection ────────────────────────────────────────────────

    private void RowCheckBox_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        var row = FindVisualParent<DataGridRow>((DependencyObject)sender);
        if (row == null) return;

        if (row.IsSelected)
            InstanceGrid.SelectedItems.Remove(row.Item);
        else
            InstanceGrid.SelectedItems.Add(row.Item);
    }

    private void SelectAll_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (InstanceGrid.SelectedItems.Count == InstanceGrid.Items.Count)
            InstanceGrid.UnselectAll();
        else
            InstanceGrid.SelectAll();
    }

    private void InstanceGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DataContext is Ec2ViewModel vm)
            vm.UpdateSelection(((DataGrid)sender).SelectedItems);
    }

    private void InstanceGrid_ClearSelection(object sender, RoutedEventArgs e)
    {
        InstanceGrid.UnselectAll();
    }

    private void CopyButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string text } && !string.IsNullOrEmpty(text))
            Clipboard.SetText(text);
    }

    private static T? FindVisualParent<T>(DependencyObject child) where T : DependencyObject
    {
        var current = VisualTreeHelper.GetParent(child);
        while (current != null)
        {
            if (current is T match) return match;
            current = VisualTreeHelper.GetParent(current);
        }
        return null;
    }
}
