using Amazon.EC2;
using Amazon.EC2.Model;
using Amazon.CloudWatch.Model;
using Atlas.Infrastructure;
using Atlas.Models;
using System.Text;

namespace Atlas.Services.AWS;

public sealed class Ec2Service : IEc2Service
{
    private readonly IAwsSessionFactory _session;
    private readonly AwsClientFactory _clients;

    public Ec2Service(IAwsSessionFactory session, AwsClientFactory clients)
    {
        _session = session;
        _clients = clients;
    }

    static string D(string? v) => string.IsNullOrWhiteSpace(v) ? "—" : v;

    public async Task<IReadOnlyList<Ec2InstanceModel>> GetInstancesAsync(CancellationToken ct = default)
    {
        var client = _clients.GetEc2(_session.GetCredentials(), _session.GetRegion());
        var response = await client.DescribeInstancesAsync(new DescribeInstancesRequest(), ct);
        var region = _session.GetRegion();

        var instances = new List<Ec2InstanceModel>();
        foreach (var reservation in response.Reservations)
        foreach (var i in reservation.Instances)
        {
            var iamName = string.Empty;
            var iamArn  = i.IamInstanceProfile?.Arn ?? string.Empty;
            if (!string.IsNullOrEmpty(iamArn))
            {
                var parts = iamArn.Split('/');
                iamName = parts.Length > 1 ? parts[^1] : iamArn;
            }

            var ipv6 = i.NetworkInterfaces
                        .SelectMany(n => n.Ipv6Addresses)
                        .Select(a => a.Ipv6Address)
                        .FirstOrDefault() ?? string.Empty;

            var vCpus = (i.CpuOptions?.CoreCount ?? 0) * (i.CpuOptions?.ThreadsPerCore ?? 1);

            var lifecycle = string.IsNullOrEmpty(i.InstanceLifecycle?.Value)
                            ? "normal"
                            : i.InstanceLifecycle.Value;

            instances.Add(new Ec2InstanceModel
            {
                // Core
                InstanceId       = i.InstanceId,
                Name             = i.Tags.FirstOrDefault(t => t.Key == "Name")?.Value ?? "(no name)",
                InstanceType     = i.InstanceType.Value,
                State            = i.State.Name.Value,
                PublicIpAddress  = D(i.PublicIpAddress),
                PrivateIpAddress = D(i.PrivateIpAddress),
                Region           = region,
                LaunchTime       = i.LaunchTime,

                // Summary
                Ipv6Address            = D(ipv6),
                PublicDnsName          = D(i.PublicDnsName),
                PrivateDnsName         = D(i.PrivateDnsName),
                VpcId                  = D(i.VpcId),
                SubnetId               = D(i.SubnetId),
                IamInstanceProfileName = D(iamName),
                IamInstanceProfileArn  = iamArn,
                MetadataHttpTokens     = D(i.MetadataOptions?.HttpTokens?.Value),
                InstanceArn            = $"arn:aws:ec2:{region}:{reservation.OwnerId}:instance/{i.InstanceId}",
                AutoScalingGroupName   = D(i.Tags.FirstOrDefault(t => t.Key == "aws:autoscaling:groupName")?.Value),
                OwnerId                = D(reservation.OwnerId),
                ReservationId          = D(reservation.ReservationId),

                // Details
                ImageId                 = D(i.ImageId),
                MonitoringState         = D(i.Monitoring?.State?.Value),
                PlatformDetails         = D(i.PlatformDetails ?? i.Platform?.Value),
                KeyName                 = D(i.KeyName),
                VirtualizationType      = D(i.VirtualizationType?.Value),
                Lifecycle               = lifecycle,
                UsageOperation          = D(i.UsageOperation),
                CreditSpecification     = "—",
                BootMode                = D(i.BootMode?.Value),
                CurrentInstanceBootMode = D(i.CurrentInstanceBootMode?.Value),
                AmiLaunchIndex          = i.AmiLaunchIndex,
                StateTransitionReason   = D(i.StateTransitionReason),
                StateReasonMessage      = D(i.StateReason?.Message),
                HibernationEnabled      = i.HibernationOptions?.Configured ?? false,

                // Placement
                PlacementGroup   = D(i.Placement?.GroupName),
                PlacementGroupId = D(i.Placement?.GroupId),
                Tenancy          = D(i.Placement?.Tenancy?.Value),
                HostId           = D(i.Placement?.HostId),
                Affinity         = D(i.Placement?.Affinity),
                PartitionNumber  = i.Placement?.PartitionNumber == 0 ? null : i.Placement?.PartitionNumber,
                VCpuCount        = vCpus,

                // Capacity Reservation
                CapacityReservationId         = D(i.CapacityReservationId),
                CapacityReservationPreference = D(i.CapacityReservationSpecification?.CapacityReservationPreference?.Value),
            });
        }
        return instances;
    }

