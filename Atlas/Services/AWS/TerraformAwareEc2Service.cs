using Atlas.Infrastructure.Logging;
using Atlas.Models;
using Atlas.Services.Terraform;
using Atlas.Services.Terraform.Hcl.Models;

namespace Atlas.Services.AWS;

/// <summary>
/// Decorator de <see cref="IEc2Service"/> que, após <see cref="LaunchInstanceAsync"/>,
/// gera automaticamente o HCL Terraform correspondente em background.
/// Todas as outras chamadas são delegadas ao serviço interior sem modificação.
/// </summary>
public sealed class TerraformAwareEc2Service : IEc2Service
{
    private readonly IEc2Service       _inner;
    private readonly ITerraformService _terraform;

    public TerraformAwareEc2Service(IEc2Service inner, ITerraformService terraform)
    {
        _inner     = inner;
        _terraform = terraform;
    }

    // ── LaunchInstanceAsync — ponto de integração ─────────────────────────

    public async Task<string> LaunchInstanceAsync(
        LaunchInstanceOptions options,
        CancellationToken     ct = default)
    {
        var instanceId = await _inner.LaunchInstanceAsync(options, ct);

        // Gera HCL em background sem bloquear o fluxo principal
        if (_terraform.ActiveProject is not null)
            _ = Task.Run(() => GenerateHclAsync(options, instanceId), CancellationToken.None);

        return instanceId;
    }

    // ── Passthrough — métodos sem integração Terraform ────────────────────

    public Task<IReadOnlyList<Ec2InstanceModel>> GetInstancesAsync(CancellationToken ct = default)
        => _inner.GetInstancesAsync(ct);

    public Task StartInstanceAsync(string instanceId, CancellationToken ct = default)
        => _inner.StartInstanceAsync(instanceId, ct);

    public Task StopInstanceAsync(string instanceId, CancellationToken ct = default)
        => _inner.StopInstanceAsync(instanceId, ct);

    public Task RebootInstanceAsync(string instanceId, CancellationToken ct = default)
        => _inner.RebootInstanceAsync(instanceId, ct);

    public Task TerminateInstanceAsync(string instanceId, CancellationToken ct = default)
        => _inner.TerminateInstanceAsync(instanceId, ct);

    public Task<double> GetCpuUtilizationAsync(string instanceId, CancellationToken ct = default)
        => _inner.GetCpuUtilizationAsync(instanceId, ct);

    public Task<Ec2InstanceMetrics> GetInstanceMetricsAsync(string instanceId, CancellationToken ct = default)
        => _inner.GetInstanceMetricsAsync(instanceId, ct);

    public Task<IReadOnlyList<VpcInfo>> GetVpcsAsync(CancellationToken ct = default)
        => _inner.GetVpcsAsync(ct);

    public Task<IReadOnlyList<SubnetInfo>> GetSubnetsAsync(string? vpcId = null, CancellationToken ct = default)
        => _inner.GetSubnetsAsync(vpcId, ct);

    public Task<IReadOnlyList<KeyPairSummary>> GetKeyPairsAsync(CancellationToken ct = default)
        => _inner.GetKeyPairsAsync(ct);

    public Task<IReadOnlyList<SecurityGroupSummary>> GetSecurityGroupsAsync(string? vpcId = null, CancellationToken ct = default)
        => _inner.GetSecurityGroupsAsync(vpcId, ct);

    public Task<(string KeyMaterial, string KeyPairId)> CreateKeyPairAsync(string name, string keyType, CancellationToken ct = default)
        => _inner.CreateKeyPairAsync(name, keyType, ct);

    // ── HCL generation ────────────────────────────────────────────────────

    private async Task GenerateHclAsync(LaunchInstanceOptions opts, string instanceId)
    {
        try
        {
            var model = BuildHclModel(opts, instanceId);
            var result = await _terraform.GenerateEc2ResourceAsync(model);

            if (result.Success)
                FileLogger.Info($"[TerraformAwareEc2] Auto-generated HCL for '{model.ResourceName}' → {result.WrittenFiles.FirstOrDefault()}");
            else
                FileLogger.Warning($"[TerraformAwareEc2] HCL generation failed for '{opts.Name}': {result.ErrorMessage}");
        }
        catch (Exception ex)
        {
            FileLogger.Error("[TerraformAwareEc2] Background HCL generation threw", ex);
        }
    }

    private static Ec2InstanceHclModel BuildHclModel(LaunchInstanceOptions opts, string instanceId)
    {
        var resourceName = SanitizeTfName(
            string.IsNullOrWhiteSpace(opts.Name) ? instanceId : opts.Name);

        return new Ec2InstanceHclModel
        {
            ResourceName          = resourceName,
            AmiId                 = opts.AmiId,
            InstanceType          = opts.InstanceType,
            SubnetId              = NullIfEmpty(opts.SubnetId),
            KeyName               = NullIfEmpty(opts.KeyPairName),
            AssociatePublicIp     = opts.AutoAssignPublicIp,
            SecurityGroupIds      = NullIfEmpty(opts.ExistingSecurityGroupId) is { } sgId
                                    ? [sgId] : [],
            IamInstanceProfile    = NullIfEmpty(opts.IamInstanceProfile),
            UserData              = NullIfEmpty(opts.UserData),
            Monitoring            = opts.DetailedMonitoring,
            DisableApiTermination = opts.TerminationProtection,
            RootVolumeGb          = opts.RootVolumeSize,
            RootVolumeType        = opts.RootVolumeType,
            Tags =
            [
                new("Name", opts.Name),
                new("InstanceId", instanceId),
            ],
        };
    }

    private static string SanitizeTfName(string raw)
    {
        var lower = raw.ToLowerInvariant()
                       .Replace(' ', '_').Replace('-', '_').Replace('.', '_');
        var clean = System.Text.RegularExpressions.Regex
                        .Replace(lower, @"[^a-z0-9_]", "_")
                        .Trim('_');
        clean = System.Text.RegularExpressions.Regex.Replace(clean, "_+", "_");
        if (clean.Length > 0 && char.IsDigit(clean[0])) clean = "r_" + clean;
        return string.IsNullOrEmpty(clean) ? "resource" : clean;
    }

    private static string? NullIfEmpty(string? s) =>
        string.IsNullOrWhiteSpace(s) ? null : s;
}
