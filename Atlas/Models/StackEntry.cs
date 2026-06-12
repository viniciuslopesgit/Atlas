using System.Text.Json.Serialization;

namespace Atlas.Models;

public enum StackStatus    { Ready, Queued, Running, Finished, Failed }
public enum StackRunType   { Import, Init, Fix, Plan, Apply, FixDrift }
public enum StackRunStatus { Running, Success, Failed, Cancelled }
public enum DriftInterval  { Off, Hourly, Daily, Weekly }
public enum DriftStatus    { Unknown, Checking, Clean, Drifted, Error }

public class StackEntry
{
    public string      Id          { get; set; } = Guid.NewGuid().ToString();
    public string      Name        { get; set; } = string.Empty;
    public string      ProjectPath { get; set; } = string.Empty;
    public StackStatus Status      { get; set; } = StackStatus.Ready;
    public DateTime    CreatedAt   { get; set; } = DateTime.UtcNow;
    public List<StackRun>    Runs    { get; set; } = [];
    public List<StackEnvVar> EnvVars { get; set; } = [];

    public DriftInterval  DriftInterval         { get; set; } = DriftInterval.Off;
    public DriftStatus    DriftStatus           { get; set; } = DriftStatus.Unknown;
    public string?        DriftSummary          { get; set; }
    public DateTime?      LastDriftCheckAt      { get; set; }
    public bool           DriftAcknowledged     { get; set; } = false;
    public string?        DriftPlanOutput       { get; set; }
    public bool           AutoFixOnDrift        { get; set; } = false;
    public List<string>   DriftCronExpressions  { get; set; } = [];
}

public class StackRun
{
    public string         Id           { get; set; } = Guid.NewGuid().ToString();
    public string         StackId      { get; set; } = string.Empty;
    public StackRunType   Type         { get; set; }
    public StackRunStatus Status       { get; set; } = StackRunStatus.Running;
    public string?        TriggerLabel { get; set; }
    public DateTime       StartedAt    { get; set; } = DateTime.UtcNow;
    public DateTime?      CompletedAt  { get; set; }

    // Plain text in memory only — never written to stacks.json.
    [JsonIgnore]
    public string Output { get; set; } = string.Empty;

    // DPAPI-encrypted representation of Output written to stacks.json.
    // StackRepository encrypts on Save() and decrypts on Load().
    public string EncryptedOutput { get; set; } = string.Empty;

    public TimeSpan? Duration => CompletedAt.HasValue ? CompletedAt.Value - StartedAt : null;

    public string DurationText =>
        Duration is { } d
            ? d.TotalMinutes >= 1 ? $"{(int)d.TotalMinutes}m {d.Seconds}s" : $"{d.Seconds}s"
            : "running…";
}
