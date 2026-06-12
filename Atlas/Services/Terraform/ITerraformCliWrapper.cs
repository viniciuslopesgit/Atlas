namespace Atlas.Services.Terraform;

public interface ITerraformCliWrapper
{
    /// <summary>Timeout global aplicado a cada comando. Padrão: 5 minutos.</summary>
    TimeSpan DefaultTimeout { get; set; }

    /// <summary>
    /// Verifica se o binário terraform está disponível e retorna a versão.
    /// Retorna null se não encontrado.
    /// </summary>
    Task<string?> GetVersionAsync(CancellationToken ct = default);

    /// <summary>terraform init -no-color [-upgrade]</summary>
    Task<TerraformResult> InitAsync(
        string                    workingDir,
        bool                      upgrade     = false,
        TerraformAwsCredentials?  credentials = null,
        IProgress<string>?        progress    = null,
        CancellationToken         ct          = default);

    /// <summary>terraform validate -no-color</summary>
    Task<TerraformResult> ValidateAsync(
        string             workingDir,
        IProgress<string>? progress = null,
        CancellationToken  ct       = default);

    /// <summary>
    /// terraform plan -no-color [-detailed-exitcode] [-out=tfplan]
    /// Exit 0 → NoChanges, Exit 2 → PlanHasChanges, Exit 1 → Failed.
    /// </summary>
    Task<TerraformResult> PlanAsync(
        string                                workingDir,
        bool                                  detailed    = false,
        string?                               planOutFile = null,
        TerraformAwsCredentials?              credentials = null,
        IReadOnlyDictionary<string, string>?  tfVars      = null,
        IProgress<string>?                    progress    = null,
        CancellationToken                     ct          = default);

    /// <summary>
    /// terraform apply -auto-approve -no-color [planFile]
    /// Nunca interativo — usa -auto-approve ou aplica um plan salvo.
    /// </summary>
    Task<TerraformResult> ApplyAsync(
        string                                workingDir,
        string?                               planFile    = null,
        TerraformAwsCredentials?              credentials = null,
        IReadOnlyDictionary<string, string>?  tfVars      = null,
        IProgress<string>?                    progress    = null,
        CancellationToken                     ct          = default);

    /// <summary>terraform import -no-color &lt;resourceAddress&gt; &lt;resourceId&gt;</summary>
    Task<TerraformResult> ImportAsync(
        string                    workingDir,
        string                    resourceAddress,
        string                    resourceId,
        TerraformAwsCredentials?  credentials = null,
        IProgress<string>?        progress    = null,
        CancellationToken         ct          = default);

    /// <summary>
    /// terraform plan -generate-config-out=&lt;path&gt; -no-color
    /// Gera HCL para cada import block existente, escreve em <paramref name="generateConfigOut"/>
    /// e mostra o plano de import. Requer Terraform 1.5+.
    /// </summary>
    Task<TerraformResult> PlanWithGenerateConfigAsync(
        string                                workingDir,
        string                                generateConfigOut,
        TerraformAwsCredentials?              credentials = null,
        IReadOnlyDictionary<string, string>?  tfVars      = null,
        IProgress<string>?                    progress    = null,
        CancellationToken                     ct          = default);

    /// <summary>terraform output -no-color [-json]</summary>
    Task<TerraformResult> OutputAsync(
        string             workingDir,
        bool               json     = false,
        IProgress<string>? progress = null,
        CancellationToken  ct       = default);
}
