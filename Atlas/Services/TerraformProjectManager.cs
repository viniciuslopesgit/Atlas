using Atlas.Infrastructure.Database;
using Atlas.Infrastructure.Logging;
using Atlas.Models;
using Atlas.Services.Terraform;
using System.IO;

namespace Atlas.Services;

public sealed class TerraformProjectManager : ITerraformProjectManager
{
    private readonly ITerraformProjectRepository _repo;
    private readonly ITerraformCliWrapper        _cli;

    public TerraformProjectManager(
        ITerraformProjectRepository repo,
        ITerraformCliWrapper        cli)
    {
        _repo = repo;
        _cli  = cli;
    }

    public IReadOnlyList<TerraformProjectConfig> GetProjects() => _repo.GetAll();

    public Task<bool> ValidateProjectAsync(string rootPath, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(rootPath) || !Directory.Exists(rootPath))
            return Task.FromResult(false);

        var hasTfFiles = Directory.EnumerateFiles(rootPath, "*.tf", SearchOption.TopDirectoryOnly).Any();
        return Task.FromResult(hasTfFiles);
    }

    public async Task<TerraformInitResult> InitializeAsync(
        string            projectId,
        CancellationToken ct = default)
    {
        var project = _repo.GetAll().FirstOrDefault(p => p.Id == projectId);
        if (project is null)
            return new TerraformInitResult(false, string.Empty, "Projeto não encontrado.");

        if (!Directory.Exists(project.RootPath))
            return new TerraformInitResult(false, string.Empty, $"Diretório não encontrado: {project.RootPath}");

        var result = await _cli.InitAsync(project.RootPath, upgrade: false, ct: ct)
                               .ConfigureAwait(false);

        if (result.IsSuccess)
            _repo.MarkInitialized(projectId, true);
        else
            FileLogger.Warning($"[TerraformManager] init falhou: {result.DiagnosticMessage}");

        return new TerraformInitResult(
            result.IsSuccess,
            result.FullOutput,
            result.IsSuccess ? null : result.DiagnosticMessage);
    }

    public void SaveProject(TerraformProjectConfig config)  => _repo.Save(config);
    public void DeleteProject(string id)                    => _repo.Delete(id);
}
