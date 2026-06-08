using System.Collections.Generic;

namespace Atlas.Services.Terraform;

public enum TerraformResultStatus
{
    /// <summary>Comando concluído sem erros (exit 0).</summary>
    Success,

    /// <summary>terraform plan: concluiu e detectou mudanças pendentes (exit 2). Não é erro.</summary>
    PlanHasChanges,

    /// <summary>terraform plan: concluiu e não há mudanças (exit 0).</summary>
    NoChanges,

    /// <summary>Terraform retornou código de saída ≥ 1 com erros.</summary>
    Failed,

    /// <summary>Operação cancelada via CancellationToken.</summary>
    Cancelled,

    /// <summary>Timeout configurável excedido.</summary>
    TimedOut,

    /// <summary>Binário 'terraform' não encontrado no PATH.</summary>
    TerraformNotFound,
}

public sealed record TerraformResult
{
    public TerraformResultStatus Status    { get; init; }
    public int                   ExitCode  { get; init; }
    public string                Stdout    { get; init; } = string.Empty;
    public string                Stderr    { get; init; } = string.Empty;
    public string                DiagnosticMessage { get; init; } = string.Empty;
    public TimeSpan              Duration  { get; init; }

    /// <summary>Erros estruturados extraídos do output (blocos Error: do Terraform).</summary>
    public IReadOnlyList<string> ParsedErrors { get; init; } = [];

    /// <summary>True para Success, PlanHasChanges e NoChanges.</summary>
    public bool IsSuccess =>
        Status is TerraformResultStatus.Success
               or TerraformResultStatus.PlanHasChanges
               or TerraformResultStatus.NoChanges;

    /// <summary>Output completo para exibição: stdout + stderr separados por marcador.</summary>
    public string FullOutput =>
        string.IsNullOrWhiteSpace(Stderr)
            ? Stdout
            : string.IsNullOrWhiteSpace(Stdout)
                ? Stderr
                : $"{Stdout}\n─── stderr ───\n{Stderr}";

    // ── Factories ─────────────────────────────────────────────────────────

    internal static TerraformResult NotFound() => new()
    {
        Status           = TerraformResultStatus.TerraformNotFound,
        ExitCode         = -1,
        DiagnosticMessage =
            "'terraform' não foi encontrado no PATH. Instale o Terraform CLI e adicione-o ao PATH do sistema.",
    };

    internal static TerraformResult Cancelled() => new()
    {
        Status            = TerraformResultStatus.Cancelled,
        ExitCode          = -1,
        DiagnosticMessage = "Operação cancelada.",
    };

    internal static TerraformResult Timeout(TimeSpan elapsed) => new()
    {
        Status            = TerraformResultStatus.TimedOut,
        ExitCode          = -1,
        Duration          = elapsed,
        DiagnosticMessage = $"Timeout após {elapsed.TotalSeconds:0}s.",
    };
}
