using Atlas.Services.Terraform.Hcl;
using Atlas.Services.Terraform.Hcl.Models;

namespace Atlas.Services.Terraform.Import;

/// <summary>Grau de confiança na sugestão de nome Terraform para o recurso.</summary>
public enum ImportConfidence
{
    /// <summary>Nome explícito (tag Name) encontrado + tipo de recurso bem suportado.</summary>
    High,
    /// <summary>Sem tag Name mas recurso identificável por ID ou nome interno.</summary>
    Medium,
    /// <summary>Recurso ambíguo ou com informação insuficiente para nomear com segurança.</summary>
    Low,
}

/// <summary>
/// Um recurso AWS descoberto durante a análise de infraestrutura existente,
/// com toda a informação necessária para gerar blocos de import Terraform e HCL sugerido.
/// </summary>
public sealed class DiscoveredResource
{
    // ── Identificação AWS ─────────────────────────────────────────────────

    /// <summary>Tipo de recurso AWS.</summary>
    public AwsResourceType ResourceType { get; init; }

    /// <summary>ID único no AWS (ex.: <c>i-0abc123456</c>, <c>sg-0def456789</c>).</summary>
    public string AwsId { get; init; } = string.Empty;

    /// <summary>Nome legível do recurso, geralmente valor da tag <c>Name</c>.</summary>
    public string ResourceName { get; init; } = string.Empty;

    /// <summary>Região AWS onde o recurso vive.</summary>
    public string Region { get; init; } = string.Empty;

    /// <summary>Tags AWS do recurso.</summary>
    public IReadOnlyDictionary<string, string> Tags { get; init; } =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    // ── Terraform ─────────────────────────────────────────────────────────

    /// <summary>Tipo de recurso Terraform (ex.: <c>aws_instance</c>).</summary>
    public string TerraformType { get; init; } = string.Empty;

    /// <summary>Nome sugerido para o recurso Terraform (snake_case válido).</summary>
    public string SuggestedTfName { get; init; } = string.Empty;

    /// <summary>
    /// Endereço completo do recurso Terraform (ex.: <c>aws_instance.web_server</c>).
    /// </summary>
    public string ResourceAddress => $"{TerraformType}.{SuggestedTfName}";

    /// <summary>
    /// ID usado no <c>terraform import</c> ou no bloco <c>import { id = ... }</c>.
    /// Pode diferir do <see cref="AwsId"/> (ex.: S3 usa o nome do bucket, não um ID).
    /// </summary>
    public string ImportId { get; init; } = string.Empty;

    // ── Qualidade da sugestão ─────────────────────────────────────────────

    /// <summary>Grau de confiança no nome Terraform sugerido.</summary>
    public ImportConfidence Confidence { get; init; } = ImportConfidence.Medium;

    /// <summary>
    /// Notas e avisos sobre este recurso (ex.: recurso com estado incomum,
    /// campos que requerem atenção manual no HCL gerado).
    /// </summary>
    public IReadOnlyList<string> Notes { get; init; } = [];

    // ── Modelos internos ──────────────────────────────────────────────────

    /// <summary>
    /// Modelo HCL pré-construído (ex.: <see cref="Ec2InstanceHclModel"/>).
    /// Usado por <c>SuggestHclFromExistingResourcesAsync</c> sem necessidade
    /// de re-mapear os dados AWS.
    /// </summary>
    public object? HclModel { get; init; }
}

/// <summary>Associa um recurso descoberto ao HCL Terraform sugerido para ele.</summary>
public sealed class HclSuggestion
{
    public DiscoveredResource                        Resource  { get; init; } = null!;
    public HclGenerationResult HclResult { get; init; } = null!;
}
