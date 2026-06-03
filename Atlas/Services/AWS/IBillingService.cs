using Atlas.Models;

namespace Atlas.Services.AWS;

public interface IBillingService
{
    Task<BillingReport> GetCostBreakdownAsync(
        DateOnly          start,
        DateOnly          end,
        string            groupBy = "SERVICE",
        CancellationToken ct      = default);
}
