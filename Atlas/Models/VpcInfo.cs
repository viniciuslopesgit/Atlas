namespace Atlas.Models;

public class VpcInfo
{
    public string VpcId    { get; set; } = string.Empty;
    public string CidrBlock{ get; set; } = string.Empty;
    public bool   IsDefault{ get; set; }
    public string Name     { get; set; } = string.Empty;

    public string DisplayLabel
    {
        get
        {
            var s = VpcId;
            if (!string.IsNullOrEmpty(Name)) s += $"  —  {Name}";
            if (IsDefault) s += "  (default)";
            return s;
        }
    }
}
