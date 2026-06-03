namespace Atlas.Models;

/// <summary>Cost for one service/group in one calendar month.</summary>
public record MonthlyServiceCost(
    string MonthLabel,
    string Service,
    decimal Amount,
    string Currency);

/// <summary>Full billing report for the selected period.</summary>
public sealed class BillingReport
{
    public List<string>             MonthLabels { get; init; } = [];
    public List<string>             TopServices { get; init; } = [];
    public List<MonthlyServiceCost> Entries     { get; init; } = [];
    public decimal                  GrandTotal  { get; init; }
    public string                   Currency    { get; init; } = "USD";
}
