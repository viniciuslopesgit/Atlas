using System.Globalization;
using Atlas.Infrastructure.Database;

namespace Atlas.Services;

public sealed class BudgetService : IBudgetService
{
    private readonly DatabaseContext _db;

    public BudgetService(DatabaseContext db) => _db = db;

    public decimal? GetMonthlyBudget(string accountId)
    {
        using var cmd = _db.Connection.CreateCommand();
        cmd.CommandText = "SELECT Value FROM AppSettings WHERE Key=$key";
        cmd.Parameters.AddWithValue("$key", $"budget:{accountId}");
        var result = cmd.ExecuteScalar();
        return result is string s && decimal.TryParse(s, NumberStyles.Any,
            CultureInfo.InvariantCulture, out var val) ? val : null;
    }

    public void SetMonthlyBudget(string accountId, decimal? budget)
    {
        using var cmd = _db.Connection.CreateCommand();
        if (budget is > 0)
        {
            cmd.CommandText = """
                INSERT INTO AppSettings(Key, Value) VALUES($key, $val)
                ON CONFLICT(Key) DO UPDATE SET Value=$val;
                """;
            cmd.Parameters.AddWithValue("$val", budget.Value.ToString("F2", CultureInfo.InvariantCulture));
        }
        else
        {
            cmd.CommandText = "DELETE FROM AppSettings WHERE Key=$key";
        }
        cmd.Parameters.AddWithValue("$key", $"budget:{accountId}");
        cmd.ExecuteNonQuery();
    }
}
