using Atlas.Models;

namespace Atlas.Services;

public sealed record TerraformInitResult(bool Success, string Output, string? ErrorMessage = null);

public interface ITerraformProjectManager
{
    IReadOnlyList<TerraformProjectConfig> GetProjects();
    Task<bool> ValidateProjectAsync(string rootPath, CancellationToken ct = default);
    Task<TerraformInitResult> InitializeAsync(string projectId, CancellationToken ct = default);
    void SaveProject(TerraformProjectConfig config);
    void DeleteProject(string id);
}
