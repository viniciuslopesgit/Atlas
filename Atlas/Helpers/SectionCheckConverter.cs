using System.Globalization;
using System.Windows.Data;

namespace Atlas.Helpers;

/// <summary>
/// Converts any value to bool by comparing its ToString() to the ConverterParameter string.
/// Generic counterpart to PageCheckConverter — can be used with any enum type.
/// </summary>
public sealed class SectionCheckConverter : IValueConverter
{
    public object Convert(object value, Type t, object parameter, CultureInfo c) =>
        value?.ToString() == parameter?.ToString();

    public object ConvertBack(object value, Type t, object parameter, CultureInfo c) =>
        Binding.DoNothing;
}
