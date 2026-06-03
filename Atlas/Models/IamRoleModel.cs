namespace Atlas.Models;

public class IamRoleModel
{
    public string RoleName          { get; set; } = string.Empty;
    public string RoleId            { get; set; } = string.Empty;
    public string Arn               { get; set; } = string.Empty;
    public string Path              { get; set; } = string.Empty;
    public string Description       { get; set; } = string.Empty;
    public DateTime CreateDate      { get; set; }
    public int MaxSessionDuration   { get; set; }
    public string TrustedEntities   { get; set; } = string.Empty;
    public List<string> AttachedPolicies { get; set; } = [];
    public List<string> InlinePolicies   { get; set; } = [];

    public string AttachedPoliciesDisplay => AttachedPolicies.Count > 0 ? string.Join(", ", AttachedPolicies) : "—";
    public string MaxSessionDisplay       => $"{MaxSessionDuration / 3600}h {(MaxSessionDuration % 3600) / 60}m";
}
