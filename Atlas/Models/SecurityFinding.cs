namespace Atlas.Models;

public enum FindingSeverity { Ok, Warning, Critical }

public sealed class SecurityFinding
{
    public required string Title         { get; init; }
    public required string Description   { get; init; }
    public FindingSeverity Severity       { get; init; }
    public int?            AffectedCount { get; init; }

    public string SeverityIcon => Severity switch
    {
        FindingSeverity.Critical => "",
        FindingSeverity.Warning  => "",
        _                        => ""
    };
}

public sealed class SecurityAuditResult
{
    public List<SecurityFinding> Findings    { get; init; } = [];
    public DateTime              AuditedAt   { get; init; } = DateTime.UtcNow;
    public string?               ErrorMessage { get; init; }

    public int CriticalCount => Findings.Count(f => f.Severity == FindingSeverity.Critical);
    public int WarningCount  => Findings.Count(f => f.Severity == FindingSeverity.Warning);
    public int OkCount       => Findings.Count(f => f.Severity == FindingSeverity.Ok);

    public FindingSeverity OverallSeverity =>
        CriticalCount > 0 ? FindingSeverity.Critical :
        WarningCount  > 0 ? FindingSeverity.Warning  :
                            FindingSeverity.Ok;

    public string SummaryText => ErrorMessage != null
        ? $"Audit error: {ErrorMessage}"
        : $"{CriticalCount} critical · {WarningCount} warnings · {OkCount} OK";
}
