namespace Atlas.Models;

public class Ec2InstanceModel
{
    // ── Core (used by table) ────────────────────────────────────────────────
    public string InstanceId       { get; set; } = string.Empty;
    public string Name             { get; set; } = string.Empty;
    public string InstanceType     { get; set; } = string.Empty;
    public string State            { get; set; } = string.Empty;
    public string PublicIpAddress  { get; set; } = string.Empty;
    public string PrivateIpAddress { get; set; } = string.Empty;
    public string Region           { get; set; } = string.Empty;
    public DateTime LaunchTime     { get; set; }
    public double CpuUtilization   { get; set; }

    // ── Instance Summary ────────────────────────────────────────────────────
    public string Ipv6Address            { get; set; } = string.Empty;
    public string PublicDnsName          { get; set; } = string.Empty;
    public string PrivateDnsName         { get; set; } = string.Empty;
    public string VpcId                  { get; set; } = string.Empty;
    public string SubnetId               { get; set; } = string.Empty;
    public string IamInstanceProfileName { get; set; } = string.Empty;
    public string IamInstanceProfileArn  { get; set; } = string.Empty;
    public string MetadataHttpTokens     { get; set; } = string.Empty;
    public string InstanceArn            { get; set; } = string.Empty;
    public string AutoScalingGroupName   { get; set; } = string.Empty;
    public string OwnerId                { get; set; } = string.Empty;
    public string ReservationId          { get; set; } = string.Empty;

    // ── Instance Details ────────────────────────────────────────────────────
    public string ImageId                { get; set; } = string.Empty;
    public string MonitoringState        { get; set; } = string.Empty;
    public string PlatformDetails        { get; set; } = string.Empty;
    public string KeyName                { get; set; } = string.Empty;
    public string VirtualizationType     { get; set; } = string.Empty;
    public string Lifecycle              { get; set; } = string.Empty;
    public string UsageOperation         { get; set; } = string.Empty;
    public string CreditSpecification    { get; set; } = string.Empty;
    public string BootMode               { get; set; } = string.Empty;
    public string CurrentInstanceBootMode { get; set; } = string.Empty;
    public int    AmiLaunchIndex         { get; set; }
    public string StateTransitionReason  { get; set; } = string.Empty;
    public string StateReasonMessage     { get; set; } = string.Empty;
    public bool   HibernationEnabled     { get; set; }

    // ── Host & Placement ────────────────────────────────────────────────────
    public string PlacementGroup         { get; set; } = string.Empty;
    public string PlacementGroupId       { get; set; } = string.Empty;
    public string Tenancy                { get; set; } = string.Empty;
    public string HostId                 { get; set; } = string.Empty;
    public string Affinity               { get; set; } = string.Empty;
    public int?   PartitionNumber        { get; set; }
    public int    VCpuCount              { get; set; }

    // ── Capacity Reservation ────────────────────────────────────────────────
    public string CapacityReservationId         { get; set; } = string.Empty;
    public string CapacityReservationPreference { get; set; } = string.Empty;
}
