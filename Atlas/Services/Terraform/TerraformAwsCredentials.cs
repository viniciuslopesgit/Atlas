namespace Atlas.Services.Terraform;

/// <summary>
/// Credenciais AWS passadas ao processo terraform via variáveis de ambiente temporárias.
/// Nunca são gravadas em disco — existem apenas na memória durante a execução do comando.
/// </summary>
public sealed record TerraformAwsCredentials(
    string AccessKeyId,
    string SecretAccessKey,
    string Region,
    string? SessionToken = null);
