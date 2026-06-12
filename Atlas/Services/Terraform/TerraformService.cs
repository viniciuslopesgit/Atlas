using Atlas.Infrastructure.Logging;
using Atlas.Models;
using Atlas.Services.Terraform.Hcl;
using Atlas.Services.Terraform.Hcl.Models;
using Atlas.Services.Terraform.Import;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace Atlas.Services.Terraform;

public sealed class TerraformService : ITerraformService
{
    private readonly ITerraformProjectManager  _projects;
    private readonly ITerraformHclGenerator    _hcl;
    private readonly ITerraformCliWrapper      _cli;
    private readonly IImportService            _importer;
    private readonly IAccountService           _accounts;

    public TerraformService(
        ITerraformProjectManager  projects,
        ITerraformHclGenerator    hcl,
        ITerraformCliWrapper      cli,
        IImportService            importer,
        IAccountService           accounts)
    {
        _projects = projects;
        _hcl      = hcl;
        _cli      = cli;
        _importer = importer;
        _accounts = accounts;
    }

    // ══════════════════════════════════════════════════════════════════════
    // ActiveProject
    // ══════════════════════════════════════════════════════════════════════

    public TerraformProjectConfig? ActiveProject =>
        _projects.GetProjects().FirstOrDefault(p => p.IsInitialized)
        ?? _projects.GetProjects().FirstOrDefault();

    // ══════════════════════════════════════════════════════════════════════
    // GenerateAndWriteResourceAsync
    // ══════════════════════════════════════════════════════════════════════

    public Task<TerraformOperationResult> GenerateEc2ResourceAsync(
        Ec2InstanceHclModel model,
        string?             projectId = null,
        CancellationToken   ct        = default) =>
        GenerateAndWriteResourceAsync(model, projectId, ct);

    public Task<TerraformOperationResult> GenerateS3ResourceAsync(
        S3BucketHclModel  model,
        string?           projectId = null,
        CancellationToken ct        = default) =>
        GenerateAndWriteResourceAsync(model, projectId, ct);

    public async Task<TerraformOperationResult> GenerateAndWriteResourceAsync(
        object             model,
        string?            projectId  = null,
        CancellationToken  ct         = default)
    {
        const string Op = "GenerateResource";
        var sw    = Stopwatch.StartNew();
        var steps = new List<OperationStep>();

        var project = ResolveProject(projectId);
        if (project is null)
            return TerraformOperationResult.Fail(Op, NoProjectError());

        // Dispatch para o método tipado correcto do HclGenerator
        var outputPath = Path.Combine(project.RootPath, OutputFileFor(model));

        var hclResult = model switch
        {
            Ec2InstanceHclModel   ec2  => await _hcl.GenerateEc2InstanceAsync(ec2,  outputPath, ct),
            S3BucketHclModel      s3   => await _hcl.GenerateS3BucketAsync(s3,      outputPath, ct),
            SecurityGroupHclModel sg   => await _hcl.GenerateSecurityGroupAsync(sg, outputPath, ct),
            IamRoleHclModel       role => await _hcl.GenerateIamRoleAsync(role,     outputPath, ct),
            _ => await _hcl.GenerateAsync(new HclGenerationRequest
                 {
                     TemplateName = model.GetType().Name.ToLowerInvariant(),
                     Model        = model,
                     OutputPath   = outputPath,
                 }, ct),
        };

        sw.Stop();

        if (!hclResult.Success)
        {
            steps.Add(OperationStep.Err("GenerateHCL", hclResult.ErrorMessage ?? "Unknown error"));
            return TerraformOperationResult.Fail(Op, hclResult.ErrorMessage ?? "HCL generation failed.", steps);
        }

        steps.Add(OperationStep.Ok("GenerateHCL",
            $"Written {hclResult.ManagedBlockKeys.Count} block(s) → {Path.GetFileName(outputPath)}",
            sw.Elapsed));

        FileLogger.Info($"[TerraformService] GenerateResource  file={outputPath}  blocks={hclResult.ManagedBlockKeys.Count}");

        return TerraformOperationResult.Ok(
            operation:      Op,
            output:         hclResult.Content,
            duration:       sw.Elapsed,
            writtenFiles:   hclResult.WasWritten ? [outputPath] : [],
            generatedBlocks: hclResult.ManagedBlockKeys,
            steps:          steps);
    }

