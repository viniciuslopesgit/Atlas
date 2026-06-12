namespace Atlas.Services.Terraform.Hcl.Models;

public sealed class HclGenerationRequest
{
    /// <summary>
    /// Nome do template sem extensão, relativo à pasta Templates/Terraform/.
    /// Exemplos: <c>"ec2_instance"</c>, <c>"s3_bucket"</c>, <c>"modules/ec2/main"</c>.
    /// </summary>
    public string TemplateName { get; init; } = string.Empty;

    /// <summary>Objecto de modelo passado ao Scriban — as propriedades mapeiam para variáveis snake_case.</summary>
    public object Model { get; init; } = new();

    /// <summary>
    /// Caminho do ficheiro de saída (absoluto ou relativo ao directório de trabalho).
    /// Se <c>null</c>, o conteúdo gerado é apenas retornado sem ser escrito.
    /// </summary>
    public string? OutputPath { get; init; }

    /// <summary>
    /// Quando <c>false</c> e o ficheiro já contém o bloco ATLAS-MANAGED com a mesma chave,
    /// esse bloco NÃO é regenerado (preserva edições manuais dentro do bloco).
    /// Padrão: <c>true</c> (regenera sempre os blocos geridos).
    /// </summary>
    public bool OverwriteManaged { get; init; } = true;
}
