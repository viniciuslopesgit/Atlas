namespace Atlas.Services.Terraform.Import;

public sealed class ImportOptions
{
    /// <summary>
    /// Região AWS alvo. Se vazio, usa a região activa da sessão.
    /// </summary>
    public string Region { get; init; } = string.Empty;

    /// <summary>
    /// Tipos de recurso a descobrir.
    /// Por padrão descobre todos os tipos suportados.
    /// </summary>
    public IReadOnlyList<AwsResourceType> ResourceTypes { get; init; } =
        Enum.GetValues<AwsResourceType>().ToList();

    /// <summary>
    /// Filtros de tag aplicados durante a descoberta.
    /// Se vazio, sem filtro (retorna todos os recursos).
    /// Filtros são combinados com AND (todos os filtros têm de coincidir).
    /// </summary>
    public IReadOnlyList<TagFilter> TagFilters { get; init; } = [];

    /// <summary>
    /// Número máximo de recursos a retornar por tipo.
    /// Evita trazer miles de registos num único scan.
    /// </summary>
    public int MaxResourcesPerType { get; init; } = 200;

    /// <summary>
    /// Incluir instâncias EC2 terminadas na descoberta.
    /// Por padrão apenas instâncias activas/paradas são retornadas.
    /// </summary>
    public bool IncludeTerminated { get; init; }

    /// <summary>
    /// Incluir recursos geridos pelo AWS (ex.: roles de serviço, subnets de sistema).
    /// Por padrão são excluídos para evitar poluir o state Terraform.
    /// </summary>
    public bool IncludeAwsManagedResources { get; init; }

    // ── Factories ─────────────────────────────────────────────────────────

    /// <summary>Preset: descobre apenas EC2 e Security Groups.</summary>
    public static ImportOptions ComputeOnly() => new()
    {
        ResourceTypes = [AwsResourceType.Ec2Instance, AwsResourceType.SecurityGroup],
    };

    /// <summary>Preset: descobre apenas recursos S3.</summary>
    public static ImportOptions StorageOnly() => new()
    {
        ResourceTypes = [AwsResourceType.S3Bucket],
    };

    /// <summary>Preset: descobre apenas recursos IAM.</summary>
    public static ImportOptions IamOnly() => new()
    {
        ResourceTypes = [AwsResourceType.IamRole, AwsResourceType.IamUser],
    };

    /// <summary>Preset: descobre apenas recursos de rede (VPC, Subnet, Security Group).</summary>
    public static ImportOptions NetworkOnly() => new()
    {
        ResourceTypes = [AwsResourceType.Vpc, AwsResourceType.Subnet, AwsResourceType.SecurityGroup],
    };

    /// <summary>Preset: filtra por ambiente via tag Environment=<paramref name="environment"/>.</summary>
    public static ImportOptions ForEnvironment(string environment) => new()
    {
        TagFilters = [new TagFilter("Environment", environment)],
    };
}
