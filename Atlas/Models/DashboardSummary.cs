namespace Atlas.Models;

public class DashboardSummary
{
    public int RunningInstances { get; set; }
    public int StoppedInstances { get; set; }
    public int TotalInstances { get; set; }
    public int S3BucketCount { get; set; }
    public int ActiveAlarms { get; set; }

    // Cost & Usage
    public decimal CurrentMonthCost { get; set; }
    public decimal LastMonthCost { get; set; }
    public decimal ForecastedMonthCost { get; set; }
    public string CostCurrency { get; set; } = "USD";
    public List<DailyCost> DailyCosts { get; set; } = [];
    public List<ServiceCost> ServiceCosts { get; set; } = [];

    // Account identity
    public string AccountId { get; set; } = string.Empty;
    public string AccountAlias { get; set; } = string.Empty;
    public string AccountArn { get; set; } = string.Empty;
    public string Region { get; set; } = string.Empty;

    public DateTime LastRefreshed { get; set; }
}

public class DailyCost
{
    public DateOnly Date { get; set; }
    public decimal Amount { get; set; }
}

public class ServiceCost
{
    public string ServiceName { get; set; } = string.Empty;
    public decimal Amount { get; set; }
    public string Currency { get; set; } = "USD";
}
