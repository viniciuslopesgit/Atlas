using Atlas.Infrastructure.Security;
using Atlas.Models;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Atlas.Services;

public sealed class StackRepository : IStackRepository
{
    private readonly string               _filePath;
    private readonly ICredentialProtector _protector;
    private List<StackEntry> _cache = [];
    private bool _loaded;

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented           = true,
        PropertyNameCaseInsensitive = true,
        Converters              = { new JsonStringEnumConverter() },
    };

    public StackRepository(ICredentialProtector protector)
    {
        _protector = protector;
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Atlas");
        Directory.CreateDirectory(dir);
        _filePath = Path.Combine(dir, "stacks.json");
    }

    public IReadOnlyList<StackEntry> GetAll()
    {
        EnsureLoaded();
        return _cache.AsReadOnly();
    }

    public StackEntry? GetById(string id)
    {
        EnsureLoaded();
        return _cache.FirstOrDefault(s => s.Id == id);
    }

    public void Save(StackEntry stack)
    {
        EnsureLoaded();
        var idx = _cache.FindIndex(s => s.Id == stack.Id);
        if (idx >= 0) _cache[idx] = stack;
        else          _cache.Add(stack);
        Persist();
    }

    public void Delete(string id)
    {
        EnsureLoaded();
        _cache.RemoveAll(s => s.Id == id);
        Persist();
    }

    private void EnsureLoaded()
    {
        if (_loaded) return;
        _loaded = true;
        if (!File.Exists(_filePath)) return;
        try
        {
            var json = File.ReadAllText(_filePath);
            _cache = JsonSerializer.Deserialize<List<StackEntry>>(json, Json) ?? [];
            foreach (var stack in _cache)
                foreach (var run in stack.Runs)
                    TryDecryptOutput(run);
        }
        catch { _cache = []; }
    }

    private void TryDecryptOutput(StackRun run)
    {
        if (string.IsNullOrEmpty(run.EncryptedOutput)) return;
        try   { run.Output = _protector.Unprotect(run.EncryptedOutput); }
        catch { /* decryption failed (different user/machine) — leave Output empty */ }
    }

    private void Persist()
    {
        // Sync EncryptedOutput from in-memory Output before writing.
        // Output is [JsonIgnore] so it never appears in the file.
        foreach (var stack in _cache)
            foreach (var run in stack.Runs)
                if (!string.IsNullOrEmpty(run.Output))
                    run.EncryptedOutput = _protector.Protect(run.Output);

        try { File.WriteAllText(_filePath, JsonSerializer.Serialize(_cache, Json)); }
        catch { }
    }
}
