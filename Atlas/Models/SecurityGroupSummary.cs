namespace Atlas.Models;

public class SecurityGroupSummary
{
    public string GroupId   { get; set; } = string.Empty;
    public string GroupName { get; set; } = string.Empty;
    public string VpcId     { get; set; } = string.Empty;
    public string DisplayLabel => $"{GroupName}  ({GroupId})";
}
