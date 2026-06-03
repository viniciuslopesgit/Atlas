namespace Atlas.Models;

public class AccessKeyInfo
{
    public string    AccessKeyId       { get; set; } = string.Empty;
    public string    Status            { get; set; } = string.Empty; // "Active" | "Inactive"
    public DateTime  CreateDate        { get; set; }
    public DateTime? LastUsedDate      { get; set; }
    public string    LastUsedRegion    { get; set; } = string.Empty;
    public string    LastUsedService   { get; set; } = string.Empty;

    public bool   IsActive           => Status == "Active";
    public string LastUsedDisplay    => LastUsedDate.HasValue ? LastUsedDate.Value.ToString("yyyy-MM-dd") : "Never";
}

public class IamTagModel
{
    public string Key   { get; set; } = string.Empty;
    public string Value { get; set; } = string.Empty;
}

public class IamUserModel
{
    public string UserName            { get; set; } = string.Empty;
    public string UserId              { get; set; } = string.Empty;
    public string Arn                 { get; set; } = string.Empty;
    public string Path                { get; set; } = string.Empty;
    public DateTime CreateDate        { get; set; }
    public DateTime? PasswordLastUsed { get; set; }
    public int AccessKeyCount         { get; set; }
    public List<string>               Groups            { get; set; } = [];
    public List<string>               AttachedPolicies  { get; set; } = []; // policy names (display)
    public List<(string Name, string Arn)> AttachedPolicyRefs { get; set; } = []; // name + ARN for actions
    public List<string>               InlinePolicies    { get; set; } = [];
    public List<AccessKeyInfo> AccessKeys        { get; set; } = [];
    public List<IamTagModel>   Tags              { get; set; } = [];

    public string PasswordLastUsedDisplay =>
        PasswordLastUsed.HasValue ? PasswordLastUsed.Value.ToString("yyyy-MM-dd HH:mm") : "Never";
    public string GroupsDisplay           => Groups.Count > 0 ? string.Join(", ", Groups) : "—";
    public string AttachedPoliciesDisplay => AttachedPolicies.Count > 0 ? string.Join(", ", AttachedPolicies) : "—";
}
