using Amazon;
using Amazon.APIGateway;
using Amazon.AutoScaling;
using Amazon.CertificateManager;
using Amazon.CloudWatch;
using Amazon.CloudWatchLogs;
using Amazon.CostExplorer;
using Amazon.DynamoDBv2;
using Amazon.EC2;
using Amazon.ECR;
using Amazon.ECS;
using Amazon.EKS;
using Amazon.ElastiCache;
using Amazon.ElasticLoadBalancingV2;
using Amazon.GuardDuty;
using Amazon.IdentityManagement;
using Amazon.KeyManagementService;
using Amazon.Lambda;
using Amazon.RDS;
using Amazon.Route53;
using Amazon.Runtime;
using Amazon.S3;
using Amazon.SecretsManager;
using Amazon.SecurityToken;
using Amazon.SimpleNotificationService;
using Amazon.SimpleSystemsManagement;
using Amazon.SQS;
using System.Collections.Concurrent;
using System.Threading;

namespace Atlas.Infrastructure;

/// <summary>
/// Caches and reuses AWS SDK clients per (accessKeyId, region).
/// </summary>
public sealed class AwsClientFactory : IDisposable
{
    private readonly ConcurrentDictionary<string, Lazy<IDisposable>> _cache = new();

    // ── Compute ───────────────────────────────────────────────────────────

