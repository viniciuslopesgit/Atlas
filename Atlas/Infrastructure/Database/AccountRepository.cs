using Atlas.Models;
using Microsoft.Data.Sqlite;

namespace Atlas.Infrastructure.Database;

public interface IAccountRepository
{
    IReadOnlyList<AwsAccount> GetAll();
    void Save(AwsAccount account);
    void Delete(string id);
    void SetActive(string id);
}

public sealed class AccountRepository : IAccountRepository
{
    private readonly DatabaseContext _db;

    public AccountRepository(DatabaseContext db) => _db = db;

    public IReadOnlyList<AwsAccount> GetAll()
    {
        var list = new List<AwsAccount>();
        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = "SELECT * FROM AwsAccounts ORDER BY CreatedAt";
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            list.Add(new AwsAccount
            {
                Id = reader.GetString(0),
                Name = reader.GetString(1),
                AccessKeyId = reader.GetString(2),
                EncryptedSecretKey = reader.GetString(3),
                DefaultRegion = reader.GetString(4),
                CreatedAt = DateTime.Parse(reader.GetString(5)),
                IsActive = reader.GetInt32(6) == 1
            });
        }
        return list;
    }

    public void Save(AwsAccount account)
    {
        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = """
            INSERT INTO AwsAccounts VALUES ($id,$name,$ak,$sk,$region,$created,$active)
            ON CONFLICT(Id) DO UPDATE SET
                Name=$name, AccessKeyId=$ak, EncryptedSecretKey=$sk,
                DefaultRegion=$region, IsActive=$active;
            """;
        cmd.Parameters.AddWithValue("$id", account.Id);
        cmd.Parameters.AddWithValue("$name", account.Name);
        cmd.Parameters.AddWithValue("$ak", account.AccessKeyId);
        cmd.Parameters.AddWithValue("$sk", account.EncryptedSecretKey);
        cmd.Parameters.AddWithValue("$region", account.DefaultRegion);
        cmd.Parameters.AddWithValue("$created", account.CreatedAt.ToString("O"));
        cmd.Parameters.AddWithValue("$active", account.IsActive ? 1 : 0);
        cmd.ExecuteNonQuery();
    }

    public void Delete(string id)
    {
        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = "DELETE FROM AwsAccounts WHERE Id=$id";
        cmd.Parameters.AddWithValue("$id", id);
        cmd.ExecuteNonQuery();
    }

    public void SetActive(string id)
    {
        using var tx  = _db.Connection.BeginTransaction();
        using var cmd = _db.Connection.CreateCommand();
        cmd.Transaction = tx;
        cmd.Parameters.AddWithValue("$id", id);

        cmd.CommandText = "UPDATE AwsAccounts SET IsActive=0";
        cmd.ExecuteNonQuery();

        cmd.CommandText = "UPDATE AwsAccounts SET IsActive=1 WHERE Id=$id";
        cmd.ExecuteNonQuery();

        tx.Commit();
    }
}