    public async Task<string> LaunchInstanceAsync(LaunchInstanceOptions options, CancellationToken ct = default)
    {
        var client = _clients.GetEc2(_session.GetCredentials(), _session.GetRegion());

        // ── Security group ──────────────────────────────────────────
        var sgIds = new List<string>();
        if (options.CreateNewSecurityGroup)
        {
            var sgName = string.IsNullOrEmpty(options.NewSecurityGroupName)
                ? $"launch-wizard-{DateTime.UtcNow:yyyyMMddHHmmss}"
                : options.NewSecurityGroupName;

            var sgReq = new CreateSecurityGroupRequest
            {
                GroupName   = sgName,
                Description = "Created by Atlas launch wizard"
            };
            if (!string.IsNullOrEmpty(options.VpcId)) sgReq.VpcId = options.VpcId;

            var sgResp = await client.CreateSecurityGroupAsync(sgReq, ct);
            var sgId = sgResp.GroupId;
            sgIds.Add(sgId);

            var ipPerms = new List<IpPermission>();
            if (options.AllowSsh)
                ipPerms.Add(new IpPermission
                {
                    IpProtocol = "tcp", FromPort = 22, ToPort = 22,
                    Ipv4Ranges = [new IpRange { CidrIp = "0.0.0.0/0", Description = "SSH" }]
                });
            if (options.AllowHttps)
                ipPerms.Add(new IpPermission
                {
                    IpProtocol = "tcp", FromPort = 443, ToPort = 443,
                    Ipv4Ranges = [new IpRange { CidrIp = "0.0.0.0/0", Description = "HTTPS" }]
                });
            if (options.AllowHttp)
                ipPerms.Add(new IpPermission
                {
                    IpProtocol = "tcp", FromPort = 80, ToPort = 80,
                    Ipv4Ranges = [new IpRange { CidrIp = "0.0.0.0/0", Description = "HTTP" }]
                });

            if (ipPerms.Count > 0)
                await client.AuthorizeSecurityGroupIngressAsync(new AuthorizeSecurityGroupIngressRequest
                {
                    GroupId       = sgId,
                    IpPermissions = ipPerms
                }, ct);
        }
        else if (!string.IsNullOrWhiteSpace(options.ExistingSecurityGroupId))
        {
            sgIds.Add(options.ExistingSecurityGroupId.Trim());
        }

        // ── Network interface ───────────────────────────────────────
        var ni = new InstanceNetworkInterfaceSpecification
        {
            DeviceIndex              = 0,
            AssociatePublicIpAddress = options.AutoAssignPublicIp,
            Groups                   = sgIds.Count > 0 ? sgIds : null
        };
        if (!string.IsNullOrEmpty(options.SubnetId)) ni.SubnetId = options.SubnetId;

        // ── Build RunInstances request ──────────────────────────────
        var request = new RunInstancesRequest
        {
            ImageId      = options.AmiId,
            InstanceType = new InstanceType(options.InstanceType),
            MinCount     = options.Count,
            MaxCount     = options.Count,
            NetworkInterfaces =
            [
                ni
            ],
            BlockDeviceMappings =
            [
                new BlockDeviceMapping
                {
                    DeviceName = "/dev/xvda",
                    Ebs = new EbsBlockDevice
                    {
                        VolumeSize          = options.RootVolumeSize,
                        VolumeType          = new VolumeType(options.RootVolumeType),
                        DeleteOnTermination = true
                    }
                }
            ],
            InstanceInitiatedShutdownBehavior = options.ShutdownBehavior == "terminate"
                ? ShutdownBehavior.Terminate
                : ShutdownBehavior.Stop,
            Monitoring   = options.DetailedMonitoring,
            EbsOptimized = options.EbsOptimized,
            MetadataOptions = new InstanceMetadataOptionsRequest
            {
                HttpTokens   = options.Imdsv2 == "required" ? HttpTokensState.Required : HttpTokensState.Optional,
                HttpEndpoint = InstanceMetadataEndpointState.Enabled
            }
        };

        if (!string.IsNullOrWhiteSpace(options.KeyPairName))
            request.KeyName = options.KeyPairName.Trim();

        if (!string.IsNullOrWhiteSpace(options.UserData))
            request.UserData = Convert.ToBase64String(Encoding.UTF8.GetBytes(options.UserData));

        if (!string.IsNullOrWhiteSpace(options.IamInstanceProfile))
            request.IamInstanceProfile = options.IamInstanceProfile.StartsWith("arn:", StringComparison.OrdinalIgnoreCase)
                ? new IamInstanceProfileSpecification { Arn  = options.IamInstanceProfile }
                : new IamInstanceProfileSpecification { Name = options.IamInstanceProfile };

        var tags = new List<Amazon.EC2.Model.Tag>();
        if (!string.IsNullOrEmpty(options.Name))
            tags.Add(new Amazon.EC2.Model.Tag { Key = "Name", Value = options.Name });
        if (tags.Count > 0)
            request.TagSpecifications =
            [
                new TagSpecification { ResourceType = ResourceType.Instance, Tags = tags }
            ];

        var response = await client.RunInstancesAsync(request, ct);
        var ids = response.Reservation.Instances.Select(i => i.InstanceId).ToList();

        // Termination protection requires a separate call per instance
        if (options.TerminationProtection)
            await Task.WhenAll(ids.Select(id => client.ModifyInstanceAttributeAsync(
                new ModifyInstanceAttributeRequest
                {
                    InstanceId            = id,
                    DisableApiTermination = true
                }, ct)));

        return string.Join(", ", ids);
    }

