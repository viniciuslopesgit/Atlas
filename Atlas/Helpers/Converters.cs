using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using Atlas.Models;

namespace Atlas.Helpers;

/// <summary>true → Visible, false → Collapsed</summary>
public sealed class BoolToVisibleConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        value is true ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        value is Visibility.Visible;
}

/// <summary>true → Collapsed, false → Visible</summary>
public sealed class BoolToInvisibleConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        value is Visibility.Collapsed;
}

/// <summary>null → Collapsed, non-null → Visible</summary>
public sealed class NullToCollapsedConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        value is null ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        throw new NotSupportedException();
}

/// <summary>null → Visible, non-null → Collapsed</summary>
public sealed class NullToVisibleConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        value is null ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        throw new NotSupportedException();
}

/// <summary>0 → Visible, non-zero → Collapsed (for empty-state panels)</summary>
public sealed class ZeroToVisibleConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        value is int i && i == 0 ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        throw new NotSupportedException();
}

/// <summary>Inverts a bool</summary>
public sealed class BoolInvertConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        value is bool b && !b;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        value is bool b && !b;
}

/// <summary>0 or empty collection → Collapsed, non-zero → Visible</summary>
public sealed class ZeroToCollapsedConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        value is int i && i > 0 ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        throw new NotSupportedException();
}

/// <summary>Visible when value.ToString() == parameter; Collapsed otherwise</summary>
public sealed class EqualToVisibleConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        value?.ToString() == p?.ToString() ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        throw new NotSupportedException();
}

/// <summary>true when value.ToString() == parameter; ConvertBack returns parameter when value is true</summary>
public sealed class EqualityConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c) =>
        value?.ToString() == p?.ToString();
    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        value is true ? p : Binding.DoNothing;
}

/// <summary>
/// IMultiValueConverter: returns true when all supplied values are equal (string comparison).
/// </summary>
public sealed class MultiValueEqualityConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type t, object p, CultureInfo c) =>
        values.Length >= 2 && Equals(values[0], values[1]);
    public object[] ConvertBack(object value, Type[] t, object p, CultureInfo c) =>
        throw new NotSupportedException();
}

/// <summary>
/// Maps SearchResultType to a Segoe MDL2 Assets glyph character.
/// </summary>
public sealed class ResourceTypeToIconConverter : IValueConverter
{
    private static readonly string GlyphEC2    = char.ConvertFromUtf32(0xEDA3);
    private static readonly string GlyphBucket = char.ConvertFromUtf32(0xE8B7);
    private static readonly string GlyphFolder = char.ConvertFromUtf32(0xE8A5);

    public object Convert(object value, Type t, object p, CultureInfo c) =>
        value is SearchResultType type ? type switch
        {
            SearchResultType.EC2Instance => GlyphEC2,
            SearchResultType.S3Bucket    => GlyphBucket,
            _                            => GlyphFolder
        } : string.Empty;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        throw new NotSupportedException();
}

/// <summary>
/// Converts IReadOnlyList&lt;MetricPoint&gt; to a PointCollection normalised to a 100×26 canvas.
/// Wrap the Polyline in a Viewbox so it fills available width.
/// Returns an empty collection when fewer than 2 data points exist.
/// </summary>
public sealed class SparklineConverter : IValueConverter
{
    public object Convert(object value, Type t, object p, CultureInfo c)
    {
        if (value is not IReadOnlyList<MetricPoint> pts || pts.Count < 2)
            return new PointCollection();

        const double W = 100, H = 26;
        var vals = pts.Select(x => x.Value).ToList();
        double min = vals.Min(), max = vals.Max(), range = max - min;

        var col = new PointCollection(pts.Count);
        for (int i = 0; i < vals.Count; i++)
        {
            double x = (double)i / (vals.Count - 1) * W;
            double y = range < 1e-9 ? H * 0.5 : H - (vals[i] - min) / range * H;
            col.Add(new Point(x, y));
        }
        return col;
    }

    public object ConvertBack(object value, Type t, object p, CultureInfo c) =>
        throw new NotSupportedException();
}
