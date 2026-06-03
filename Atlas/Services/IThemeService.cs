namespace Atlas.Services;

public enum AppTheme { Dark, Light }

public interface IThemeService
{
    AppTheme CurrentTheme { get; }
    event EventHandler<AppTheme> ThemeChanged;
    void Toggle();
    void Apply(AppTheme theme);
}
