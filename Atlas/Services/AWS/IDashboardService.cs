using Atlas.Models;

namespace Atlas.Services.AWS;

public interface IDashboardService
{
    Task<DashboardSummary> GetSummaryAsync(DateOnly month, CancellationToken ct = default);
}