    // ── Network / resource discovery ────────────────────────────────

    public async Task<IReadOnlyList<VpcInfo>> GetVpcsAsync(CancellationToken ct = default)
    {
        var client   = _clients.GetEc2(_session.GetCredentials(), _session.GetRegion());
        var response = await client.DescribeVpcsAsync(new DescribeVpcsRequest(), ct);
        return response.Vpcs
            .Select(v => new VpcInfo
            {
                VpcId     = v.VpcId,
                CidrBlock = v.CidrBlock,
                IsDefault = v.IsDefault,
                Name      = v.Tags.FirstOrDefault(t => t.Key == "Name")?.Value ?? string.Empty
            })
            .OrderByDescending(v => v.IsDefault)
            .ThenBy(v => v.VpcId)
            .ToList();
    }

    public async Task<IReadOnlyList<SubnetInfo>> GetSubnetsAsync(string? vpcId = null, CancellationToken ct = default)
    {
        var client  = _clients.GetEc2(_session.GetCredentials(), _session.GetRegion());
        var request = new DescribeSubnetsRequest();
        if (!string.IsNullOrEmpty(vpcId))
            request.Filters = [new Filter { Name = "vpc-id", Values = [vpcId] }];
        var response = await client.DescribeSubnetsAsync(request, ct);
        return response.Subnets
            .Select(s => new SubnetInfo
            {
                SubnetId         = s.SubnetId,
                VpcId            = s.VpcId,
                AvailabilityZone = s.AvailabilityZone,
                CidrBlock        = s.CidrBlock,
                IsDefault        = s.DefaultForAz,
                Name             = s.Tags.FirstOrDefault(t => t.Key == "Name")?.Value ?? string.Empty
            })
            .OrderByDescending(s => s.IsDefault)
            .ThenBy(s => s.AvailabilityZone)
            .ToList();
    }

    public async Task<IReadOnlyList<KeyPairSummary>> GetKeyPairsAsync(CancellationToken ct = default)
    {
        var client   = _clients.GetEc2(_session.GetCredentials(), _session.GetRegion());
        var response = await client.DescribeKeyPairsAsync(new DescribeKeyPairsRequest(), ct);
        return response.KeyPairs
            .Select(k => new KeyPairSummary
            {
                KeyPairId = k.KeyPairId,
                KeyName   = k.KeyName,
                KeyType   = k.KeyType?.Value ?? "rsa"
            })
            .OrderBy(k => k.KeyName)
            .ToList();
    }

    public async Task<IReadOnlyList<SecurityGroupSummary>> GetSecurityGroupsAsync(
        string? vpcId = null, CancellationToken ct = default)
    {
        var client  = _clients.GetEc2(_session.GetCredentials(), _session.GetRegion());
        var request = new DescribeSecurityGroupsRequest();
        if (!string.IsNullOrEmpty(vpcId))
            request.Filters = [new Filter { Name = "vpc-id", Values = [vpcId] }];
        var response = await client.DescribeSecurityGroupsAsync(request, ct);
        return response.SecurityGroups
            .Select(sg => new SecurityGroupSummary
            {
                GroupId   = sg.GroupId,
                GroupName = sg.GroupName,
                VpcId     = sg.VpcId
            })
            .OrderBy(sg => sg.GroupName)
            .ToList();
    }