    public AmazonEC2Client GetEc2(AWSCredentials creds, string region) =>
        Get<AmazonEC2Client>($"ec2:{region}", creds,
            () => new AmazonEC2Client(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonAutoScalingClient GetAutoScaling(AWSCredentials creds, string region) =>
        Get<AmazonAutoScalingClient>($"asg:{region}", creds,
            () => new AmazonAutoScalingClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonLambdaClient GetLambda(AWSCredentials creds, string region) =>
        Get<AmazonLambdaClient>($"lambda:{region}", creds,
            () => new AmazonLambdaClient(creds, RegionEndpoint.GetBySystemName(region)));

    // ── Containers ────────────────────────────────────────────────────────

    public AmazonECSClient GetEcs(AWSCredentials creds, string region) =>
        Get<AmazonECSClient>($"ecs:{region}", creds,
            () => new AmazonECSClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonECRClient GetEcr(AWSCredentials creds, string region) =>
        Get<AmazonECRClient>($"ecr:{region}", creds,
            () => new AmazonECRClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonEKSClient GetEks(AWSCredentials creds, string region) =>
        Get<AmazonEKSClient>($"eks:{region}", creds,
            () => new AmazonEKSClient(creds, RegionEndpoint.GetBySystemName(region)));

    // ── Storage ───────────────────────────────────────────────────────────

    public AmazonS3Client GetS3(AWSCredentials creds, string region) =>
        Get<AmazonS3Client>($"s3:{region}", creds,
            () => new AmazonS3Client(creds, RegionEndpoint.GetBySystemName(region)));

    // ── Database ──────────────────────────────────────────────────────────

    public AmazonRDSClient GetRds(AWSCredentials creds, string region) =>
        Get<AmazonRDSClient>($"rds:{region}", creds,
            () => new AmazonRDSClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonDynamoDBClient GetDynamoDb(AWSCredentials creds, string region) =>
        Get<AmazonDynamoDBClient>($"dynamo:{region}", creds,
            () => new AmazonDynamoDBClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonElastiCacheClient GetElastiCache(AWSCredentials creds, string region) =>
        Get<AmazonElastiCacheClient>($"elasticache:{region}", creds,
            () => new AmazonElastiCacheClient(creds, RegionEndpoint.GetBySystemName(region)));

    // ── Networking ────────────────────────────────────────────────────────

    public AmazonElasticLoadBalancingV2Client GetElbV2(AWSCredentials creds, string region) =>
        Get<AmazonElasticLoadBalancingV2Client>($"elbv2:{region}", creds,
            () => new AmazonElasticLoadBalancingV2Client(creds, RegionEndpoint.GetBySystemName(region)));

    // Route53 is global
    public AmazonRoute53Client GetRoute53(AWSCredentials creds) =>
        Get<AmazonRoute53Client>("route53:global", creds,
            () => new AmazonRoute53Client(creds, RegionEndpoint.USEast1));

    // ── Messaging ─────────────────────────────────────────────────────────

    public AmazonSQSClient GetSqs(AWSCredentials creds, string region) =>
        Get<AmazonSQSClient>($"sqs:{region}", creds,
            () => new AmazonSQSClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonSimpleNotificationServiceClient GetSns(AWSCredentials creds, string region) =>
        Get<AmazonSimpleNotificationServiceClient>($"sns:{region}", creds,
            () => new AmazonSimpleNotificationServiceClient(creds, RegionEndpoint.GetBySystemName(region)));

    // ── Serverless ────────────────────────────────────────────────────────

    public AmazonAPIGatewayClient GetApiGateway(AWSCredentials creds, string region) =>
        Get<AmazonAPIGatewayClient>($"apigw:{region}", creds,
            () => new AmazonAPIGatewayClient(creds, RegionEndpoint.GetBySystemName(region)));

    // ── Security ──────────────────────────────────────────────────────────

    public AmazonKeyManagementServiceClient GetKms(AWSCredentials creds, string region) =>
        Get<AmazonKeyManagementServiceClient>($"kms:{region}", creds,
            () => new AmazonKeyManagementServiceClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonSecretsManagerClient GetSecretsManager(AWSCredentials creds, string region) =>
        Get<AmazonSecretsManagerClient>($"secrets:{region}", creds,
            () => new AmazonSecretsManagerClient(creds, RegionEndpoint.GetBySystemName(region)));

    // ACM is regional but us-east-1 is used for CloudFront certs
    public AmazonCertificateManagerClient GetAcm(AWSCredentials creds, string region) =>
        Get<AmazonCertificateManagerClient>($"acm:{region}", creds,
            () => new AmazonCertificateManagerClient(creds, RegionEndpoint.GetBySystemName(region)));

    // ── Monitoring ────────────────────────────────────────────────────────

    public AmazonCloudWatchClient GetCloudWatch(AWSCredentials creds, string region) =>
        Get<AmazonCloudWatchClient>($"cw:{region}", creds,
            () => new AmazonCloudWatchClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonCloudWatchLogsClient GetCloudWatchLogs(AWSCredentials creds, string region) =>
        Get<AmazonCloudWatchLogsClient>($"cwlogs:{region}", creds,
            () => new AmazonCloudWatchLogsClient(creds, RegionEndpoint.GetBySystemName(region)));

    // ── IAM + SSM ─────────────────────────────────────────────────────────

    public AmazonIdentityManagementServiceClient GetIam(AWSCredentials creds) =>
        Get<AmazonIdentityManagementServiceClient>("iam:global", creds,
            () => new AmazonIdentityManagementServiceClient(creds, RegionEndpoint.USEast1));

    public AmazonSimpleSystemsManagementClient GetSsm(AWSCredentials creds, string region) =>
        Get<AmazonSimpleSystemsManagementClient>($"ssm:{region}", creds,
            () => new AmazonSimpleSystemsManagementClient(creds, RegionEndpoint.GetBySystemName(region)));

    // ── Other ─────────────────────────────────────────────────────────────

    public AmazonSecurityTokenServiceClient GetSts(AWSCredentials creds, string region) =>
        Get<AmazonSecurityTokenServiceClient>($"sts:{region}", creds,
            () => new AmazonSecurityTokenServiceClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonGuardDutyClient GetGuardDuty(AWSCredentials creds, string region) =>
        Get<AmazonGuardDutyClient>($"gd:{region}", creds,
            () => new AmazonGuardDutyClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonCostExplorerClient GetCostExplorer(AWSCredentials creds) =>
        Get<AmazonCostExplorerClient>("ce:global", creds,
            () => new AmazonCostExplorerClient(creds, RegionEndpoint.USEast1));

    // ── Cache helpers ─────────────────────────────────────────────────────

    public void InvalidateAll()
    {
        foreach (var key in _cache.Keys.ToList())
            if (_cache.TryRemove(key, out var lazy) && lazy.IsValueCreated)
                lazy.Value.Dispose();
    }

    private T Get<T>(string service, AWSCredentials creds, Func<T> factory) where T : IDisposable
    {
        var key  = $"{service}:{CacheKey(creds)}";
        var lazy = _cache.GetOrAdd(key, _ => new Lazy<IDisposable>(() => factory()!, LazyThreadSafetyMode.ExecutionAndPublication));
        return (T)lazy.Value;
    }

    private static string CacheKey(AWSCredentials creds)
    {
        try { return creds.GetCredentials().AccessKey; }
        catch { return "unknown"; }
    }

    public void Dispose() => InvalidateAll();
}