    // ══════════════════════════════════════════════════════════════════════
    // ImportExistingResourcesAsync
    // ══════════════════════════════════════════════════════════════════════

    public async Task<TerraformOperationResult> ImportExistingResourcesAsync(
        ImportOptions      options,
        bool               generateHcl = true,
        IProgress<string>? progress    = null,
        CancellationToken  ct          = default)
    {
        const string Op = "ImportExistingResources";
        var sw    = Stopwatch.StartNew();
        var steps = new List<OperationStep>();
        var log   = new StringBuilder();

        var project = ActiveProject;
        if (project is null)
        {
            return TerraformOperationResult.Fail(Op, NoProjectError());
        }

        // Preenche a região se não fornecida
        var effectiveOptions = string.IsNullOrWhiteSpace(options.Region)
            ? new ImportOptions
            {
                Region                  = _accounts.ActiveRegion,
                ResourceTypes           = options.ResourceTypes,
                TagFilters              = options.TagFilters,
                MaxResourcesPerType     = options.MaxResourcesPerType,
                IncludeTerminated       = options.IncludeTerminated,
                IncludeAwsManagedResources = options.IncludeAwsManagedResources,
            }
            : options;

        // ── Passo 1: descoberta ──────────────────────────────────────────
        var stepSw = Stopwatch.StartNew();
        progress?.Report($"Discovering resources in {effectiveOptions.Region}…");

        ImportAnalysisResult analysis;
        try
        {
            analysis = await _importer.DiscoverResourcesAsync(effectiveOptions, progress, ct);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return TerraformOperationResult.Fail(Op, $"Discovery failed: {ex.Message}", steps);
        }

        stepSw.Stop();
        var discoverMsg = $"Discovered {analysis.TotalDiscovered} resources "
                        + $"({string.Join(", ", analysis.CountByType.Select(kv => $"{kv.Value} {kv.Key}"))})";
        steps.Add(OperationStep.Ok("DiscoverResources", discoverMsg, stepSw.Elapsed));
        log.AppendLine(discoverMsg);

        if (analysis.PartialErrors.Count > 0)
        {
            foreach (var (type, err) in analysis.PartialErrors)
                log.AppendLine($"  ⚠ {type}: {err}");
        }

        if (analysis.TotalDiscovered == 0)
        {
            return TerraformOperationResult.Ok(Op, log.ToString(), sw.Elapsed,
                writtenFiles: [], generatedBlocks: [], analysis: analysis, steps: steps);
        }

        // ── Passo 2: gerar imports.tf ────────────────────────────────────
        stepSw.Restart();
        progress?.Report("Writing imports.tf…");

        var importBlocks  = await _importer.GenerateImportBlocksAsync(analysis.Resources, ct);
        var importsPath   = Path.Combine(project.RootPath, "imports.tf");
        var writtenFiles  = new List<string>();
        var allBlocks     = new List<string>();

        try
        {
            await WriteWithMergeAsync(importsPath, importBlocks, ct);
            writtenFiles.Add(importsPath);
            var keys = HclMergeEngine.ExtractKeys(importBlocks);
            allBlocks.AddRange(keys);
            steps.Add(OperationStep.Ok("WriteImports",
                $"imports.tf — {keys.Count} import block(s)", stepSw.Elapsed));
            log.AppendLine($"Written imports.tf ({keys.Count} blocks)");
        }
        catch (Exception ex)
        {
            steps.Add(OperationStep.Err("WriteImports", ex.Message));
            log.AppendLine($"⚠ imports.tf write failed: {ex.Message}");
        }

        // ── Passo 3: sugestões HCL (opcional) ───────────────────────────
        IReadOnlyList<HclSuggestion>? suggestions = null;

        if (generateHcl && analysis.TotalDiscovered > 0)
        {
            stepSw.Restart();
            progress?.Report("Generating HCL suggestions…");

            try
            {
                suggestions = await _importer.SuggestHclFromExistingResourcesAsync(
                    analysis.Resources, project.RootPath, ct);

                var written = suggestions.Where(s => s.HclResult.WasWritten).ToList();
                var failed  = suggestions.Where(s => !s.HclResult.Success).ToList();

                foreach (var s in written.Select(s => s.HclResult.OutputPath!).Distinct())
                    writtenFiles.Add(s);

                foreach (var s in suggestions.SelectMany(s => s.HclResult.ManagedBlockKeys))
                    allBlocks.Add(s);

                var hclMsg = $"HCL: {written.Count} file(s) written";
                if (failed.Count > 0) hclMsg += $", {failed.Count} skipped (no template)";
                steps.Add(OperationStep.Ok("GenerateHCL", hclMsg, stepSw.Elapsed));
                log.AppendLine(hclMsg);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                steps.Add(OperationStep.Err("GenerateHCL", ex.Message));
                log.AppendLine($"⚠ HCL generation failed: {ex.Message}");
            }
        }

        sw.Stop();
        FileLogger.Info($"[TerraformService] ImportExisting  resources={analysis.TotalDiscovered}  files={writtenFiles.Count}");

        return TerraformOperationResult.Ok(
            operation:      Op,
            output:         log.ToString(),
            duration:       sw.Elapsed,
            writtenFiles:   writtenFiles,
            generatedBlocks: allBlocks,
            analysis:       analysis,
            suggestions:    suggestions,
            steps:          steps);
    }

