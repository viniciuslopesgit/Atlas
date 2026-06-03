using Atlas.Infrastructure.Logging;
using Atlas.Models;

namespace Atlas.Services.AWS;

public sealed class SearchService : ISearchService
{
    private readonly IEc2Service _ec2;
    private readonly IS3Service  _s3;

    // Segoe MDL2 Assets code points
    private const string IconEC2    = ""; // ServerEnvironment
    private const string IconBucket = ""; // Library/Storage

    public SearchService(IEc2Service ec2, IS3Service s3)
    {
        _ec2 = ec2;
        _s3  = s3;
    }

    public async Task<IReadOnlyList<SearchResult>> SearchAsync(string query, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(query))
            return [];

        var q = query.Trim();

        var instancesTask = SafeAsync(() => _ec2.GetInstancesAsync(ct), "EC2 search");
        var bucketsTask   = SafeAsync(() => _s3.GetBucketsAsync(ct),    "S3 search");

        await Task.WhenAll(instancesTask, bucketsTask);

        var instances = await instancesTask ?? [];
        var buckets   = await bucketsTask   ?? [];

        var results = new List<SearchResult>();

        foreach (var i in instances)
        {
            if (Matches(q, i.Name, i.InstanceId, i.PublicIpAddress, i.PrivateIpAddress,
                           i.Region, i.InstanceType, i.State, i.VpcId, i.ImageId))
            {
                results.Add(new SearchResult
                {
                    ResourceType = SearchResultType.EC2Instance,
                    Name       = string.IsNullOrEmpty(i.Name) ? i.InstanceId : i.Name,
                    Id         = i.InstanceId,
                    Region     = i.Region,
                    State      = i.State,
                    TypeLabel  = "EC2 Instance",
                    Icon       = IconEC2
                });
            }
        }

        foreach (var b in buckets)
        {
            if (Matches(q, b.Name, b.Region))
            {
                results.Add(new SearchResult
                {
                    ResourceType = SearchResultType.S3Bucket,
                    Name      = b.Name,
                    Id        = b.Name,
                    Region    = b.Region,
                    State     = "active",
                    TypeLabel = "S3 Bucket",
                    Icon      = IconBucket
                });
            }
        }

        return results;
    }

    private static bool Matches(string query, params string[] fields) =>
        fields.Any(f => f?.Contains(query, StringComparison.OrdinalIgnoreCase) == true);

    private static async Task<T?> SafeAsync<T>(Func<Task<T>> action, string context) where T : class
    {
        try { return await action(); }
        catch (OperationCanceledException) { return null; }
        catch (Exception ex)
        {
            FileLogger.Error($"SearchService: failed to load {context}", ex);
            return null;
        }
    }
}
