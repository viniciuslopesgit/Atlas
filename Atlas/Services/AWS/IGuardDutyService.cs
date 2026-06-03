using Atlas.Models;

namespace Atlas.Services.AWS;

public interface IGuardDutyService
{
    Task<IReadOnlyList<GuardDutyFindingModel>> GetFindingsAsync(CancellationToken ct = default);
}
