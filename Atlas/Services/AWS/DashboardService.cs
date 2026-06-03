using System.Globalization;
using Amazon.CloudWatch;
using Amazon.CloudWatch.Model;
using Amazon.CostExplorer;
using Amazon.CostExplorer.Model;
using Amazon.SecurityToken;
using Amazon.SecurityToken.Model;
using Atlas.Infrastructure;
using Atlas.Infrastructure.Logging;
using Atlas.Models;

namespace Atlas.Services.AWS;

public sealed class DashboardService : IDashboardService
{
    private readonly IAwsSessionFactory _session;
    private readonly IEc2Service _ec2;
    private readonly IS3Service  _s3;
    private readonly AwsClientFactory _clients;

    public DashboardService(
        IAwsSessionFactory session,
        IEc2Service ec2,
        IS3Service s3,
        AwsClientFactory clients)
    {
        _session = session;
        _ec2     = ec2;
        _s3      = s3;
        _clients = clients;
    }

    public async Task<DashboardSummary> GetSummaryAsync(DateOnly month, CancellationToken ct = default)
    {
        var instancesTask = SafeAsync(() => _ec2.GetInstancesAsync(ct), "EC2 instances");
        var bucketsTask   = SafeAsync(() => _s3.GetBucketsAsync(ct),    "S3 buckets");
        var alarmsTask    = SafeAsync(() => GetActiveAlarmsCountAsync(ct),  "CloudWatch alarms");
        var identityTask  = SafeAsync(() => GetCallerIdentityAsync(ct),     "STS identity");
        var costTask      = SafeAsync(() => GetCostDataAsync(month, ct),    "Cost Explorer");

        await Task.WhenAll(instancesTask, bucketsTask, alarmsTask, identityTask, costTask);

        var instances = await instancesTask ?? [];
        var buckets   = await bucketsTask   ?? [];
        var alarms    = await alarmsTask;
        var identity  = await identityTask  ?? new AccountIdentity();
        var costData  = await costTask      ?? new CostData();

        return new DashboardSummary
        {
            RunningInstances    = instances.Count(i => i.State == "running"),
            StoppedInstances    = instances.Count(i => i.State == "stopped"),
            TotalInstances      = instances.Count,
            S3BucketCount       = buckets.Count,
            ActiveAlarms        = alarms,
            CurrentMonthCost    = costData.CurrentMonth,
            LastMonthCost       = costData.LastMonth,
            ForecastedMonthCost = costData.Forecasted,
            CostCurrency        = costData.Currency,
            DailyCosts          = costData.Daily,
            ServiceCosts        = costData.ServiceCosts,
            AccountId           = identity.AccountId ?? "unknown",
            AccountAlias        = identity.Alias ?? string.Empty,
            AccountArn          = identity.Arn ?? string.Empty,
            Region              = identity.Region ?? string.Empty,
            LastRefreshed       = DateTime.UtcNow
        };
    }

