namespace Atlas.Models;

public class SubnetInfo
{
    public string SubnetId           { get; set; } = string.Empty;
    public string VpcId              { get; set; } = string.Empty;
    public string AvailabilityZone   { get; set; } = string.Empty;
    public string CidrBlock          { get; set; } = string.Empty;
    public bool   IsDefault          { get; set; }
    public string Name               { get; set; } = string.Empty;

    public string DisplayLabel
    {
        get
        {
            var s = string.IsNullOrEmpty(Name) ? SubnetId : $"{SubnetId}  ({Name})";
            s += $"  —  {AvailabilityZone}  {CidrBlock}";
            if (IsDefault) s += "  (default)";
            return s;
        }
    }
}
