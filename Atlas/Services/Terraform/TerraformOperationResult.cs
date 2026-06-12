using Atlas.Services.Terraform.Import;

namespace Atlas.Services.Terraform;

/// <summary>
/// Resultado unificado para todas as operações do <see cref="ITerraformService"/>.
/// Cobre operações de geração de HCL, CLI e import em simultâneo.
/// </summary>
public sealed class TerraformOperationResult
{
    // ── Estado geral ──────────────────────────────────────────────────────
    public bool     Success       { get; init; }
    public string   OperationName { get; init; } = string.Empty;
    public string?  ErrorMessage  { get; init; }
    public TimeSpan Duration      { get; init; }

    /// <summary>Output consolidado (logs, mensagens de diagnóstico).</summary>
    public string Output { get; init; } = string.Empty;

    // ── Geração de ficheiros ──────────────────────────────────────────────

    /// <summary>Caminhos absolutos dos ficheiros .tf escritos nesta operação.</summary>
    public IReadOnlyList<string> WrittenFiles { get; init; } = [];

    /// <summary>Chaves dos blocos ATLAS-MANAGED gerados/actualizados.</summary>
    public IReadOnlyList<string> GeneratedBlocks { get; init; } = [];

    // ── CLI Terraform ─────────────────────────────────────────────────────

    /// <summary>Resultado bruto do comando terraform (plan/apply/init/validate).</summary>
    public TerraformResult? CliResult { get; init; }

    // ── Import / Sync ─────────────────────────────────────────────────────

    /// <summary>Análise de descoberta de recursos AWS (preenchido em import/sync).</summary>
    public ImportAnalysisResult? ImportAnalysis { get; init; }

    /// <summary>Sugestões de HCL geradas a partir dos recursos descobertos.</summary>
    public IReadOnlyList<HclSuggestion>? HclSuggestions { get; init; }

    // ── Histórico de passos ───────────────────────────────────────────────

    /// <summary>
    /// Log estruturado dos passos executados nesta operação.
    /// Útil para debug e exibição de progresso no UI.
    /// </summary>
    public IReadOnlyList<OperationStep> Steps { get; init; } = [];

    // ── Conveniences ─────────────────────────────────────────────────────

    public bool HasCliResult   => CliResult is not null;
    public bool HasImport      => ImportAnalysis is not null;
    public bool PlanHasChanges => CliResult?.Status == TerraformResultStatus.PlanHasChanges;
    public int  ResourcesFound => ImportAnalysis?.TotalDiscovered ?? 0;

    // ── Factories ─────────────────────────────────────────────────────────

    internal static TerraformOperationResult Ok(
        string                         operation,
        string                         output,
        TimeSpan                       duration,
        IReadOnlyList<string>          writtenFiles,
        IReadOnlyList<string>          generatedBlocks,
        TerraformResult?               cli        = null,
        ImportAnalysisResult?          analysis   = null,
        IReadOnlyList<HclSuggestion>?  suggestions = null,
        IReadOnlyList<OperationStep>?  steps       = null) =>
        new()
        {
            Success         = true,
            OperationName   = operation,
            Output          = output,
            Duration        = duration,
            WrittenFiles    = writtenFiles,
            GeneratedBlocks = generatedBlocks,
            CliResult       = cli,
            ImportAnalysis  = analysis,
            HclSuggestions  = suggestions,
            Steps           = steps ?? [],
        };

    internal static TerraformOperationResult Fail(
        string                        operation,
        string                        error,
        IReadOnlyList<OperationStep>? steps = null) =>
        new()
        {
            Success       = false,
            OperationName = operation,
            ErrorMessage  = error,
            Steps         = steps ?? [],
        };
}

/// <summary>Um passo individual dentro de uma operação Terraform multi-fase.</summary>
public sealed class OperationStep
{
    public string    Name      { get; init; } = string.Empty;
    public bool      Success   { get; init; }
    public string    Message   { get; init; } = string.Empty;
    public TimeSpan  Duration  { get; init; }

    public static OperationStep Ok(string name, string msg, TimeSpan d) =>
        new() { Name = name, Success = true,  Message = msg, Duration = d };

    public static OperationStep Err(string name, string msg) =>
        new() { Name = name, Success = false, Message = msg };
}
