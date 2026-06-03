using Atlas.Models;

namespace Atlas.Services.AWS;

public interface ISecurityAuditService
{
    Task<SecurityAuditResult> RunAuditAsync(CancellationToken ct = default);
}
