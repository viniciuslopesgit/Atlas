namespace Atlas.Services;

public interface IBudgetService
{
    decimal? GetMonthlyBudget(string accountId);
    void     SetMonthlyBudget(string accountId, decimal? budget);
}
