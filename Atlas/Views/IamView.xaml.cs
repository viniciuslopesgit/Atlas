using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Atlas.ViewModels;

namespace Atlas.Views;

public partial class IamView : UserControl
{
    private const double DefaultDetailWidth = 400;
    private const double SplitterWidth      = 8;
    private const double PanelMinWidth      = 280;
    private const double PanelMaxWidth      = 700;

    private double _savedDetailWidth = DefaultDetailWidth;
    private bool   _panelOpen;

    public IamView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is IamViewModel old)
            old.PropertyChanged -= OnVmPropertyChanged;

        if (e.NewValue is IamViewModel vm)
        {
            vm.PropertyChanged += OnVmPropertyChanged;
            _panelOpen = !vm.HasSelection;
            SetPanelOpen(vm.HasSelection);
        }
    }

    private void OnVmPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(IamViewModel.HasSelection))
            SetPanelOpen((sender as IamViewModel)?.HasSelection ?? false);
    }

    private void SetPanelOpen(bool open)
    {
        if (open == _panelOpen) return;

        if (open)
        {
            DetailColumn.MinWidth = PanelMinWidth;
            DetailColumn.MaxWidth = PanelMaxWidth;
            SplitterColumn.Width  = new GridLength(SplitterWidth);
            DetailColumn.Width    = new GridLength(_savedDetailWidth);
        }
        else
        {
            if (DetailColumn.Width.Value > 0)
                _savedDetailWidth = DetailColumn.Width.Value;

            DetailColumn.MinWidth = 0;
            DetailColumn.MaxWidth = double.PositiveInfinity;
            SplitterColumn.Width  = new GridLength(0);
            DetailColumn.Width    = new GridLength(0);
        }

        _panelOpen = open;
    }

    private IamViewModel? VM => DataContext as IamViewModel;

    // ── Shared helpers ────────────────────────────────────────────────────

    private void RowCheckBox_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        var row = FindVisualParent<DataGridRow>((DependencyObject)sender);
        if (row == null) return;

        var grid = FindVisualParent<DataGrid>(row);
        if (grid == null) return;

        if (row.IsSelected)
            grid.SelectedItems.Remove(row.Item);
        else
            grid.SelectedItems.Add(row.Item);
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

    // ── Users ─────────────────────────────────────────────────────────────

    private void SelectAllUsers_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (UsersGrid.SelectedItems.Count == UsersGrid.Items.Count)
            UsersGrid.UnselectAll();
        else
            UsersGrid.SelectAll();
    }

    private void UsersGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DataContext is IamViewModel vm)
            vm.UpdateUserSelection(((DataGrid)sender).SelectedItems);
    }

    private void UsersGrid_ClearSelection(object sender, RoutedEventArgs e)
    {
        UsersGrid.UnselectAll();
    }

    // ── Roles ─────────────────────────────────────────────────────────────

    private void SelectAllRoles_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (RolesGrid.SelectedItems.Count == RolesGrid.Items.Count)
            RolesGrid.UnselectAll();
        else
            RolesGrid.SelectAll();
    }

    private void RolesGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DataContext is IamViewModel vm)
            vm.UpdateRoleSelection(((DataGrid)sender).SelectedItems);
    }

    private void RolesGrid_ClearSelection(object sender, RoutedEventArgs e)
    {
        RolesGrid.UnselectAll();
    }

    // ── Groups ────────────────────────────────────────────────────────────

    private void SelectAllGroups_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (GroupsGrid.SelectedItems.Count == GroupsGrid.Items.Count)
            GroupsGrid.UnselectAll();
        else
            GroupsGrid.SelectAll();
    }

    private void GroupsGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DataContext is IamViewModel vm)
            vm.UpdateGroupSelection(((DataGrid)sender).SelectedItems);
    }

    private void GroupsGrid_ClearSelection(object sender, RoutedEventArgs e)
    {
        GroupsGrid.UnselectAll();
    }

    // ── Policies ──────────────────────────────────────────────────────────

    private void SelectAllPolicies_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (PoliciesGrid.SelectedItems.Count == PoliciesGrid.Items.Count)
            PoliciesGrid.UnselectAll();
        else
            PoliciesGrid.SelectAll();
    }

    private void PoliciesGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DataContext is IamViewModel vm)
            vm.UpdatePolicySelection(((DataGrid)sender).SelectedItems);
    }

    private void PoliciesGrid_ClearSelection(object sender, RoutedEventArgs e)
    {
        PoliciesGrid.UnselectAll();
    }
}
