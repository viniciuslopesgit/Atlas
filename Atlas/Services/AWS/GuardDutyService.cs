using Amazon.GuardDuty;
using Amazon.GuardDuty.Model;
using Atlas.Infrastructure;
using Atlas.Infrastructure.Logging;
using Atlas.Models;

namespace Atlas.Services.AWS;

public sealed class GuardDutyService : IGuardDutyService
{
    private readonly IAwsSessionFactory _session;
    private readonly AwsClientFactory   _clients;

    public GuardDutyService(IAwsSessionFactory session, AwsClientFactory clients)
    {
        _session = session;
        _clients = clients;
    }

    public async Task<IReadOnlyList<GuardDutyFindingModel>> GetFindingsAsync(CancellationToken ct = default)
    {
        try
        {
            var gd     = _clients.GetGuardDuty(_session.GetCredentials(), _session.GetRegion());
            var region = _session.GetRegion();

            // Each account has at most one detector per region
            var detectorsResp = await gd.ListDetectorsAsync(new ListDetectorsRequest(), ct);
            if (detectorsResp.DetectorIds.Count == 0)
                return [];

            var detectorId = detectorsResp.DetectorIds[0];

            // Page through finding IDs
            var findingIds = new List<string>();
            string? nextToken = null;
            do
            {
                var listResp = await gd.ListFindingsAsync(new ListFindingsRequest
                {
                    DetectorId = detectorId,
                    NextToken   = nextToken,
                    MaxResults  = 50,
                    FindingCriteria = new FindingCriteria
                    {
                        Criterion = new Dictionary<string, Condition>
                        {
                            // Only active findings (not archived)
                            ["service.archived"] = new Condition { Equals = ["false"] }
                        }
                    },
                    SortCriteria = new SortCriteria
                    {
                        AttributeName = "severity",
                        OrderBy       = OrderBy.DESC
                    }
                }, ct);

                findingIds.AddRange(listResp.FindingIds);
                nextToken = listResp.NextToken;
            }
            while (!string.IsNullOrEmpty(nextToken));

            if (findingIds.Count == 0)
                return [];

            // GetFindings accepts at most 50 IDs per call
            var findings = new List<GuardDutyFindingModel>();
            foreach (var batch in Chunk(findingIds, 50))
            {
                var getResp = await gd.GetFindingsAsync(new GetFindingsRequest
                {
                    DetectorId = detectorId,
                    FindingIds  = [.. batch]
                }, ct);

                foreach (var f in getResp.Findings)
                {
                    findings.Add(new GuardDutyFindingModel
                    {
                        Id           = f.Id,
                        Title        = f.Title,
                        Description  = f.Description,
                        Severity     = f.Severity,
                        Type         = f.Type,
                        ResourceType = f.Resource?.ResourceType ?? "Unknown",
                        Region       = region,
                        AccountId    = f.AccountId,
                        UpdatedAt    = DateTime.TryParse(f.UpdatedAt, out var dt) ? dt.ToUniversalTime() : DateTime.UtcNow,
                    });
                }
            }

            return findings
                .OrderByDescending(f => f.Severity)
                .ThenBy(f => f.Title)
                .ToList();
        }
        catch (Exception ex)
        {
            FileLogger.Error("GuardDutyService.GetFindingsAsync", ex);
            throw;
        }
    }

    private static IEnumerable<IEnumerable<T>> Chunk<T>(IList<T> source, int size)
    {
        for (int i = 0; i < source.Count; i += size)
            yield return source.Skip(i).Take(size);
    }
}