    public async Task<(string KeyMaterial, string KeyPairId)> CreateKeyPairAsync(
        string name, string keyType, CancellationToken ct = default)
    {
        var client   = _clients.GetEc2(_session.GetCredentials(), _session.GetRegion());
        var response = await client.CreateKeyPairAsync(new CreateKeyPairRequest
        {
            KeyName = name,
            KeyType = new KeyType(keyType.ToLower())
        }, ct);
        return (response.KeyPair.KeyMaterial, response.KeyPair.KeyPairId);
    }

    public async Task StartInstanceAsync(string instanceId, CancellationToken ct = default)
    {
        var client = _clients.GetEc2(_session.GetCredentials(), _session.GetRegion());
        await client.StartInstancesAsync(new StartInstancesRequest { InstanceIds = [instanceId] }, ct);
    }

    public async Task StopInstanceAsync(string instanceId, CancellationToken ct = default)
    {
        var client = _clients.GetEc2(_session.GetCredentials(), _session.GetRegion());
        await client.StopInstancesAsync(new StopInstancesRequest { InstanceIds = [instanceId] }, ct);
    }

    public async Task TerminateInstanceAsync(string instanceId, CancellationToken ct = default)
    {
        var client = _clients.GetEc2(_session.GetCredentials(), _session.GetRegion());
        await client.TerminateInstancesAsync(new TerminateInstancesRequest { InstanceIds = [instanceId] }, ct);
    }

    public async Task RebootInstanceAsync(string instanceId, CancellationToken ct = default)
    {
        var client = _clients.GetEc2(_session.GetCredentials(), _session.GetRegion());
        await client.RebootInstancesAsync(new RebootInstancesRequest { InstanceIds = [instanceId] }, ct);
    }

    public async Task<double> GetCpuUtilizationAsync(string instanceId, CancellationToken ct = default)
    {
        var cw = _clients.GetCloudWatch(_session.GetCredentials(), _session.GetRegion());
        var response = await cw.GetMetricStatisticsAsync(new GetMetricStatisticsRequest
        {
            Namespace  = "AWS/EC2",
            MetricName = "CPUUtilization",
            Dimensions = [new Dimension { Name = "InstanceId", Value = instanceId }],
            StartTimeUtc = DateTime.UtcNow.AddMinutes(-10),
            EndTimeUtc   = DateTime.UtcNow,
            Period       = 300,
            Statistics   = ["Average"]
        }, ct);

        return response.Datapoints.Count > 0
            ? response.Datapoints.OrderByDescending(d => d.Timestamp).First().Average
            : 0.0;
    }

    public async Task<Ec2InstanceMetrics> GetInstanceMetricsAsync(string instanceId, CancellationToken ct = default)
    {
        var cw    = _clients.GetCloudWatch(_session.GetCredentials(), _session.GetRegion());
        var end   = DateTime.UtcNow;
        var start = end.AddHours(-1);

        var cpuTask   = FetchMetricAsync(cw, instanceId, "CPUUtilization", "Average", start, end, ct);
        var netInTask = FetchMetricAsync(cw, instanceId, "NetworkIn",      "Sum",     start, end, ct);
        var netOutTask= FetchMetricAsync(cw, instanceId, "NetworkOut",     "Sum",     start, end, ct);
        var diskWTask = FetchMetricAsync(cw, instanceId, "DiskWriteBytes", "Sum",     start, end, ct);

        await Task.WhenAll(cpuTask, netInTask, netOutTask, diskWTask);

        return new Ec2InstanceMetrics(instanceId,
            cpuTask.Result, netInTask.Result, netOutTask.Result, diskWTask.Result);
    }

    private static async Task<IReadOnlyList<Models.MetricPoint>> FetchMetricAsync(
        Amazon.CloudWatch.IAmazonCloudWatch cw,
        string instanceId, string metricName, string statistic,
        DateTime start, DateTime end, CancellationToken ct)
    {
        var response = await cw.GetMetricStatisticsAsync(new GetMetricStatisticsRequest
        {
            Namespace    = "AWS/EC2",
            MetricName   = metricName,
            Dimensions   = [new Dimension { Name = "InstanceId", Value = instanceId }],
            StartTimeUtc = start,
            EndTimeUtc   = end,
            Period       = 300,
            Statistics   = [statistic]
        }, ct);

        return response.Datapoints
            .OrderBy(d => d.Timestamp)
            .Select(d => new Models.MetricPoint(d.Timestamp,
                statistic == "Average" ? d.Average : d.Sum))
            .ToList();
    }
}
