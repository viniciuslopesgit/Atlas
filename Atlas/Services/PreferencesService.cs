using Microsoft.Win32;

namespace Atlas.Services;

public sealed class PreferencesService : IPreferencesService
{
    private const string KeyPath = @"SOFTWARE\Atlas";

    public string? Get(string key)
    {
        using var k = Registry.CurrentUser.OpenSubKey(KeyPath, false);
        return k?.GetValue(key) as string;
    }

    public void Set(string key, string value)
    {
        using var k = Registry.CurrentUser.CreateSubKey(KeyPath, writable: true);
        k.SetValue(key, value, RegistryValueKind.String);
    }
}
