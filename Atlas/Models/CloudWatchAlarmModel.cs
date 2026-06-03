namespace Atlas.Models;

public sealed class CloudWatchAlarmModel
{
    public required string   Name        { get; init; }
    public required string   State       { get; init; }  // OK, ALARM, INSUFFICIENT_DATA
    public required string   MetricName  { get; init; }
    public required string   Namespace   { get; init; }
    public required string   Description { get; init; }
    public required DateTime UpdatedAt   { get; init; }
    public          string   AlarmArn    { get; init; } = string.Empty;

    public bool IsAlarm             => State == "ALARM";
    public bool IsOk                => State == "OK";
    public bool IsInsufficientData  => State == "INSUFFICIENT_DATA";
}
