using Atlas.ViewModels;
using System.Globalization;
using System.Windows.Data;

namespace Atlas.Helpers;

/// <summary>
/// Converts a NavigationPage enum value to bool (true when it matches the ConverterParameter).
/// Used to drive the sidebar RadioButton IsChecked state.
/// </summary>
public sealed class PageCheckConverter : IValueConverter
{
    public object Convert(object value, Type t, object parameter, CultureInfo c)
    {
        if (value is NavigationPage page && parameter is string name)
            return page.ToString() == name;
        return false;
    }

    public object ConvertBack(object value, Type t, object parameter, CultureInfo c) =>
        Binding.DoNothing;
}
