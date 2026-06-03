using System.Windows;

namespace Atlas.Services;

public sealed class ThemeService : IThemeService
{
    private AppTheme _current = AppTheme.Dark;

    public AppTheme CurrentTheme => _current;
    public event EventHandler<AppTheme> ThemeChanged = delegate { };

    public void Toggle() => Apply(_current == AppTheme.Dark ? AppTheme.Light : AppTheme.Dark);

    public void Apply(AppTheme theme)
    {
        _current = theme;

        var dict = Application.Current.Resources.MergedDictionaries;

        // Remove existing theme dict (match only DarkTheme/LightTheme, not ControlStyles)
        var existing = dict.FirstOrDefault(d =>
            d.Source?.OriginalString is string s &&
            (s.Contains("DarkTheme") || s.Contains("LightTheme")));
        if (existing != null) dict.Remove(existing);

        var uri = theme == AppTheme.Dark
            ? new Uri("Themes/DarkTheme.xaml", UriKind.Relative)
            : new Uri("Themes/LightTheme.xaml", UriKind.Relative);

        dict.Add(new ResourceDictionary { Source = uri });
        ThemeChanged(this, theme);
    }
}
