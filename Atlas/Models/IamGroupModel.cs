namespace Atlas.Models;

public class IamGroupModel
{
    public string GroupName     { get; set; } = string.Empty;
    public string GroupId       { get; set; } = string.Empty;
    public string Arn           { get; set; } = string.Empty;
    public string Path          { get; set; } = string.Empty;
    public DateTime CreateDate  { get; set; }
    public int UserCount        { get; set; }
    public List<string> AttachedPolicies { get; set; } = [];
    public List<string> InlinePolicies   { get; set; } = [];

    public string AttachedPoliciesDisplay => AttachedPolicies.Count > 0 ? string.Join(", ", AttachedPolicies) : "—";
}
