using Atlas.Services.Terraform.Hcl;

namespace Atlas.Services.Terraform.Import;

public interface IImportService
{
    /// <summary>
    /// Descobre recursos AWS existentes de acordo com as <paramref name="options"/> fornecidas.
    /// Os tipos são descobertos em paralelo; erros por tipo são isolados e reportados em
    /// <see cref="ImportAnalysisResult.PartialErrors"/> sem interromper o resto.
    /// </summary>
    Task<ImportAnalysisResult> DiscoverResourcesAsync(
        ImportOptions      options,
        IProgress<string>? progress = null,
        CancellationToken  ct       = default);

    /// <summary>
    /// Gera blocos <c>import { }</c> Terraform 1.5+ para uma lista de recursos descobertos.
    /// Cada bloco é envolvido em marcas ATLAS-MANAGED para suporte ao merge engine da Parte 3.
    /// Inclui também o comando CLI <c>terraform import</c> equivalente como comentário.
    /// </summary>
    Task<string> GenerateImportBlocksAsync(
        IReadOnlyList<DiscoveredResource> resources,
        CancellationToken                 ct = default);

    /// <summary>
    /// Garante que o bucket S3 de estado remoto do Terraform existe e está configurado
    /// (versioning, bloqueio de acesso público). Retorna o nome do bucket.
    /// O nome inclui o ID da conta AWS para garantir unicidade global.
    /// </summary>
    Task<string> EnsureStateBucketAsync(
        string             region,
        IProgress<string>? progress = null,
        CancellationToken  ct       = default);

    /// <summary>
    /// Para cada recurso descoberto, gera o HCL Terraform sugerido usando os templates da Parte 3.
    /// <para>
    /// Se <paramref name="outputDir"/> não for nulo, escreve os ficheiros <c>.tf</c> nesse directório
    /// usando o sistema de merge (preserva conteúdo existente fora das marcas ATLAS-MANAGED).
    /// </para>
    /// </summary>
    Task<IReadOnlyList<HclSuggestion>> SuggestHclFromExistingResourcesAsync(
        IReadOnlyList<DiscoveredResource> resources,
        string?                           outputDir = null,
        CancellationToken                 ct        = default);
}
