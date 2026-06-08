using Atlas.Models;

namespace Atlas.Infrastructure.Database;

public sealed class TerraformProjectRepository : ITerraformProjectRepository
{
    private readonly DatabaseContext _db;

    public TerraformProjectRepository(DatabaseContext db) => _db = db;

    public IReadOnlyList<TerraformProjectConfig> GetAll()
    {
        var list = new List<TerraformProjectConfig>();
        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = "SELECT Id, Name, RootPath, DefaultWorkspace, BackendType, AutoCommitEnabled, ManagedModules, CreatedAt, IsInitialized FROM TerraformProjects ORDER BY CreatedAt";
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            list.Add(new TerraformProjectConfig
            {
                Id                = reader.GetString(0),
                Name              = reader.GetString(1),
                RootPath          = reader.GetString(2),
                DefaultWorkspace  = reader.GetString(3),
                BackendType       = reader.GetString(4),
                AutoCommitEnabled = reader.GetInt32(5) == 1,
                ManagedModules    = reader.GetString(6),
                CreatedAt         = DateTime.Parse(reader.GetString(7)),
                IsInitialized     = reader.GetInt32(8) == 1,
            });
        }
        return list;
    }

    public void Save(TerraformProjectConfig config)
    {
        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = """
            INSERT INTO TerraformProjects
                (Id, Name, RootPath, DefaultWorkspace, BackendType, AutoCommitEnabled, ManagedModules, CreatedAt, IsInitialized)
            VALUES
                ($id, $name, $path, $workspace, $backend, $autoCommit, $modules, $created, $init)
            ON CONFLICT(Id) DO UPDATE SET
                Name=$name, RootPath=$path, DefaultWorkspace=$workspace,
                BackendType=$backend, AutoCommitEnabled=$autoCommit,
                ManagedModules=$modules, IsInitialized=$init;
            """;
        cmd.Parameters.AddWithValue("$id",         config.Id);
        cmd.Parameters.AddWithValue("$name",        config.Name);
        cmd.Parameters.AddWithValue("$path",        config.RootPath);
        cmd.Parameters.AddWithValue("$workspace",   config.DefaultWorkspace);
        cmd.Parameters.AddWithValue("$backend",     config.BackendType);
        cmd.Parameters.AddWithValue("$autoCommit",  config.AutoCommitEnabled ? 1 : 0);
        cmd.Parameters.AddWithValue("$modules",     config.ManagedModules);
        cmd.Parameters.AddWithValue("$created",     config.CreatedAt.ToString("O"));
        cmd.Parameters.AddWithValue("$init",        config.IsInitialized ? 1 : 0);
        cmd.ExecuteNonQuery();
    }

    public void Delete(string id)
    {
        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = "DELETE FROM TerraformProjects WHERE Id=$id";
        cmd.Parameters.AddWithValue("$id", id);
        cmd.ExecuteNonQuery();
    }

    public void MarkInitialized(string id, bool value)
    {
        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = "UPDATE TerraformProjects SET IsInitialized=$val WHERE Id=$id";
        cmd.Parameters.AddWithValue("$val", value ? 1 : 0);
        cmd.Parameters.AddWithValue("$id",  id);
        cmd.ExecuteNonQuery();
    }
}
