using Atlas.Models;

namespace Atlas.Services.AWS;

public interface IEc2Service
{
    Task<IReadOnlyList<Ec2InstanceModel>>     GetInstancesAsync(CancellationToken ct = default);
    Task<string>                              LaunchInstanceAsync(LaunchInstanceOptions options, CancellationToken ct = default);
    Task                                      StartInstanceAsync(string instanceId, CancellationToken ct = default);
    Task                                      StopInstanceAsync(string instanceId, CancellationToken ct = default);
    Task                                      RebootInstanceAsync(string instanceId, CancellationToken ct = default);
    Task                                      TerminateInstanceAsync(string instanceId, CancellationToken ct = default);
    Task<double>                              GetCpuUtilizationAsync(string instanceId, CancellationToken ct = default);
    Task<Ec2InstanceMetrics>                  GetInstanceMetricsAsync(string instanceId, CancellationToken ct = default);

    // Network / resource discovery (for Launch dialog)
    Task<IReadOnlyList<VpcInfo>>              GetVpcsAsync(CancellationToken ct = default);
    Task<IReadOnlyList<SubnetInfo>>           GetSubnetsAsync(string? vpcId = null, CancellationToken ct = default);
    Task<IReadOnlyList<KeyPairSummary>>       GetKeyPairsAsync(CancellationToken ct = default);
    Task<IReadOnlyList<SecurityGroupSummary>> GetSecurityGroupsAsync(string? vpcId = null, CancellationToken ct = default);
    Task<(string KeyMaterial, string KeyPairId)> CreateKeyPairAsync(string name, string keyType, CancellationToken ct = default);
}
