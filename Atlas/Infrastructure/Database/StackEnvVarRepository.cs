using Atlas.Infrastructure.Security;
using Atlas.Models;
using Microsoft.Data.Sqlite;

namespace Atlas.Infrastructure.Database;

/// <summary>
/// SQLite-backed repository for stack environment variables.
/// Values are encrypted with Windows DPAPI before being written to disk —
/// they can only be decrypted by the same Windows user on the same machine.
/// </summary>
public sealed class StackEnvVarRepository : IStackEnvVarRepository
{
    private readonly DatabaseContext     _db;
    private readonly ICredentialProtector _protector;

    public StackEnvVarRepository(DatabaseContext db, ICredentialProtector protector)
    {
        _db        = db;
        _protector = protector;
    }

    // ── Write ─────────────────────────────────────────────────────────────────

    public Task UpsertAsync(string stackName, StackEnvVar var) =>
        UpsertCoreAsync(stackName, var);

    public async Task UpsertBatchAsync(string stackName, IEnumerable<StackEnvVar> vars)
    {
        foreach (var v in vars)
            await UpsertCoreAsync(stackName, v);
    }

    private Task UpsertCoreAsync(string stackName, StackEnvVar v)
    {
        var encrypted = _protector.Protect(v.Value);

        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = """
            INSERT INTO StackEnvVars
                (Id, StackName, TfVarName, EnvKey, EncryptedValue,
                 ResourceType, ResourceName, SourceFile, UpdatedAt)
            VALUES
                ($id, $stack, $tfvar, $envkey, $enc,
                 $rtype, $rname, $file, $now)
            ON CONFLICT(StackName, TfVarName) DO UPDATE SET
                EnvKey         = $envkey,
                EncryptedValue = $enc,
                ResourceType   = $rtype,
                ResourceName   = $rname,
                SourceFile     = $file,
                UpdatedAt      = $now;
            """;
        cmd.Parameters.AddWithValue("$id",     v.Id);
        cmd.Parameters.AddWithValue("$stack",  stackName);
        cmd.Parameters.AddWithValue("$tfvar",  v.TfVarName);
        cmd.Parameters.AddWithValue("$envkey", v.EnvKey);
        cmd.Parameters.AddWithValue("$enc",    encrypted);
        cmd.Parameters.AddWithValue("$rtype",  v.ResourceType);
        cmd.Parameters.AddWithValue("$rname",  v.ResourceName);
        cmd.Parameters.AddWithValue("$file",   v.SourceFile);
        cmd.Parameters.AddWithValue("$now",    DateTime.UtcNow.ToString("O"));
        cmd.ExecuteNonQuery();
        return Task.CompletedTask;
    }

    // ── Read ──────────────────────────────────────────────────────────────────

    public Task<IReadOnlyList<StackEnvVar>> GetForStackAsync(string stackName)
    {
        var list = new List<StackEnvVar>();
        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = """
            SELECT Id, TfVarName, EnvKey, EncryptedValue,
                   ResourceType, ResourceName, SourceFile
            FROM StackEnvVars
            WHERE StackName = $stack
            ORDER BY EnvKey;
            """;
        cmd.Parameters.AddWithValue("$stack", stackName);
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            string plainValue;
            try   { plainValue = _protector.Unprotect(r.GetString(3)); }
            catch { plainValue = "";  /* decryption failed (different machine/user) */ }

            list.Add(new StackEnvVar
            {
                Id           = r.GetString(0),
                TfVarName    = r.GetString(1),
                EnvKey       = r.GetString(2),
                Value        = plainValue,
                ResourceType = r.GetString(4),
                ResourceName = r.GetString(5),
                SourceFile   = r.GetString(6),
            });
        }
        return Task.FromResult<IReadOnlyList<StackEnvVar>>(list);
    }

    public async Task<IReadOnlyDictionary<string, string>> GetTfVarsAsync(string stackName)
    {
        var all = await GetForStackAsync(stackName);
        return all
            .Where(v => !string.IsNullOrEmpty(v.Value))
            .ToDictionary(v => v.TfVarName, v => v.Value);
    }

    // ── Delete ────────────────────────────────────────────────────────────────

    public Task DeleteAsync(string stackName, string tfVarName)
    {
        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = "DELETE FROM StackEnvVars WHERE StackName=$s AND TfVarName=$v;";
        cmd.Parameters.AddWithValue("$s", stackName);
        cmd.Parameters.AddWithValue("$v", tfVarName);
        cmd.ExecuteNonQuery();
        return Task.CompletedTask;
    }

    public Task DeleteAllForStackAsync(string stackName)
    {
        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = "DELETE FROM StackEnvVars WHERE StackName=$s;";
        cmd.Parameters.AddWithValue("$s", stackName);
        cmd.ExecuteNonQuery();
        return Task.CompletedTask;
    }
}
