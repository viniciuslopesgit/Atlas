using Atlas.Models;
using Atlas.Services.Terraform.Hcl.Models;
using Atlas.Services.Terraform.Import;

namespace Atlas.Services.Terraform;

public interface ITerraformService
{
    // ── Projecto activo ───────────────────────────────────────────────────

    /// <summary>
    /// Retorna o projecto Terraform actualmente activo (primeiro inicializado,
    /// ou o único configurado). Retorna <c>null</c> se nenhum projecto existir.
    /// </summary>
    TerraformProjectConfig? ActiveProject { get; }

    // ── Geração de HCL ────────────────────────────────────────────────────

    /// <summary>
    /// Gera HCL para um recurso individual e escreve no directório do projecto activo.
    /// O modelo é despachado automaticamente para o template correcto:
    /// <see cref="Ec2InstanceHclModel"/>, <see cref="S3BucketHclModel"/>,
    /// <see cref="SecurityGroupHclModel"/>, <see cref="IamRoleHclModel"/>.
    /// Usa o sistema de markers ATLAS-MANAGED — edições manuais fora dos blocos são preservadas.
    /// </summary>
    Task<TerraformOperationResult> GenerateAndWriteResourceAsync(
        object             model,
        string?            projectId  = null,
        CancellationToken  ct         = default);

    /// <summary>Atalho tipado para EC2 instances.</summary>
    Task<TerraformOperationResult> GenerateEc2ResourceAsync(
        Ec2InstanceHclModel model,
        string?             projectId = null,
        CancellationToken   ct        = default);

    /// <summary>Atalho tipado para S3 buckets.</summary>
    Task<TerraformOperationResult> GenerateS3ResourceAsync(
        S3BucketHclModel  model,
        string?           projectId = null,
        CancellationToken ct        = default);

    // ── Import de infraestrutura existente ───────────────────────────────

    /// <summary>
    /// Descobre recursos AWS de acordo com <paramref name="options"/> e:
    /// <list type="number">
    ///   <item>Escreve <c>imports.tf</c> com blocos <c>import { }</c> Terraform 1.5+.</item>
    ///   <item>Opcionalmente gera HCL sugerido para cada recurso descoberto.</item>
    /// </list>
    /// </summary>
    Task<TerraformOperationResult> ImportExistingResourcesAsync(
        ImportOptions      options,
        bool               generateHcl = true,
        IProgress<string>? progress    = null,
        CancellationToken  ct          = default);

    /// <summary>
    /// Sincronização completa com o AWS:
    /// descobre todos os tipos de recurso na região activa,
    /// gera <c>imports.tf</c> e todos os ficheiros HCL no projecto activo,
    /// e executa <c>terraform validate</c> para verificar a consistência.
    /// </summary>
    Task<TerraformOperationResult> SyncWithAwsAsync(
        IProgress<string>? progress = null,
        CancellationToken  ct       = default);

    // ── Comandos Terraform CLI ────────────────────────────────────────────

    /// <summary>
    /// Inicializa o projecto activo (<c>terraform init</c>) se ainda não estiver inicializado.
    /// </summary>
    Task<TerraformOperationResult> EnsureInitializedAsync(
        CancellationToken ct = default);

    /// <summary>
    /// Executa <c>terraform plan -detailed-exitcode</c> no projecto activo.
    /// Injeta as credenciais AWS da conta activa como variáveis de ambiente temporárias.
    /// </summary>
    Task<TerraformOperationResult> RunPlanAsync(
        IProgress<string>? progress = null,
        CancellationToken  ct       = default);

    /// <summary>
    /// Executa <c>terraform apply -auto-approve</c> no projecto activo.
    /// ⚠️ Operação destrutiva — modifica infra-estrutura real.
    /// </summary>
    Task<TerraformOperationResult> ApplyChangesAsync(
        IProgress<string>? progress = null,
        CancellationToken  ct       = default);
}
