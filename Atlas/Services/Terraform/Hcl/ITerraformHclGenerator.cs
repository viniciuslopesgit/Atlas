using Atlas.Services.Terraform.Hcl.Models;

namespace Atlas.Services.Terraform.Hcl;

public interface ITerraformHclGenerator
{
    /// <summary>Nomes de todas as templates embutidas disponíveis (sem extensão .tf.tpl).</summary>
    IReadOnlyList<string> AvailableTemplates { get; }

    // ── Método genérico ───────────────────────────────────────────────────

    /// <summary>
    /// Renderiza qualquer template Scriban com o modelo fornecido.
    /// Se <see cref="HclGenerationRequest.OutputPath"/> não for nulo, funde com o ficheiro existente.
    /// </summary>
    Task<HclGenerationResult> GenerateAsync(
        HclGenerationRequest request,
        CancellationToken    ct = default);

    // ── Métodos tipados de conveniência ───────────────────────────────────

    /// <summary>Gera um recurso <c>aws_instance</c>.</summary>
    Task<HclGenerationResult> GenerateEc2InstanceAsync(
        Ec2InstanceHclModel model,
        string?             outputPath = null,
        CancellationToken   ct         = default);

    /// <summary>Gera recursos de S3 bucket (bucket + public access block + versioning + SSE).</summary>
    Task<HclGenerationResult> GenerateS3BucketAsync(
        S3BucketHclModel  model,
        string?           outputPath = null,
        CancellationToken ct         = default);

    /// <summary>Gera um recurso <c>aws_security_group</c>.</summary>
    Task<HclGenerationResult> GenerateSecurityGroupAsync(
        SecurityGroupHclModel model,
        string?               outputPath = null,
        CancellationToken     ct         = default);

    /// <summary>Gera um recurso <c>aws_iam_role</c> com políticas opcionais.</summary>
    Task<HclGenerationResult> GenerateIamRoleAsync(
        IamRoleHclModel   model,
        string?           outputPath = null,
        CancellationToken ct         = default);

    // ── Módulos Terraform ─────────────────────────────────────────────────

    /// <summary>
    /// Gera todos os ficheiros de um módulo Terraform (main.tf, variables.tf, outputs.tf)
    /// para o directório <paramref name="outputDir"/>.
    /// </summary>
    /// <param name="moduleName">Nome da pasta de módulo: <c>"ec2"</c> ou <c>"s3"</c>.</param>
    /// <param name="model">Modelo partilhado passado a todos os templates do módulo.</param>
    /// <param name="outputDir">Directório de destino dos ficheiros gerados.</param>
    Task<IReadOnlyList<HclGenerationResult>> GenerateModuleAsync(
        string            moduleName,
        object            model,
        string            outputDir,
        CancellationToken ct = default);
}
