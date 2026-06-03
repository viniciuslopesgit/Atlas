namespace Atlas.Models;

public class LaunchInstanceOptions
{
    // Name
    public string Name { get; set; } = string.Empty;

    // AMI
    public string AmiId          { get; set; } = "ami-06422669907866d20";
    public string AmiDisplayName { get; set; } = "Amazon Linux 2023 AMI";
    public string Architecture   { get; set; } = "x86_64";

    // Instance type
    public string InstanceType { get; set; } = "t3.micro";

    // Key pair
    public string? KeyPairName { get; set; }

    // Network
    public string? VpcId              { get; set; }
    public string? SubnetId           { get; set; }
    public bool    AutoAssignPublicIp { get; set; } = true;

    // Security group
    public bool   CreateNewSecurityGroup    { get; set; } = true;
    public string NewSecurityGroupName      { get; set; } = string.Empty;
    public string ExistingSecurityGroupId  { get; set; } = string.Empty;
    public bool   AllowSsh                 { get; set; } = true;
    public bool   AllowHttp                { get; set; } = false;
    public bool   AllowHttps               { get; set; } = false;

    // Storage
    public int    RootVolumeSize { get; set; } = 8;
    public string RootVolumeType { get; set; } = "gp3";

    // Advanced
    public string? IamInstanceProfile    { get; set; }
    public string? UserData              { get; set; }
    public string  ShutdownBehavior      { get; set; } = "stop";  // "stop" | "terminate"
    public bool    TerminationProtection { get; set; } = false;
    public bool    DetailedMonitoring    { get; set; } = false;
    public bool    EbsOptimized          { get; set; } = false;
    public string  Imdsv2                { get; set; } = "optional"; // "optional" | "required"

    // Count
    public int Count { get; set; } = 1;
}
