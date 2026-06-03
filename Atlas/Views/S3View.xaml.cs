using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Atlas.ViewModels;

namespace Atlas.Views;

public partial class S3View : UserControl
{
    public S3View() => InitializeComponent();

    private void BucketRowCheckBox_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        var row = FindVisualParent<DataGridRow>((DependencyObject)sender);
        if (row == null) return;

        if (row.IsSelected)
            BucketGrid.SelectedItems.Remove(row.Item);
        else
            BucketGrid.SelectedItems.Add(row.Item);
    }

    private void BucketSelectAll_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (BucketGrid.SelectedItems.Count == BucketGrid.Items.Count)
            BucketGrid.UnselectAll();
        else
            BucketGrid.SelectAll();
    }

    private void BucketGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DataContext is S3ViewModel vm)
            vm.UpdateBucketSelection(((DataGrid)sender).SelectedItems);
    }

    private void BucketGrid_ClearSelection(object sender, RoutedEventArgs e)
    {
        BucketGrid.UnselectAll();
    }

    private void ObjectRowCheckBox_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        var row = FindVisualParent<DataGridRow>((DependencyObject)sender);
        if (row == null) return;

        if (row.IsSelected)
            ObjectGrid.SelectedItems.Remove(row.Item);
        else
            ObjectGrid.SelectedItems.Add(row.Item);
    }

    private void ObjectSelectAll_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (ObjectGrid.SelectedItems.Count == ObjectGrid.Items.Count)
            ObjectGrid.UnselectAll();
        else
            ObjectGrid.SelectAll();
    }

    private void ObjectGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (DataContext is S3ViewModel vm)
            vm.UpdateObjectSelection(((DataGrid)sender).SelectedItems);
    }

    private void ObjectGrid_ClearSelection(object sender, RoutedEventArgs e)
    {
        ObjectGrid.UnselectAll();
    }

    private void ObjectGrid_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (DataContext is S3ViewModel vm && vm.SelectedObject?.IsFolder == true)
            vm.EnterFolderCommand.Execute(vm.SelectedObject);
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