    private async Task<CostData> GetCostDataAsync(DateOnly month, CancellationToken ct)
    {
        var ce    = _clients.GetCostExplorer(_session.GetCredentials());
        var today = DateOnly.FromDateTime(DateTime.UtcNow);

        var firstSelectedMonth = new DateOnly(month.Year, month.Month, 1);
        var firstNextMonth     = firstSelectedMonth.AddMonths(1);
        var firstPrevMonth     = firstSelectedMonth.AddMonths(-1);

        bool isCurrentMonth = month.Year == today.Year && month.Month == today.Month;
        var endForCurrent   = isCurrentMonth ? today : firstNextMonth;

        // Current/selected month: daily breakdown
        var currentTask = ce.GetCostAndUsageAsync(new GetCostAndUsageRequest
        {
            TimePeriod  = new DateInterval { Start = firstSelectedMonth.ToString("yyyy-MM-dd"), End = endForCurrent.ToString("yyyy-MM-dd") },
            Granularity = Granularity.DAILY,
            Metrics     = ["BlendedCost"]
        }, ct);

        // Previous month total
        var prevTask = ce.GetCostAndUsageAsync(new GetCostAndUsageRequest
        {
            TimePeriod  = new DateInterval { Start = firstPrevMonth.ToString("yyyy-MM-dd"), End = firstSelectedMonth.ToString("yyyy-MM-dd") },
            Granularity = Granularity.MONTHLY,
            Metrics     = ["BlendedCost"]
        }, ct);

        // Service breakdown for the selected month
        var serviceTask = ce.GetCostAndUsageAsync(new GetCostAndUsageRequest
        {
            TimePeriod  = new DateInterval { Start = firstSelectedMonth.ToString("yyyy-MM-dd"), End = endForCurrent.ToString("yyyy-MM-dd") },
            Granularity = Granularity.MONTHLY,
            Metrics     = ["BlendedCost"],
            GroupBy     = [new GroupDefinition { Type = GroupDefinitionType.DIMENSION, Key = "SERVICE" }]
        }, ct);

        // Forecast to end of month (only for current month, not last day)
        Task<GetCostForecastResponse>? forecastTask = null;
        if (isCurrentMonth && today < firstNextMonth.AddDays(-1))
        {
            forecastTask = ce.GetCostForecastAsync(new GetCostForecastRequest
            {
                TimePeriod  = new DateInterval { Start = today.AddDays(1).ToString("yyyy-MM-dd"), End = firstNextMonth.ToString("yyyy-MM-dd") },
                Metric      = Amazon.CostExplorer.Metric.BLENDED_COST,
                Granularity = Granularity.MONTHLY
            }, ct);
        }

        await Task.WhenAll(currentTask, prevTask, serviceTask);

        var currentResp = await currentTask;
        var prevResp    = await prevTask;
        var serviceResp = await serviceTask;

        var currency     = "USD";
        var daily        = new List<DailyCost>();
        var currentTotal = 0m;

        foreach (var result in currentResp.ResultsByTime)
        {
            if (result.Total.TryGetValue("BlendedCost", out var metric))
            {
                var amount = decimal.Parse(metric.Amount, CultureInfo.InvariantCulture);
                currency      = metric.Unit == "USD" ? "USD" : metric.Unit;
                currentTotal += amount;
                daily.Add(new DailyCost { Date = DateOnly.Parse(result.TimePeriod.Start), Amount = amount });
            }
        }

        var lastMonth = 0m;
        if (prevResp.ResultsByTime.Count > 0 &&
            prevResp.ResultsByTime[0].Total.TryGetValue("BlendedCost", out var lm))
            lastMonth = decimal.Parse(lm.Amount, CultureInfo.InvariantCulture);

        // Service costs
        var serviceCosts = new List<ServiceCost>();
        if (serviceResp.ResultsByTime.Count > 0)
        {
            foreach (var group in serviceResp.ResultsByTime[0].Groups)
            {
                if (group.Metrics.TryGetValue("BlendedCost", out var svc))
                {
                    var amount = decimal.Parse(svc.Amount, CultureInfo.InvariantCulture);
                    if (amount > 0.001m)
                        serviceCosts.Add(new ServiceCost
                        {
                            ServiceName = group.Keys.Count > 0 ? group.Keys[0] : "Other",
                            Amount      = amount,
                            Currency    = currency
                        });
                }
            }
            serviceCosts.Sort((a, b) => b.Amount.CompareTo(a.Amount));
        }

        var forecasted = currentTotal;
        if (forecastTask != null)
        {
            try
            {
                var fResp = await forecastTask;
                if (decimal.TryParse(fResp.Total.Amount,
                        NumberStyles.Any, CultureInfo.InvariantCulture, out var f))
                    forecasted = f;
            }
            catch { /* forecast might fail if not enough data */ }
        }

        return new CostData
        {
            CurrentMonth = currentTotal,
            LastMonth    = lastMonth,
            Forecasted   = isCurrentMonth ? forecasted : currentTotal,
            Currency     = currency,
            Daily        = daily,
            ServiceCosts = serviceCosts
        };
    }

    private async Task<int> GetActiveAlarmsCountAsync(CancellationToken ct)
    {
        var cw = _clients.GetCloudWatch(_session.GetCredentials(), _session.GetRegion());
        var response = await cw.DescribeAlarmsAsync(new DescribeAlarmsRequest
        {
            StateValue = StateValue.ALARM,
            MaxRecords = 100
        }, ct);
        return response.MetricAlarms.Count;
    }

    private async Task<AccountIdentity> GetCallerIdentityAsync(CancellationToken ct)
    {
        var region   = _session.GetRegion();
        var sts      = _clients.GetSts(_session.GetCredentials(), region);
        var identity = await sts.GetCallerIdentityAsync(new GetCallerIdentityRequest(), ct);
        return new AccountIdentity
        {
            AccountId = identity.Account,
            Alias     = string.Empty,
            Arn       = identity.Arn,
            Region    = region
        };
    }

    private static async Task<T?> SafeAsync<T>(Func<Task<T>> action, string context) where T : class
    {
        try { return await action(); }
        catch (OperationCanceledException) { return null; }
        catch (Exception ex)
        {
            FileLogger.Error($"DashboardService: failed to load {context}", ex);
            return null;
        }
    }

    private static async Task<int> SafeAsync(Func<Task<int>> action, string context)
    {
        try { return await action(); }
        catch (OperationCanceledException) { return 0; }
        catch (Exception ex)
        {
            FileLogger.Error($"DashboardService: failed to load {context}", ex);
            return 0;
        }
    }

    private sealed class AccountIdentity
    {
        public string? AccountId { get; set; }
        public string? Alias     { get; set; }
        public string? Arn       { get; set; }
        public string? Region    { get; set; }
    }

    private sealed class CostData
    {
        public decimal CurrentMonth  { get; set; }
        public decimal LastMonth     { get; set; }
        public decimal Forecasted    { get; set; }
        public string  Currency      { get; set; } = "USD";
        public List<DailyCost>   Daily        { get; set; } = [];
        public List<ServiceCost> ServiceCosts { get; set; } = [];
    }
}
