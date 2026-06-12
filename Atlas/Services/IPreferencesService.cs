namespace Atlas.Services;

public interface IPreferencesService
{
    string? Get(string key);
    void Set(string key, string value);
}
