namespace Atlas.Models;

public sealed class GuardDutyFindingModel
{
    public required string  Id           { get; init; }
    public required string  Title        { get; init; }
    public required string  Description  { get; init; }
    public required double  Severity     { get; init; }
    public required string  Type         { get; init; }
    public required string  ResourceType { get; init; }
    public required string  Region       { get; init; }
    public required string  AccountId    { get; init; }
    public required DateTime UpdatedAt   { get; init; }

    public string SeverityLabel => Severity >= 7.0 ? "HIGH" : Severity >= 4.0 ? "MEDIUM" : "LOW";
    public bool   IsHigh        => Severity >= 7.0;
    public bool   IsMedium      => Severity >= 4.0 && Severity < 7.0;
    public bool   IsLow         => Severity < 4.0;
}
