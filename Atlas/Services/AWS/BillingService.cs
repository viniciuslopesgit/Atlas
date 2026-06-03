using System.Globalization;
using Amazon.CostExplorer;
using Amazon.CostExplorer.Model;
using Atlas.Infrastructure;
using Atlas.Infrastructure.Logging;
using Atlas.Models;

namespace Atlas.Services.AWS;

public sealed class BillingService : IBillingService
{
    private readonly IAwsSessionFactory _session;
    private readonly AwsClientFactory   _clients;

    public BillingService(IAwsSessionFactory session, AwsClientFactory clients)
    {
        _session = session;
        _clients = clients;
    }

    public async Task<BillingReport> GetCostBreakdownAsync(
        DateOnly          start,
        DateOnly          end,
        string            groupBy = "SERVICE",
        CancellationToken ct      = default)
    {
        try
        {
            var ce = _clients.GetCostExplorer(_session.GetCredentials());

            // Cost Explorer end date is exclusive — add one day so the last month is included
            var ceEnd = end.AddDays(1);

            var resp = await ce.GetCostAndUsageAsync(new GetCostAndUsageRequest
            {
                TimePeriod  = new DateInterval
                {
                    Start = start.ToString("yyyy-MM-dd"),
                    End   = ceEnd.ToString("yyyy-MM-dd")
                },
                Granularity = Granularity.MONTHLY,
                Metrics     = ["BlendedCost"],
                GroupBy     = [new GroupDefinition
                {
                    Type = GroupDefinitionType.DIMENSION,
                    Key  = groupBy
                }]
            }, ct);

            var entries       = new List<MonthlyServiceCost>();
            var monthLabels   = new List<string>();
            var serviceTotals = new Dictionary<string, decimal>(StringComparer.Ordinal);

            foreach (var result in resp.ResultsByTime)
            {
                var period     = DateOnly.Parse(result.TimePeriod.Start, CultureInfo.InvariantCulture);
                var monthLabel = period.ToString("MMM yyyy", CultureInfo.InvariantCulture);
                if (!monthLabels.Contains(monthLabel)) monthLabels.Add(monthLabel);

                foreach (var group in result.Groups)
                {
                    var svc    = string.IsNullOrWhiteSpace(group.Keys[0]) ? "Untagged" : group.Keys[0];
                    var metric = group.Metrics["BlendedCost"];
                    var currency = metric.Unit;
                    if (!decimal.TryParse(metric.Amount, NumberStyles.Any,
                            CultureInfo.InvariantCulture, out var amount)) continue;
                    if (amount < 0.001m) continue;

                    entries.Add(new MonthlyServiceCost(monthLabel, svc, amount, currency));
                    serviceTotals[svc] = serviceTotals.GetValueOrDefault(svc) + amount;
                }
            }

            // Keep top 7 by total; roll everything else into "Others"
            var top7 = serviceTotals
                .OrderByDescending(kv => kv.Value)
                .Take(7)
                .Select(kv => kv.Key)
                .ToHashSet(StringComparer.Ordinal);

            var finalEntries = new List<MonthlyServiceCost>();
            var hasOthers    = false;

            foreach (var month in monthLabels)
            {
                var monthRows = entries.Where(e => e.MonthLabel == month).ToList();
                finalEntries.AddRange(monthRows.Where(e => top7.Contains(e.Service)));

                var othersTotal = monthRows
                    .Where(e => !top7.Contains(e.Service))
                    .Sum(e => e.Amount);
                if (othersTotal > 0.001m)
                {
                    finalEntries.Add(new MonthlyServiceCost(month, "Others", othersTotal, "USD"));
                    hasOthers = true;
                }
            }

            var allServices = serviceTotals
                .OrderByDescending(kv => kv.Value)
                .Take(7)
                .Select(kv => kv.Key)
                .ToList();
            if (hasOthers) allServices.Add("Others");

            return new BillingReport
            {
                MonthLabels = monthLabels,
                TopServices = allServices,
                Entries     = finalEntries,
                GrandTotal  = serviceTotals.Values.Sum(),
                Currency    = "USD"
            };
        }
        catch (Exception ex)
        {
            FileLogger.Error("BillingService.GetCostBreakdownAsync", ex);
            throw;
        }
    }
}