    // ══════════════════════════════════════════════════════════════════════
    // SyncWithAwsAsync
    // ══════════════════════════════════════════════════════════════════════

    public async Task<TerraformOperationResult> SyncWithAwsAsync(
        IProgress<string>? progress = null,
        CancellationToken  ct       = default)
    {
        const string Op = "SyncWithAws";
        var sw    = Stopwatch.StartNew();
        var steps = new List<OperationStep>();
        var log   = new StringBuilder();

        var project = ActiveProject;
        if (project is null)
            return TerraformOperationResult.Fail(Op, NoProjectError());

        progress?.Report($"Starting full sync — project: {project.Name}");
        log.AppendLine($"Project : {project.Name}");
        log.AppendLine($"Path    : {project.RootPath}");
        log.AppendLine($"Region  : {_accounts.ActiveRegion}");
        log.AppendLine();

        // ── Passo 1: Garantir que o projecto está inicializado ────────────
        if (!project.IsInitialized)
        {
            var initResult = await EnsureInitializedAsync(ct);
            steps.AddRange(initResult.Steps);
            if (!initResult.Success)
                return TerraformOperationResult.Fail(Op, initResult.ErrorMessage!, steps);
            log.AppendLine($"Init: {initResult.Output}");
        }

        // ── Passo 2: Importar + gerar HCL para todos os tipos ─────────────
        var importOpts = new ImportOptions
        {
            Region        = _accounts.ActiveRegion,
            ResourceTypes = Enum.GetValues<AwsResourceType>().ToList(),
        };

        var importResult = await ImportExistingResourcesAsync(
            importOpts, generateHcl: true, progress: progress, ct: ct);

        steps.AddRange(importResult.Steps);
        log.AppendLine(importResult.Output);

        if (!importResult.Success)
            return TerraformOperationResult.Fail(Op, importResult.ErrorMessage!, steps);

        // ── Passo 3: terraform validate ──────────────────────────────────
        progress?.Report("Running terraform validate…");
        var validateSw = Stopwatch.StartNew();
        TerraformResult? validateResult = null;

        try
        {
            validateResult = await _cli.ValidateAsync(project.RootPath, progress: progress, ct: ct);
            validateSw.Stop();

            if (validateResult.IsSuccess)
            {
                steps.Add(OperationStep.Ok("Validate", "terraform validate passed", validateSw.Elapsed));
                log.AppendLine("✓ terraform validate passed");
            }
            else
            {
                steps.Add(OperationStep.Err("Validate", validateResult.DiagnosticMessage));
                log.AppendLine($"✗ terraform validate: {validateResult.DiagnosticMessage}");
                // Validate falhou mas não cancela o sync — só avisa
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            steps.Add(OperationStep.Err("Validate", ex.Message));
            log.AppendLine($"⚠ validate skipped: {ex.Message}");
        }

        sw.Stop();
        var summary = $"Sync complete — {importResult.ResourcesFound} resources, "
                    + $"{importResult.WrittenFiles.Count} files written";
        log.AppendLine();
        log.AppendLine(summary);

        FileLogger.Info($"[TerraformService] SyncWithAws  {summary}  duration={sw.Elapsed.TotalSeconds:0.0}s");

        return TerraformOperationResult.Ok(
            operation:      Op,
            output:         log.ToString(),
            duration:       sw.Elapsed,
            writtenFiles:   importResult.WrittenFiles,
            generatedBlocks: importResult.GeneratedBlocks,
            cli:            validateResult,
            analysis:       importResult.ImportAnalysis,
            suggestions:    importResult.HclSuggestions,
            steps:          steps);
    }

    // ══════════════════════════════════════════════════════════════════════
    // EnsureInitializedAsync
    // ══════════════════════════════════════════════════════════════════════

    public async Task<TerraformOperationResult> EnsureInitializedAsync(
        CancellationToken ct = default)
    {
        const string Op = "EnsureInitialized";
        var steps = new List<OperationStep>();

        var project = ActiveProject;
        if (project is null)
            return TerraformOperationResult.Fail(Op, NoProjectError());

        if (project.IsInitialized)
        {
            steps.Add(OperationStep.Ok("Init", "Already initialized — skipped.", TimeSpan.Zero));
            return TerraformOperationResult.Ok(Op, "Already initialized.", TimeSpan.Zero,
                writtenFiles: [], generatedBlocks: [], steps: steps);
        }

        var sw     = Stopwatch.StartNew();
        var result = await _projects.InitializeAsync(project.Id, ct);
        sw.Stop();

        if (result.Success)
        {
            steps.Add(OperationStep.Ok("Init", "terraform init succeeded.", sw.Elapsed));
            return TerraformOperationResult.Ok(Op, result.Output, sw.Elapsed,
                writtenFiles: [], generatedBlocks: [], steps: steps);
        }

        steps.Add(OperationStep.Err("Init", result.ErrorMessage ?? "terraform init failed."));
        return TerraformOperationResult.Fail(Op, result.ErrorMessage ?? "terraform init failed.", steps);
    }

    // ══════════════════════════════════════════════════════════════════════
    // RunPlanAsync
    // ══════════════════════════════════════════════════════════════════════

    public async Task<TerraformOperationResult> RunPlanAsync(
        IProgress<string>? progress = null,
        CancellationToken  ct       = default)
    {
        const string Op = "Plan";
        var steps = new List<OperationStep>();

        var project = ActiveProject;
        if (project is null)
            return TerraformOperationResult.Fail(Op, NoProjectError());

        if (!project.IsInitialized)
        {
            var init = await EnsureInitializedAsync(ct);
            steps.AddRange(init.Steps);
            if (!init.Success)
                return TerraformOperationResult.Fail(Op, init.ErrorMessage!, steps);
        }

        var sw      = Stopwatch.StartNew();
        var creds   = BuildCredentials();
        var planOut = Path.Combine(project.RootPath, ".atlas_plan.tfplan");

        progress?.Report("Running terraform plan…");

        var result = await _cli.PlanAsync(
            workingDir:  project.RootPath,
            detailed:    true,
            planOutFile: planOut,
            credentials: creds,
            progress:    progress,
            ct:          ct);

        sw.Stop();

        var stepMsg = result.Status switch
        {
            TerraformResultStatus.PlanHasChanges => "Plan complete — changes detected.",
            TerraformResultStatus.NoChanges      => "Plan complete — no changes.",
            _                                    => result.DiagnosticMessage,
        };

        steps.Add(result.IsSuccess
            ? OperationStep.Ok("Plan", stepMsg, sw.Elapsed)
            : OperationStep.Err("Plan", stepMsg));

        FileLogger.Info($"[TerraformService] Plan  status={result.Status}  duration={sw.Elapsed.TotalSeconds:0.0}s");

        if (!result.IsSuccess)
            return TerraformOperationResult.Fail(Op, result.DiagnosticMessage, steps);

        return TerraformOperationResult.Ok(Op, result.FullOutput, sw.Elapsed,
            writtenFiles: [], generatedBlocks: [], cli: result, steps: steps);
    }

    // ══════════════════════════════════════════════════════════════════════
    // ApplyChangesAsync
    // ══════════════════════════════════════════════════════════════════════

    public async Task<TerraformOperationResult> ApplyChangesAsync(
        IProgress<string>? progress = null,
        CancellationToken  ct       = default)
    {
        const string Op = "Apply";
        var steps = new List<OperationStep>();

        var project = ActiveProject;
        if (project is null)
            return TerraformOperationResult.Fail(Op, NoProjectError());

        if (!project.IsInitialized)
        {
            var init = await EnsureInitializedAsync(ct);
            steps.AddRange(init.Steps);
            if (!init.Success)
                return TerraformOperationResult.Fail(Op, init.ErrorMessage!, steps);
        }

        var sw    = Stopwatch.StartNew();
        var creds = BuildCredentials();
        var plan  = Path.Combine(project.RootPath, ".atlas_plan.tfplan");

        // Usa o plan salvo se existir (gerado por RunPlanAsync), senão apply directo
        var planFile = File.Exists(plan) ? plan : null;

        progress?.Report(planFile != null
            ? "Applying saved plan…"
            : "Running terraform apply -auto-approve…");

        var result = await _cli.ApplyAsync(
            workingDir:  project.RootPath,
            planFile:    planFile,
            credentials: creds,
            progress:    progress,
            ct:          ct);

        sw.Stop();

        steps.Add(result.IsSuccess
            ? OperationStep.Ok("Apply", "terraform apply succeeded.", sw.Elapsed)
            : OperationStep.Err("Apply", result.DiagnosticMessage));

        // Limpa o plan file após apply
        if (planFile != null && File.Exists(planFile))
        {
            try { File.Delete(planFile); } catch { /* non-fatal */ }
        }

        FileLogger.Info($"[TerraformService] Apply  status={result.Status}  duration={sw.Elapsed.TotalSeconds:0.0}s");

        if (!result.IsSuccess)
            return TerraformOperationResult.Fail(Op, result.DiagnosticMessage, steps);

        return TerraformOperationResult.Ok(Op, result.FullOutput, sw.Elapsed,
            writtenFiles: [], generatedBlocks: [], cli: result, steps: steps);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Helpers privados
    // ══════════════════════════════════════════════════════════════════════

    private TerraformProjectConfig? ResolveProject(string? projectId)
    {
        if (projectId is null) return ActiveProject;
        return _projects.GetProjects().FirstOrDefault(p => p.Id == projectId);
    }

    /// <summary>Constrói credenciais AWS da conta activa. Retorna null se sem conta.</summary>
    private TerraformAwsCredentials? BuildCredentials()
    {
        var account = _accounts.ActiveAccount;
        if (account is null) return null;

        return new TerraformAwsCredentials(
            AccessKeyId:     account.AccessKeyId,
            SecretAccessKey: _accounts.GetActiveSecretKey(),
            Region:          _accounts.ActiveRegion);
    }

    /// <summary>
    /// Escreve conteúdo num ficheiro usando o merge engine de ATLAS-MANAGED markers.
    /// Cria o ficheiro se não existir; funde com o existente se já houver.
    /// </summary>
    private static async Task WriteWithMergeAsync(
        string filePath, string newContent, CancellationToken ct)
    {
        var dir = Path.GetDirectoryName(filePath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        if (File.Exists(filePath))
        {
            var existing = await File.ReadAllTextAsync(filePath, System.Text.Encoding.UTF8, ct);
            newContent   = HclMergeEngine.Merge(existing, newContent);
        }

        await File.WriteAllTextAsync(filePath, newContent, System.Text.Encoding.UTF8, ct);
    }

    /// <summary>Mapeia tipo de modelo para nome do ficheiro .tf de destino.</summary>
    private static string OutputFileFor(object model) => model switch
    {
        Ec2InstanceHclModel   => "ec2_instances.tf",
        S3BucketHclModel      => "s3_buckets.tf",
        SecurityGroupHclModel => "security_groups.tf",
        IamRoleHclModel       => "iam_roles.tf",
        _                     => $"{model.GetType().Name.ToLowerInvariant()}.tf",
    };

    private static string NoProjectError() =>
        "No Terraform project configured. Add and initialise a project in the IaC settings first.";
}
