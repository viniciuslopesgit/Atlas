namespace Atlas.Services.Terraform.Import;

/// <summary>Tipos de recursos AWS suportados para descoberta e importação Terraform.</summary>
public enum AwsResourceType
{
    // ── Compute ────────────────────────────────────────────────────────────
    Ec2Instance,
    AutoScalingGroup,
    LaunchTemplate,

    // ── Networking ─────────────────────────────────────────────────────────
    Vpc,
    Subnet,
    SecurityGroup,
    RouteTable,
    InternetGateway,
    NatGateway,
    LoadBalancer,       // ALB / NLB (ELBv2)
    TargetGroup,

    // ── Storage ────────────────────────────────────────────────────────────
    S3Bucket,

    // ── Database ───────────────────────────────────────────────────────────
    RdsInstance,
    RdsCluster,
    DynamoDbTable,
    ElastiCacheCluster,

    // ── Serverless ─────────────────────────────────────────────────────────
    LambdaFunction,
    ApiGatewayRestApi,

    // ── Containers ─────────────────────────────────────────────────────────
    EcsCluster,
    EcsService,
    EcrRepository,
    EksCluster,

    // ── Messaging ──────────────────────────────────────────────────────────
    SqsQueue,
    SnsTopic,

    // ── IAM ────────────────────────────────────────────────────────────────
    IamRole,
    IamUser,
    IamGroup,
    IamPolicy,          // customer-managed policies only

    // ── Security ───────────────────────────────────────────────────────────
    KmsKey,
    SecretsManagerSecret,
    AcmCertificate,

    // ── DNS / CDN ──────────────────────────────────────────────────────────
    Route53HostedZone,

    // ── Monitoring ─────────────────────────────────────────────────────────
    CloudWatchLogGroup,
    CloudWatchAlarm,
}

/// <summary>Filtro por tag AWS aplicado durante a descoberta.</summary>
/// <param name="Key">Chave da tag (obrigatório).</param>
/// <param name="Value">Valor da tag. Se <c>null</c>, aceita qualquer valor para esta chave.</param>
public sealed record TagFilter(string Key, string? Value = null);
