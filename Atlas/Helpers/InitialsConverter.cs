using System.Globalization;
using System.Windows.Data;

namespace Atlas.Helpers;

/// <summary>Converts "My Account" → "MA", "prod" → "PR"</summary>
public sealed class InitialsConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c)
    {
        if (value is not string name || string.IsNullOrWhiteSpace(name))
            return "?";

        var words = name.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return words.Length >= 2
            ? $"{char.ToUpper(words[0][0])}{char.ToUpper(words[1][0])}"
            : name.Substring(0, Math.Min(2, name.Length)).ToUpper();
    }

    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        throw new NotSupportedException();
}
