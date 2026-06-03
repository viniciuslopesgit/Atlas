using Amazon;
using Amazon.CloudWatch;
using Amazon.CostExplorer;
using Amazon.EC2;
using Amazon.GuardDuty;
using Amazon.IdentityManagement;
using Amazon.Runtime;
using Amazon.S3;
using Amazon.SecurityToken;
using Amazon.SimpleSystemsManagement;
using System.Collections.Concurrent;
using System.Threading;

namespace Atlas.Infrastructure;

/// <summary>
/// Caches and reuses AWS SDK clients per (accessKeyId, region).
/// The AWS SDK uses an internal HttpClient pool — creating a new client per call
/// bypasses that pool and opens new TCP connections every time.
/// Clients here are disposed and evicted when the active account changes.
/// </summary>
public sealed class AwsClientFactory : IDisposable
{
    // Lazy<T> ensures the factory is called exactly once per key even under concurrent access,
    // preventing extra unmanaged AWS clients from being created and abandoned.
    private readonly ConcurrentDictionary<string, Lazy<IDisposable>> _cache = new();

    public AmazonEC2Client GetEc2(AWSCredentials creds, string region) =>
        (AmazonEC2Client)GetOrCreate($"ec2:{region}:{CacheKey(creds)}",
            () => new AmazonEC2Client(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonS3Client GetS3(AWSCredentials creds, string region) =>
        (AmazonS3Client)GetOrCreate($"s3:{region}:{CacheKey(creds)}",
            () => new AmazonS3Client(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonCloudWatchClient GetCloudWatch(AWSCredentials creds, string region) =>
        (AmazonCloudWatchClient)GetOrCreate($"cw:{region}:{CacheKey(creds)}",
            () => new AmazonCloudWatchClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonSecurityTokenServiceClient GetSts(AWSCredentials creds, string region) =>
        (AmazonSecurityTokenServiceClient)GetOrCreate($"sts:{region}:{CacheKey(creds)}",
            () => new AmazonSecurityTokenServiceClient(creds, RegionEndpoint.GetBySystemName(region)));

    // IAM is global — no region needed
    public AmazonIdentityManagementServiceClient GetIam(AWSCredentials creds) =>
        (AmazonIdentityManagementServiceClient)GetOrCreate($"iam:global:{CacheKey(creds)}",
            () => new AmazonIdentityManagementServiceClient(creds, RegionEndpoint.USEast1));

    public AmazonSimpleSystemsManagementClient GetSsm(AWSCredentials creds, string region) =>
        (AmazonSimpleSystemsManagementClient)GetOrCreate($"ssm:{region}:{CacheKey(creds)}",
            () => new AmazonSimpleSystemsManagementClient(creds, RegionEndpoint.GetBySystemName(region)));

    public AmazonGuardDutyClient GetGuardDuty(AWSCredentials creds, string region) =>
        (AmazonGuardDutyClient)GetOrCreate($"gd:{region}:{CacheKey(creds)}",
            () => new AmazonGuardDutyClient(creds, RegionEndpoint.GetBySystemName(region)));

    // Cost Explorer always uses us-east-1 regardless of the active region
    public AmazonCostExplorerClient GetCostExplorer(AWSCredentials creds) =>
        (AmazonCostExplorerClient)GetOrCreate($"ce:us-east-1:{CacheKey(creds)}",
            () => new AmazonCostExplorerClient(creds, RegionEndpoint.USEast1));

    /// <summary>Call when the active account changes to force fresh clients.</summary>
    public void InvalidateAll()
    {
        foreach (var key in _cache.Keys.ToList())
        {
            if (_cache.TryRemove(key, out var lazy) && lazy.IsValueCreated)
                lazy.Value.Dispose();
        }
    }

    private IDisposable GetOrCreate(string key, Func<IDisposable> factory)
    {
        var lazy = _cache.GetOrAdd(key, _ => new Lazy<IDisposable>(factory, LazyThreadSafetyMode.ExecutionAndPublication));
        return lazy.Value;
    }

    private static string CacheKey(AWSCredentials creds)
    {
        try { return creds.GetCredentials().AccessKey; }
        catch { return "unknown"; }
    }

    public void Dispose() => InvalidateAll();
}
