using Microsoft.Win32;

namespace Atlas.Services;

public sealed class StartupService : IStartupService
{
    private const string AppName     = "Atlas";
    private const string RunKeyPath  = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
    private const string PrefKeyPath = @"SOFTWARE\Atlas";
    private const string PrefValue   = "StartOnLogin";

    public bool IsEnabled
    {
        get
        {
            using var pref = Registry.CurrentUser.OpenSubKey(PrefKeyPath, false);
            if (pref?.GetValue(PrefValue) is int stored)
                return stored != 0;

            // First run — enable by default
            Set(true);
            return true;
        }
    }

    public void Set(bool enabled)
    {
        using var pref = Registry.CurrentUser.CreateSubKey(PrefKeyPath, writable: true);
        pref.SetValue(PrefValue, enabled ? 1 : 0, RegistryValueKind.DWord);

        using var run = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
        if (run is null) return;

        if (enabled)
        {
            var exe = Environment.ProcessPath
                   ?? System.Diagnostics.Process.GetCurrentProcess().MainModule?.FileName;
            if (exe is not null)
                run.SetValue(AppName, $"\"{exe}\"");
        }
        else
        {
            run.DeleteValue(AppName, throwOnMissingValue: false);
        }
    }
}
