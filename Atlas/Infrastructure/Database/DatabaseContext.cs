using Microsoft.Data.Sqlite;
using System.IO;

namespace Atlas.Infrastructure.Database;

public sealed class DatabaseContext : IDisposable
{
    private readonly SqliteConnection _connection;

    public DatabaseContext()
    {
        var folder = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Atlas");
        Directory.CreateDirectory(folder);

        var dbPath = Path.Combine(folder, "Atlas.db");
        _connection = new SqliteConnection($"Data Source={dbPath}");
        _connection.Open();
        InitializeSchema();
    }

    public SqliteConnection Connection => _connection;

    private void InitializeSchema()
    {
        using var cmd = _connection.CreateCommand();
        cmd.CommandText = """
            CREATE TABLE IF NOT EXISTS AwsAccounts (
                Id TEXT PRIMARY KEY,
                Name TEXT NOT NULL,
                AccessKeyId TEXT NOT NULL,
                EncryptedSecretKey TEXT NOT NULL,
                DefaultRegion TEXT NOT NULL DEFAULT 'us-east-1',
                CreatedAt TEXT NOT NULL,
                IsActive INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS AppSettings (
                Key TEXT PRIMARY KEY,
                Value TEXT NOT NULL
            );
            """;
        cmd.ExecuteNonQuery();
    }

    public void Dispose() => _connection.Dispose();
}
