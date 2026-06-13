// ── Only import namespaces that don't create ambiguities ─────────────────────
using Amazon.CertificateManager.Model;
using Amazon.CloudWatchLogs.Model;
using Amazon.DynamoDBv2.Model;
using Amazon.EC2.Model;                             // primary — kept for EC2 types
using Amazon.ECR.Model;
using Amazon.ElastiCache.Model;
using Amazon.IdentityManagement.Model;
using Amazon.KeyManagementService.Model;
using Amazon.Lambda.Model;
using Amazon.RDS.Model;
using Amazon.S3;
using Amazon.SecretsManager.Model;
using Amazon.SimpleNotificationService.Model;
using Amazon.SQS.Model;
using Atlas.Infrastructure;
using Atlas.Infrastructure.Logging;
using Atlas.Services.Terraform.Hcl;
using Atlas.Services.Terraform.Hcl.Models;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
// ── Aliases to resolve cross-SDK naming conflicts ─────────────────────────────
using Ec2Filter     = Amazon.EC2.Model.Filter;
using Ec2Tag        = Amazon.EC2.Model.Tag;
using SysTask       = System.Threading.Tasks.Task;
// Fully-qualified aliases for namespaces that conflict with EC2.Model
using AsgModel      = Amazon.AutoScaling.Model;
using ApigwModel    = Amazon.APIGateway.Model;
using EcsModel      = Amazon.ECS.Model;
using EksModel      = Amazon.EKS.Model;
using ElbModel      = Amazon.ElasticLoadBalancingV2.Model;
using R53Model      = Amazon.Route53.Model;
using CwModel       = Amazon.CloudWatch.Model;

namespace Atlas.Services.Terraform.Import;

public sealed class ImportService : IImportService
{
    private readonly IAwsSessionFactory     _session;
    private readonly AwsClientFactory       _clients;
    private readonly ITerraformHclGenerator _hcl;

    public ImportService(
        IAwsSessionFactory     session,
        AwsClientFactory       clients,
        ITerraformHclGenerator hcl)
    {
        _session = session;
        _clients = clients;
        _hcl     = hcl;
    }

    // ══════════════════════════════════════════════════════════════════════
    // DiscoverResourcesAsync
    // ══════════════════════════════════════════════════════════════════════

    public async Task<ImportAnalysisResult> DiscoverResourcesAsync(
        ImportOptions      options,
        IProgress<string>? progress = null,
        CancellationToken  ct       = default)
    {
        var sw = Stopwatch.StartNew();

        var region = string.IsNullOrWhiteSpace(options.Region)
            ? _session.GetRegion()
            : options.Region;

        FileLogger.Info($"[ImportService] DiscoverResources  region={region}  types={string.Join(",", options.ResourceTypes)}");

        var results       = new List<DiscoveredResource>();
        var partialErrors = new Dictionary<AwsResourceType, string>();
        var lockObj       = new object();

        var tasks = options.ResourceTypes
            .Distinct()
            .Select(type => SafeDiscoverAsync(type, async () =>
            {
                var discovered = type switch
                {
                    // ── Compute ──────────────────────────────────────────
                    AwsResourceType.Ec2Instance      => await DiscoverEc2Async(region, options, progress, ct),
                    AwsResourceType.AutoScalingGroup => await DiscoverAsgAsync(region, options, progress, ct),
                    AwsResourceType.LaunchTemplate   => await DiscoverLaunchTemplatesAsync(region, options, progress, ct),
                    // ── Networking ───────────────────────────────────────
                    AwsResourceType.Vpc              => await DiscoverVpcsAsync(region, options, progress, ct),
                    AwsResourceType.Subnet           => await DiscoverSubnetsAsync(region, options, progress, ct),
                    AwsResourceType.SecurityGroup    => await DiscoverSecurityGroupsAsync(region, options, progress, ct),
                    AwsResourceType.RouteTable       => await DiscoverRouteTablesAsync(region, options, progress, ct),
                    AwsResourceType.InternetGateway  => await DiscoverIgwsAsync(region, options, progress, ct),
                    AwsResourceType.NatGateway       => await DiscoverNatGatewaysAsync(region, options, progress, ct),
                    AwsResourceType.LoadBalancer     => await DiscoverLoadBalancersAsync(region, options, progress, ct),
                    AwsResourceType.TargetGroup      => await DiscoverTargetGroupsAsync(region, options, progress, ct),
                    // ── Storage ──────────────────────────────────────────
                    AwsResourceType.S3Bucket         => await DiscoverS3Async(region, options, progress, ct),
                    // ── Database ─────────────────────────────────────────
                    AwsResourceType.RdsInstance      => await DiscoverRdsInstancesAsync(region, options, progress, ct),
                    AwsResourceType.RdsCluster       => await DiscoverRdsClustersAsync(region, options, progress, ct),
                    AwsResourceType.DynamoDbTable    => await DiscoverDynamoDbAsync(region, options, progress, ct),
                    AwsResourceType.ElastiCacheCluster => await DiscoverElastiCacheAsync(region, options, progress, ct),
                    // ── Serverless ───────────────────────────────────────
                    AwsResourceType.LambdaFunction   => await DiscoverLambdaAsync(region, options, progress, ct),
                    AwsResourceType.ApiGatewayRestApi => await DiscoverApiGatewayAsync(region, options, progress, ct),
                    // ── Containers ───────────────────────────────────────
                    AwsResourceType.EcsCluster       => await DiscoverEcsClustersAsync(region, options, progress, ct),
                    AwsResourceType.EcsService       => await DiscoverEcsServicesAsync(region, options, progress, ct),
                    AwsResourceType.EcrRepository    => await DiscoverEcrAsync(region, options, progress, ct),
                    AwsResourceType.EksCluster       => await DiscoverEksAsync(region, options, progress, ct),
                    // ── Messaging ────────────────────────────────────────
                    AwsResourceType.SqsQueue         => await DiscoverSqsAsync(region, options, progress, ct),
                    AwsResourceType.SnsTopic         => await DiscoverSnsAsync(region, options, progress, ct),
                    // ── IAM ──────────────────────────────────────────────
                    AwsResourceType.IamRole          => await DiscoverIamRolesAsync(options, progress, ct),
                    AwsResourceType.IamUser          => await DiscoverIamUsersAsync(options, progress, ct),
                    AwsResourceType.IamGroup         => await DiscoverIamGroupsAsync(options, progress, ct),
                    AwsResourceType.IamPolicy        => await DiscoverIamPoliciesAsync(options, progress, ct),
                    // ── Security ─────────────────────────────────────────
                    AwsResourceType.KmsKey           => await DiscoverKmsAsync(region, options, progress, ct),
                    AwsResourceType.SecretsManagerSecret => await DiscoverSecretsAsync(region, options, progress, ct),
                    AwsResourceType.AcmCertificate   => await DiscoverAcmAsync(region, options, progress, ct),
                    // ── DNS / CDN ─────────────────────────────────────────
                    AwsResourceType.Route53HostedZone => await DiscoverRoute53Async(options, progress, ct),
                    // ── Monitoring ───────────────────────────────────────
                    AwsResourceType.CloudWatchLogGroup => await DiscoverLogGroupsAsync(region, options, progress, ct),
                    AwsResourceType.CloudWatchAlarm  => await DiscoverAlarmsAsync(region, options, progress, ct),
                    _                                => [],
                };
                lock (lockObj) results.AddRange(discovered);
            },
            error => { lock (lockObj) partialErrors[type] = error; }))
            .ToList();

        await SysTask.WhenAll(tasks);
        sw.Stop();

        // ── Pass 1: deduplicate by AwsId (same resource discovered via multiple paths) ─
        var deduped = results
            .GroupBy(r => r.AwsId, StringComparer.OrdinalIgnoreCase)
            .Select(g => g.First())
            .OrderBy(r => r.ResourceType)
            .ThenBy(r => r.ResourceName)
            .ToList();

        // ── Pass 2: resolve TF-name collisions (different resources → same sanitized name) ─
        // e.g. two ACM certs for *.example.com in different regions → both become "wildcard_example_com"
        var final         = new List<DiscoveredResource>(deduped.Count);
        var usedAddresses = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var r in deduped)
        {
            if (!usedAddresses.Contains(r.ResourceAddress))
            {
                final.Add(r);
                usedAddresses.Add(r.ResourceAddress);
            }
            else
            {
                // Append last 8 alphanumeric chars of AwsId to disambiguate
                var suffix = new string(r.AwsId.Where(char.IsLetterOrDigit).ToArray()).ToLowerInvariant();
                suffix     = suffix.Length >= 8 ? suffix[^8..] : suffix;
                var unique = new DiscoveredResource
                {
                    ResourceType    = r.ResourceType,
                    AwsId           = r.AwsId,
                    ResourceName    = r.ResourceName,
                    SuggestedTfName = $"{r.SuggestedTfName}_{suffix}",
                    TerraformType   = r.TerraformType,
                    ImportId        = r.ImportId,
                    Region          = r.Region,
                    Tags            = r.Tags,
                    HclModel        = r.HclModel,
                    Notes           = [..r.Notes, $"Name disambiguated from collision with another {r.TerraformType}"],
                    Confidence      = r.Confidence,
                };
                final.Add(unique);
                usedAddresses.Add(unique.ResourceAddress);
                FileLogger.Warning($"[ImportService] TF name collision resolved: {r.ResourceAddress} → {unique.ResourceAddress}");
            }
        }

        FileLogger.Info($"[ImportService] Discovered {final.Count} unique resources in {sw.Elapsed.TotalSeconds:0.0}s  (dropped {results.Count - final.Count} duplicates)");

        return ImportAnalysisResult.Ok(final, partialErrors, region, sw.Elapsed);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Discovery methods — Compute
    // ══════════════════════════════════════════════════════════════════════

    private async Task<List<DiscoveredResource>> DiscoverEc2Async(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[EC2] Discovering instances…");
        var ec2  = _clients.GetEc2(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        var req  = new DescribeInstancesRequest
        {
            Filters    = BuildTagFilters(options.TagFilters),
            MaxResults = Math.Min(options.MaxResourcesPerType, 1000),
        };
        if (!options.IncludeTerminated)
            req.Filters.Add(new Ec2Filter
            {
                Name   = "instance-state-name",
                Values = ["pending", "running", "shutting-down", "stopping", "stopped"],
            });

        var instances = new List<Amazon.EC2.Model.Instance>();
        string? next = null;
        do
        {
            req.NextToken = next;
            var r = await ec2.DescribeInstancesAsync(req, ct);
            foreach (var res in r.Reservations)
            foreach (var i in res.Instances)
            {
                if (instances.Count >= options.MaxResourcesPerType) break;
                instances.Add(i);
            }
            next = instances.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        // Best-effort: read the live root volume size/type so the generated HCL
        // never tries to shrink an existing EBS volume (AWS rejects that and the
        // apply fails). Falls back to template defaults if DescribeVolumes is not
        // permitted. The ec2_instance template also ignore_changes root_block_device.
        var rootVolumes = await GetRootVolumeInfoAsync(ec2, instances, ct);

        foreach (var i in instances)
        {
            var name  = GetTag(i.Tags, "Name");
            var tf    = SanitizeTfName(name, i.InstanceId);
            var tags  = ToDictionary(i.Tags);
            rootVolumes.TryGetValue(i.InstanceId, out var rootVol);
            var model = new Ec2InstanceHclModel
            {
                ResourceName      = tf,
                AmiId             = i.ImageId,
                InstanceType      = i.InstanceType.Value,
                SubnetId          = NullIfEmpty(i.SubnetId),
                KeyName           = NullIfEmpty(i.KeyName),
                AssociatePublicIp = !string.IsNullOrEmpty(i.PublicIpAddress),
                SecurityGroupIds  = i.SecurityGroups.Select(sg => sg.GroupId).ToList(),
                IamInstanceProfile = NullIfEmpty(i.IamInstanceProfile?.Arn?.Split('/').LastOrDefault()),
                Monitoring        = i.Monitoring?.State?.Value == "enabled",
                RootVolumeGb      = rootVol.Size > 0 ? rootVol.Size : new Ec2InstanceHclModel().RootVolumeGb,
                RootVolumeType    = !string.IsNullOrEmpty(rootVol.Type) ? rootVol.Type : new Ec2InstanceHclModel().RootVolumeType,
                Tags              = tags.Select(kv => new HclTag(kv.Key, kv.Value)).Where(t => t.Key != "Name").ToList(),
            };
            list.Add(Resource(AwsResourceType.Ec2Instance, i.InstanceId, name, tf,
                "aws_instance", i.InstanceId, region, tags, model, BuildEc2Notes(i)));
        }

        progress?.Report($"[EC2] {list.Count} instances.");
        return list;
    }

    /// <summary>
    /// Resolves each instance's live root EBS volume size (GB) and type via a
    /// batched DescribeVolumes. Best-effort: returns an empty/partial map (so
    /// callers fall back to defaults) if the call is denied or fails.
    /// </summary>
    private static async Task<Dictionary<string, (int Size, string? Type)>> GetRootVolumeInfoAsync(
        Amazon.EC2.IAmazonEC2 ec2, List<Amazon.EC2.Model.Instance> instances, CancellationToken ct)
    {
        var map          = new Dictionary<string, (int, string?)>(StringComparer.OrdinalIgnoreCase);
        var volToInstance = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        foreach (var i in instances)
        {
            var root = i.BlockDeviceMappings.FirstOrDefault(
                          b => string.Equals(b.DeviceName, i.RootDeviceName, StringComparison.OrdinalIgnoreCase))
                       ?? i.BlockDeviceMappings.FirstOrDefault();
            var volId = root?.Ebs?.VolumeId;
            if (!string.IsNullOrEmpty(volId)) volToInstance[volId] = i.InstanceId;
        }

        if (volToInstance.Count == 0) return map;

        try
        {
            foreach (var chunk in volToInstance.Keys.Chunk(200))
            {
                var r = await ec2.DescribeVolumesAsync(
                    new DescribeVolumesRequest { VolumeIds = chunk.ToList() }, ct);
                foreach (var v in r.Volumes)
                    if (volToInstance.TryGetValue(v.VolumeId, out var instanceId))
                        map[instanceId] = (Convert.ToInt32(v.Size), v.VolumeType?.Value);
            }
        }
        catch (Exception ex)
        {
            FileLogger.Warning($"[ImportService] DescribeVolumes failed — root volume sizes default to template: {ex.Message}");
        }

        return map;
    }

    private async Task<List<DiscoveredResource>> DiscoverAsgAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[ASG] Discovering Auto Scaling Groups…");
        var asg  = _clients.GetAutoScaling(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await asg.DescribeAutoScalingGroupsAsync(
                new AsgModel.DescribeAutoScalingGroupsRequest { NextToken = next, MaxRecords = 100 }, ct);
            foreach (var g in r.AutoScalingGroups)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf   = SanitizeTfName(g.AutoScalingGroupName, g.AutoScalingGroupName);
                var tags = g.Tags.ToDictionary(t => t.Key, t => t.Value, StringComparer.OrdinalIgnoreCase);
                list.Add(Resource(AwsResourceType.AutoScalingGroup, g.AutoScalingGroupName,
                    g.AutoScalingGroupName, tf, "aws_autoscaling_group", g.AutoScalingGroupName, region, tags));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[ASG] {list.Count} groups.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverLaunchTemplatesAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[LT] Discovering Launch Templates…");
        var ec2  = _clients.GetEc2(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await ec2.DescribeLaunchTemplatesAsync(
                new Amazon.EC2.Model.DescribeLaunchTemplatesRequest { NextToken = next, MaxResults = 200 }, ct);
            foreach (var lt in r.LaunchTemplates)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf   = SanitizeTfName(lt.LaunchTemplateName, lt.LaunchTemplateId);
                var tags = ToDictionary(lt.Tags);
                list.Add(Resource(AwsResourceType.LaunchTemplate, lt.LaunchTemplateId,
                    lt.LaunchTemplateName, tf, "aws_launch_template", lt.LaunchTemplateId, region, tags));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[LT] {list.Count} launch templates.");
        return list;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Networking
    // ══════════════════════════════════════════════════════════════════════

    private async Task<List<DiscoveredResource>> DiscoverVpcsAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[VPC] Discovering VPCs…");
        var ec2  = _clients.GetEc2(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        var r    = await ec2.DescribeVpcsAsync(
            new DescribeVpcsRequest { Filters = BuildTagFilters(options.TagFilters) }, ct);
        foreach (var v in r.Vpcs)
        {
            if (list.Count >= options.MaxResourcesPerType) break;
            if (!options.IncludeAwsManagedResources && v.IsDefault) continue;
            var name = GetTag(v.Tags, "Name");
            var tf   = SanitizeTfName(name, v.VpcId);
            var tags = ToDictionary(v.Tags);
            var notes = new List<string>();
            if (v.IsDefault) notes.Add("Default VPC.");
            notes.Add($"CIDR: {v.CidrBlock}");
            list.Add(Resource(AwsResourceType.Vpc, v.VpcId, name, tf, "aws_vpc", v.VpcId, region, tags, notes: notes));
        }
        progress?.Report($"[VPC] {list.Count} VPCs.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverSubnetsAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[Subnet] Discovering subnets…");
        var ec2  = _clients.GetEc2(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await ec2.DescribeSubnetsAsync(
                new DescribeSubnetsRequest { Filters = BuildTagFilters(options.TagFilters), NextToken = next, MaxResults = 1000 }, ct);
            foreach (var s in r.Subnets)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                if (!options.IncludeAwsManagedResources && s.DefaultForAz) continue;
                var name  = GetTag(s.Tags, "Name");
                var tf    = SanitizeTfName(name, s.SubnetId);
                var tags  = ToDictionary(s.Tags);
                var notes = new List<string> { $"AZ: {s.AvailabilityZone}", $"CIDR: {s.CidrBlock}" };
                list.Add(Resource(AwsResourceType.Subnet, s.SubnetId, name, tf,
                    "aws_subnet", s.SubnetId, region, tags, notes: notes));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[Subnet] {list.Count} subnets.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverSecurityGroupsAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[SG] Discovering security groups…");
        var ec2  = _clients.GetEc2(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await ec2.DescribeSecurityGroupsAsync(
                new DescribeSecurityGroupsRequest { Filters = BuildTagFilters(options.TagFilters), NextToken = next, MaxResults = 1000 }, ct);
            foreach (var sg in r.SecurityGroups)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                if (!options.IncludeAwsManagedResources && sg.GroupName == "default") continue;
                var name  = GetTag(sg.Tags, "Name").Length > 0 ? GetTag(sg.Tags, "Name") : sg.GroupName;
                var tf    = SanitizeTfName(name, sg.GroupId);
                var tags  = ToDictionary(sg.Tags);
                var model = new SecurityGroupHclModel
                {
                    ResourceName = tf, SgName = sg.GroupName, Description = sg.Description,
                    VpcId = NullIfEmpty(sg.VpcId),
                    IngressRules = sg.IpPermissions.Select(MapToSgRule).ToList(),
                    EgressRules  = sg.IpPermissionsEgress.Select(MapToSgRule).ToList(),
                    Tags = tags.Select(kv => new HclTag(kv.Key, kv.Value)).ToList(),
                };
                list.Add(Resource(AwsResourceType.SecurityGroup, sg.GroupId, name, tf,
                    "aws_security_group", sg.GroupId, region, tags, model));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[SG] {list.Count} security groups.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverRouteTablesAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[RT] Discovering route tables…");
        var ec2  = _clients.GetEc2(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await ec2.DescribeRouteTablesAsync(
                new DescribeRouteTablesRequest { Filters = BuildTagFilters(options.TagFilters), NextToken = next, MaxResults = 100 }, ct);
            foreach (var rt in r.RouteTables)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var isMain = rt.Associations.Any(a => a.Main);
                if (!options.IncludeAwsManagedResources && isMain) continue;
                var name = GetTag(rt.Tags, "Name");
                var tf   = SanitizeTfName(name, rt.RouteTableId);
                var tags = ToDictionary(rt.Tags);
                list.Add(Resource(AwsResourceType.RouteTable, rt.RouteTableId, name, tf,
                    "aws_route_table", rt.RouteTableId, region, tags));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[RT] {list.Count} route tables.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverIgwsAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[IGW] Discovering internet gateways…");
        var ec2  = _clients.GetEc2(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        var r    = await ec2.DescribeInternetGatewaysAsync(
            new DescribeInternetGatewaysRequest { Filters = BuildTagFilters(options.TagFilters) }, ct);
        foreach (var igw in r.InternetGateways)
        {
            if (list.Count >= options.MaxResourcesPerType) break;
            var name = GetTag(igw.Tags, "Name");
            var tf   = SanitizeTfName(name, igw.InternetGatewayId);
            var tags = ToDictionary(igw.Tags);
            list.Add(Resource(AwsResourceType.InternetGateway, igw.InternetGatewayId, name, tf,
                "aws_internet_gateway", igw.InternetGatewayId, region, tags));
        }
        progress?.Report($"[IGW] {list.Count} gateways.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverNatGatewaysAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[NAT] Discovering NAT gateways…");
        var ec2  = _clients.GetEc2(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await ec2.DescribeNatGatewaysAsync(
                new DescribeNatGatewaysRequest { NextToken = next, MaxResults = 100 }, ct);
            foreach (var nat in r.NatGateways)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                if (nat.State == Amazon.EC2.NatGatewayState.Deleted) continue;
                var name = GetTag(nat.Tags, "Name");
                var tf   = SanitizeTfName(name, nat.NatGatewayId);
                var tags = ToDictionary(nat.Tags);
                list.Add(Resource(AwsResourceType.NatGateway, nat.NatGatewayId, name, tf,
                    "aws_nat_gateway", nat.NatGatewayId, region, tags));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[NAT] {list.Count} NAT gateways.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverLoadBalancersAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[ELB] Discovering load balancers…");
        var elb  = _clients.GetElbV2(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await elb.DescribeLoadBalancersAsync(
                new ElbModel.DescribeLoadBalancersRequest { Marker = marker, PageSize = 100 }, ct);
            foreach (var lb in r.LoadBalancers)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf   = SanitizeTfName(lb.LoadBalancerName, lb.LoadBalancerArn);
                var notes = new List<string> { $"Type: {lb.Type}", $"Scheme: {lb.Scheme}" };
                list.Add(Resource(AwsResourceType.LoadBalancer, lb.LoadBalancerArn, lb.LoadBalancerName, tf,
                    "aws_lb", lb.LoadBalancerArn, region, new Dictionary<string, string>(), notes: notes));
            }
            marker = list.Count < options.MaxResourcesPerType ? r.NextMarker : null;
        } while (marker != null);

        progress?.Report($"[ELB] {list.Count} load balancers.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverTargetGroupsAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[TG] Discovering target groups…");
        var elb  = _clients.GetElbV2(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await elb.DescribeTargetGroupsAsync(
                new ElbModel.DescribeTargetGroupsRequest { Marker = marker, PageSize = 100 }, ct);
            foreach (var tg in r.TargetGroups)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf = SanitizeTfName(tg.TargetGroupName, tg.TargetGroupArn);
                list.Add(Resource(AwsResourceType.TargetGroup, tg.TargetGroupArn, tg.TargetGroupName, tf,
                    "aws_lb_target_group", tg.TargetGroupArn, region, new Dictionary<string, string>()));
            }
            marker = list.Count < options.MaxResourcesPerType ? r.NextMarker : null;
        } while (marker != null);

        progress?.Report($"[TG] {list.Count} target groups.");
        return list;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Storage
    // ══════════════════════════════════════════════════════════════════════

    private async Task<List<DiscoveredResource>> DiscoverS3Async(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[S3] Discovering buckets…");
        var s3   = _clients.GetS3(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        var resp = await s3.ListBucketsAsync(ct);

        foreach (var bucket in resp.Buckets)
        {
            if (list.Count >= options.MaxResourcesPerType) break;
            Dictionary<string, string> tags = [];
            if (options.TagFilters.Count > 0)
            {
                try
                {
                    var tagResp = await s3.GetBucketTaggingAsync(
                        new Amazon.S3.Model.GetBucketTaggingRequest { BucketName = bucket.BucketName }, ct);
                    tags = tagResp.TagSet.ToDictionary(t => t.Key, t => t.Value, StringComparer.OrdinalIgnoreCase);
                    if (!MatchesTagFilters(tags, options.TagFilters)) continue;
                }
                catch (AmazonS3Exception ex) when (ex.ErrorCode == "NoSuchTagSet")
                {
                    if (options.TagFilters.Count > 0) continue;
                }
            }
            var tf    = SanitizeTfName(bucket.BucketName, bucket.BucketName);
            // Import mode: minimal model — no sub-resources, only real AWS tags.
            // Sub-resources (public_access_block, encryption) create drift because
            // they may not match the actual bucket configuration.
            var model = new S3BucketHclModel
            {
                ResourceName          = tf,
                BucketName            = bucket.BucketName,
                BlockPublicAcls       = false,
                BlockPublicPolicy     = false,
                IgnorePublicAcls      = false,
                RestrictPublicBuckets = false,
                ServerSideEncryption  = false,
                Tags = tags.Select(kv => new HclTag(kv.Key, kv.Value)).ToList(),
            };
            list.Add(Resource(AwsResourceType.S3Bucket, bucket.BucketName, bucket.BucketName, tf,
                "aws_s3_bucket", bucket.BucketName, region, tags, model));
        }

        progress?.Report($"[S3] {list.Count} buckets.");
        return list;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Database
    // ══════════════════════════════════════════════════════════════════════

    private async Task<List<DiscoveredResource>> DiscoverRdsInstancesAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[RDS] Discovering DB instances…");
        var rds  = _clients.GetRds(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await rds.DescribeDBInstancesAsync(
                new DescribeDBInstancesRequest { Marker = marker, MaxRecords = 100 }, ct);
            foreach (var db in r.DBInstances)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf    = SanitizeTfName(db.DBInstanceIdentifier, db.DBInstanceIdentifier);
                var notes = new List<string>
                {
                    $"Engine: {db.Engine} {db.EngineVersion}",
                    $"Class: {db.DBInstanceClass}",
                    $"Status: {db.DBInstanceStatus}",
                };
                list.Add(Resource(AwsResourceType.RdsInstance, db.DBInstanceIdentifier,
                    db.DBInstanceIdentifier, tf, "aws_db_instance", db.DBInstanceIdentifier, region, new Dictionary<string, string>(), notes: notes));
            }
            marker = list.Count < options.MaxResourcesPerType ? r.Marker : null;
        } while (marker != null);

        progress?.Report($"[RDS] {list.Count} instances.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverRdsClustersAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[RDS] Discovering DB clusters…");
        var rds  = _clients.GetRds(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await rds.DescribeDBClustersAsync(
                new DescribeDBClustersRequest { Marker = marker, MaxRecords = 100 }, ct);
            foreach (var c in r.DBClusters)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf    = SanitizeTfName(c.DBClusterIdentifier, c.DBClusterIdentifier);
                var notes = new List<string> { $"Engine: {c.Engine} {c.EngineVersion}", $"Status: {c.Status}" };
                list.Add(Resource(AwsResourceType.RdsCluster, c.DBClusterIdentifier,
                    c.DBClusterIdentifier, tf, "aws_rds_cluster", c.DBClusterIdentifier, region, new Dictionary<string, string>(), notes: notes));
            }
            marker = list.Count < options.MaxResourcesPerType ? r.Marker : null;
        } while (marker != null);

        progress?.Report($"[RDS] {list.Count} clusters.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverDynamoDbAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[DynamoDB] Discovering tables…");
        var ddb  = _clients.GetDynamoDb(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? last = null;
        do
        {
            var r = await ddb.ListTablesAsync(new ListTablesRequest { ExclusiveStartTableName = last, Limit = 100 }, ct);
            foreach (var name in r.TableNames)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf = SanitizeTfName(name, name);
                list.Add(Resource(AwsResourceType.DynamoDbTable, name, name, tf,
                    "aws_dynamodb_table", name, region, new Dictionary<string, string>()));
            }
            last = list.Count < options.MaxResourcesPerType ? r.LastEvaluatedTableName : null;
        } while (last != null);

        progress?.Report($"[DynamoDB] {list.Count} tables.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverElastiCacheAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[ElastiCache] Discovering clusters…");
        var ec   = _clients.GetElastiCache(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await ec.DescribeCacheClustersAsync(
                new DescribeCacheClustersRequest { Marker = marker, MaxRecords = 100 }, ct);
            foreach (var c in r.CacheClusters)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf    = SanitizeTfName(c.CacheClusterId, c.CacheClusterId);
                var notes = new List<string> { $"Engine: {c.Engine} {c.EngineVersion}", $"Node type: {c.CacheNodeType}" };
                list.Add(Resource(AwsResourceType.ElastiCacheCluster, c.CacheClusterId,
                    c.CacheClusterId, tf, "aws_elasticache_cluster", c.CacheClusterId, region, new Dictionary<string, string>(), notes: notes));
            }
            marker = list.Count < options.MaxResourcesPerType ? r.Marker : null;
        } while (marker != null);

        progress?.Report($"[ElastiCache] {list.Count} clusters.");
        return list;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Serverless
    // ══════════════════════════════════════════════════════════════════════

    private async Task<List<DiscoveredResource>> DiscoverLambdaAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[Lambda] Discovering functions…");
        var lambda = _clients.GetLambda(_session.GetCredentials(), region);
        var list   = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await lambda.ListFunctionsAsync(
                new ListFunctionsRequest { Marker = marker, MaxItems = 50 }, ct);
            foreach (var f in r.Functions)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf    = SanitizeTfName(f.FunctionName, f.FunctionName);
                var notes = new List<string> { $"Runtime: {f.Runtime}", $"Memory: {f.MemorySize}MB" };
                list.Add(Resource(AwsResourceType.LambdaFunction, f.FunctionArn, f.FunctionName, tf,
                    "aws_lambda_function", f.FunctionName, region, new Dictionary<string, string>(), notes: notes));
            }
            marker = list.Count < options.MaxResourcesPerType ? r.NextMarker : null;
        } while (marker != null);

        progress?.Report($"[Lambda] {list.Count} functions.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverApiGatewayAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[APIGW] Discovering REST APIs…");
        var apigw = _clients.GetApiGateway(_session.GetCredentials(), region);
        var list  = new List<DiscoveredResource>();
        string? pos = null;
        do
        {
            var r = await apigw.GetRestApisAsync(new ApigwModel.GetRestApisRequest { Position = pos, Limit = 100 }, ct);
            foreach (var api in r.Items)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf = SanitizeTfName(api.Name, api.Id);
                list.Add(Resource(AwsResourceType.ApiGatewayRestApi, api.Id, api.Name, tf,
                    "aws_api_gateway_rest_api", api.Id, region, new Dictionary<string, string>()));
            }
            pos = list.Count < options.MaxResourcesPerType ? r.Position : null;
        } while (pos != null);

        progress?.Report($"[APIGW] {list.Count} REST APIs.");
        return list;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Containers
    // ══════════════════════════════════════════════════════════════════════

    private async Task<List<DiscoveredResource>> DiscoverEcsClustersAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[ECS] Discovering clusters…");
        var ecs  = _clients.GetEcs(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var arns = await ecs.ListClustersAsync(new EcsModel.ListClustersRequest { NextToken = next, MaxResults = 100 }, ct);
            if (arns.ClusterArns.Count == 0) break;
            var desc = await ecs.DescribeClustersAsync(new EcsModel.DescribeClustersRequest { Clusters = arns.ClusterArns }, ct);
            foreach (var c in desc.Clusters)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                if (c.Status == "INACTIVE") continue;
                var name = c.ClusterName;
                var tf   = SanitizeTfName(name, name);
                var tags = c.Tags.ToDictionary(t => t.Key, t => t.Value, StringComparer.OrdinalIgnoreCase);
                list.Add(Resource(AwsResourceType.EcsCluster, c.ClusterArn, name, tf,
                    "aws_ecs_cluster", c.ClusterArn, region, tags));
            }
            next = list.Count < options.MaxResourcesPerType ? arns.NextToken : null;
        } while (next != null);

        progress?.Report($"[ECS] {list.Count} clusters.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverEcsServicesAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[ECS] Discovering services…");
        var ecs  = _clients.GetEcs(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();

        // List clusters first, then list services per cluster
        var clusters = await ecs.ListClustersAsync(new EcsModel.ListClustersRequest { MaxResults = 100 }, ct);
        foreach (var clusterArn in clusters.ClusterArns)
        {
            string? next = null;
            do
            {
                var svcArns = await ecs.ListServicesAsync(
                    new EcsModel.ListServicesRequest { Cluster = clusterArn, NextToken = next, MaxResults = 100 }, ct);
                if (svcArns.ServiceArns.Count == 0) break;

                var desc = await ecs.DescribeServicesAsync(
                    new EcsModel.DescribeServicesRequest { Cluster = clusterArn, Services = svcArns.ServiceArns }, ct);
                foreach (var svc in desc.Services)
                {
                    if (list.Count >= options.MaxResourcesPerType) break;
                    if (svc.Status == "INACTIVE") continue;
                    var clusterName = clusterArn.Split('/').Last();
                    var tf          = SanitizeTfName($"{clusterName}_{svc.ServiceName}", svc.ServiceArn);
                    // ECS service import format: cluster/service
                    list.Add(Resource(AwsResourceType.EcsService, svc.ServiceArn, svc.ServiceName, tf,
                        "aws_ecs_service", $"{clusterName}/{svc.ServiceName}", region, new Dictionary<string, string>()));
                }
                next = list.Count < options.MaxResourcesPerType ? svcArns.NextToken : null;
            } while (next != null);

            if (list.Count >= options.MaxResourcesPerType) break;
        }

        progress?.Report($"[ECS] {list.Count} services.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverEcrAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[ECR] Discovering repositories…");
        var ecr  = _clients.GetEcr(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await ecr.DescribeRepositoriesAsync(
                new DescribeRepositoriesRequest { NextToken = next, MaxResults = 100 }, ct);
            foreach (var repo in r.Repositories)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf = SanitizeTfName(repo.RepositoryName, repo.RepositoryName);
                list.Add(Resource(AwsResourceType.EcrRepository, repo.RepositoryArn, repo.RepositoryName, tf,
                    "aws_ecr_repository", repo.RepositoryName, region, new Dictionary<string, string>()));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[ECR] {list.Count} repositories.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverEksAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[EKS] Discovering clusters…");
        var eks  = _clients.GetEks(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await eks.ListClustersAsync(new EksModel.ListClustersRequest { NextToken = next, MaxResults = 100 }, ct);
            foreach (var name in r.Clusters)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf = SanitizeTfName(name, name);
                list.Add(Resource(AwsResourceType.EksCluster, name, name, tf,
                    "aws_eks_cluster", name, region, new Dictionary<string, string>()));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[EKS] {list.Count} clusters.");
        return list;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Messaging
    // ══════════════════════════════════════════════════════════════════════

    private async Task<List<DiscoveredResource>> DiscoverSqsAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[SQS] Discovering queues…");
        var sqs  = _clients.GetSqs(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await sqs.ListQueuesAsync(new ListQueuesRequest { NextToken = next, MaxResults = 1000 }, ct);
            foreach (var url in r.QueueUrls)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var name = url.Split('/').Last();
                var tf   = SanitizeTfName(name, name);
                list.Add(Resource(AwsResourceType.SqsQueue, url, name, tf,
                    "aws_sqs_queue", url, region, new Dictionary<string, string>()));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[SQS] {list.Count} queues.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverSnsAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[SNS] Discovering topics…");
        var sns  = _clients.GetSns(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await sns.ListTopicsAsync(new ListTopicsRequest { NextToken = next }, ct);
            foreach (var t in r.Topics)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var name = t.TopicArn.Split(':').Last();
                var tf   = SanitizeTfName(name, name);
                list.Add(Resource(AwsResourceType.SnsTopic, t.TopicArn, name, tf,
                    "aws_sns_topic", t.TopicArn, region, new Dictionary<string, string>()));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[SNS] {list.Count} topics.");
        return list;
    }

    // ══════════════════════════════════════════════════════════════════════
    // IAM
    // ══════════════════════════════════════════════════════════════════════

    private async Task<List<DiscoveredResource>> DiscoverIamRolesAsync(
        ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[IAM] Discovering roles…");
        var iam    = _clients.GetIam(_session.GetCredentials());
        var list   = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await iam.ListRolesAsync(new ListRolesRequest { Marker = marker }, ct);
            foreach (var role in r.Roles)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var isAwsManaged = role.Path.StartsWith("/aws-service-role/", StringComparison.OrdinalIgnoreCase)
                                || role.RoleName.StartsWith("AWSServiceRoleFor", StringComparison.OrdinalIgnoreCase);
                if (!options.IncludeAwsManagedResources && isAwsManaged) continue;

                var tf    = SanitizeTfName(role.RoleName, role.RoleName);
                var notes = new List<string>();
                if (isAwsManaged) notes.Add("AWS-managed service-linked role — import with caution.");

                var model = new IamRoleHclModel
                {
                    ResourceName = tf, RoleName = role.RoleName,
                    Description  = NullIfEmpty(role.Description) ?? "Managed by Atlas",
                    MaxSessionDuration = role.MaxSessionDuration,
                };
                list.Add(Resource(AwsResourceType.IamRole, role.RoleId, role.RoleName, tf,
                    "aws_iam_role", role.RoleName, "global", new Dictionary<string, string>(),
                    model, notes, isAwsManaged ? ImportConfidence.Low : ImportConfidence.High));
            }
            marker = r.IsTruncated ? r.Marker : null;
        } while (marker != null && list.Count < options.MaxResourcesPerType);

        progress?.Report($"[IAM] {list.Count} roles.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverIamUsersAsync(
        ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[IAM] Discovering users…");
        var iam  = _clients.GetIam(_session.GetCredentials());
        var list = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await iam.ListUsersAsync(new ListUsersRequest { Marker = marker }, ct);
            foreach (var user in r.Users)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf    = SanitizeTfName(user.UserName, user.UserName);
                var notes = new List<string>();
                if (user.PasswordLastUsed == default) notes.Add("User has never logged in via console.");
                list.Add(Resource(AwsResourceType.IamUser, user.UserId, user.UserName, tf,
                    "aws_iam_user", user.UserName, "global", new Dictionary<string, string>()));
            }
            marker = r.IsTruncated ? r.Marker : null;
        } while (marker != null && list.Count < options.MaxResourcesPerType);

        progress?.Report($"[IAM] {list.Count} users.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverIamGroupsAsync(
        ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[IAM] Discovering groups…");
        var iam  = _clients.GetIam(_session.GetCredentials());
        var list = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await iam.ListGroupsAsync(new ListGroupsRequest { Marker = marker }, ct);
            foreach (var g in r.Groups)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf = SanitizeTfName(g.GroupName, g.GroupName);
                list.Add(Resource(AwsResourceType.IamGroup, g.GroupId, g.GroupName, tf,
                    "aws_iam_group", g.GroupName, "global", new Dictionary<string, string>()));
            }
            marker = r.IsTruncated ? r.Marker : null;
        } while (marker != null && list.Count < options.MaxResourcesPerType);

        progress?.Report($"[IAM] {list.Count} groups.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverIamPoliciesAsync(
        ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[IAM] Discovering customer-managed policies…");
        var iam  = _clients.GetIam(_session.GetCredentials());
        var list = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await iam.ListPoliciesAsync(
                new ListPoliciesRequest { Scope = Amazon.IdentityManagement.PolicyScopeType.Local, Marker = marker }, ct);
            foreach (var p in r.Policies)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf = SanitizeTfName(p.PolicyName, p.PolicyName);
                list.Add(Resource(AwsResourceType.IamPolicy, p.PolicyId, p.PolicyName, tf,
                    "aws_iam_policy", p.Arn, "global", new Dictionary<string, string>()));
            }
            marker = r.IsTruncated ? r.Marker : null;
        } while (marker != null && list.Count < options.MaxResourcesPerType);

        progress?.Report($"[IAM] {list.Count} policies.");
        return list;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Security
    // ══════════════════════════════════════════════════════════════════════

    private async Task<List<DiscoveredResource>> DiscoverKmsAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[KMS] Discovering keys…");
        var kms  = _clients.GetKms(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await kms.ListKeysAsync(new ListKeysRequest { Marker = marker, Limit = 100 }, ct);
            foreach (var k in r.Keys)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                try
                {
                    var meta = await kms.DescribeKeyAsync(new DescribeKeyRequest { KeyId = k.KeyId }, ct);
                    var km   = meta.KeyMetadata;
                    // Skip AWS-managed and pending-deletion keys
                    if (km.KeyManager == Amazon.KeyManagementService.KeyManagerType.AWS) continue;
                    if (km.KeyState  == Amazon.KeyManagementService.KeyState.PendingDeletion) continue;

                    var desc = string.IsNullOrWhiteSpace(km.Description) ? km.KeyId : km.Description;
                    var tf   = SanitizeTfName(desc, km.KeyId);
                    var notes = new List<string> { $"Usage: {km.KeyUsage}", $"State: {km.KeyState}" };
                    list.Add(Resource(AwsResourceType.KmsKey, km.KeyId, desc, tf,
                        "aws_kms_key", km.KeyId, region, new Dictionary<string, string>(), notes: notes));
                }
                catch { /* skip inaccessible keys */ }
            }
            marker = list.Count < options.MaxResourcesPerType && r.Truncated ? r.NextMarker : null;
        } while (marker != null);

        progress?.Report($"[KMS] {list.Count} keys.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverSecretsAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[Secrets Manager] Discovering secrets…");
        var sm   = _clients.GetSecretsManager(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await sm.ListSecretsAsync(new ListSecretsRequest { NextToken = next, MaxResults = 100 }, ct);
            foreach (var s in r.SecretList)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf = SanitizeTfName(s.Name, s.ARN);
                list.Add(Resource(AwsResourceType.SecretsManagerSecret, s.ARN, s.Name, tf,
                    "aws_secretsmanager_secret", s.ARN, region, new Dictionary<string, string>()));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[Secrets] {list.Count} secrets.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverAcmAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[ACM] Discovering certificates…");
        var acm  = _clients.GetAcm(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await acm.ListCertificatesAsync(
                new ListCertificatesRequest { NextToken = next, MaxItems = 100 }, ct);
            foreach (var cert in r.CertificateSummaryList)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var domain = cert.DomainName ?? cert.CertificateArn;
                var tf     = SanitizeTfName(domain.Replace("*.", "wildcard_").Replace(".", "_"), cert.CertificateArn);
                list.Add(Resource(AwsResourceType.AcmCertificate, cert.CertificateArn, domain, tf,
                    "aws_acm_certificate", cert.CertificateArn, region, new Dictionary<string, string>()));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[ACM] {list.Count} certificates.");
        return list;
    }

    // ══════════════════════════════════════════════════════════════════════
    // DNS
    // ══════════════════════════════════════════════════════════════════════

    private async Task<List<DiscoveredResource>> DiscoverRoute53Async(
        ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[Route53] Discovering hosted zones…");
        var r53  = _clients.GetRoute53(_session.GetCredentials());
        var list = new List<DiscoveredResource>();
        string? marker = null;
        do
        {
            var r = await r53.ListHostedZonesAsync(
                new R53Model.ListHostedZonesRequest { Marker = marker, MaxItems = "100" }, ct);
            foreach (var z in r.HostedZones)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var name = z.Name.TrimEnd('.');
                var id   = z.Id.Split('/').Last();
                var tf   = SanitizeTfName(name.Replace(".", "_"), id);
                var notes = new List<string> { z.Config.PrivateZone ? "Private zone" : "Public zone" };
                list.Add(Resource(AwsResourceType.Route53HostedZone, id, name, tf,
                    "aws_route53_zone", id, "global", new Dictionary<string, string>(), notes: notes));
            }
            marker = list.Count < options.MaxResourcesPerType && r.IsTruncated ? r.NextMarker : null;
        } while (marker != null);

        progress?.Report($"[Route53] {list.Count} zones.");
        return list;
    }

    // ══════════════════════════════════════════════════════════════════════
    // Monitoring
    // ══════════════════════════════════════════════════════════════════════

    private async Task<List<DiscoveredResource>> DiscoverLogGroupsAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[CloudWatch Logs] Discovering log groups…");
        var cwl  = _clients.GetCloudWatchLogs(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await cwl.DescribeLogGroupsAsync(
                new DescribeLogGroupsRequest { NextToken = next, Limit = 50 }, ct);
            foreach (var g in r.LogGroups)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf = SanitizeTfName(g.LogGroupName.Replace("/", "_").TrimStart('_'), g.LogGroupName);
                list.Add(Resource(AwsResourceType.CloudWatchLogGroup, g.LogGroupName, g.LogGroupName, tf,
                    "aws_cloudwatch_log_group", g.LogGroupName, region, new Dictionary<string, string>()));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[CW Logs] {list.Count} log groups.");
        return list;
    }

    private async Task<List<DiscoveredResource>> DiscoverAlarmsAsync(
        string region, ImportOptions options, IProgress<string>? progress, CancellationToken ct)
    {
        progress?.Report("[CloudWatch] Discovering alarms…");
        var cw   = _clients.GetCloudWatch(_session.GetCredentials(), region);
        var list = new List<DiscoveredResource>();
        string? next = null;
        do
        {
            var r = await cw.DescribeAlarmsAsync(
                new CwModel.DescribeAlarmsRequest { NextToken = next, MaxRecords = 100 }, ct);
            foreach (var a in r.MetricAlarms)
            {
                if (list.Count >= options.MaxResourcesPerType) break;
                var tf = SanitizeTfName(a.AlarmName, a.AlarmArn);
                list.Add(Resource(AwsResourceType.CloudWatchAlarm, a.AlarmArn, a.AlarmName, tf,
                    "aws_cloudwatch_metric_alarm", a.AlarmName, region, new Dictionary<string, string>()));
            }
            next = list.Count < options.MaxResourcesPerType ? r.NextToken : null;
        } while (next != null);

        progress?.Report($"[CloudWatch] {list.Count} alarms.");
        return list;
    }

    // ══════════════════════════════════════════════════════════════════════
    // EnsureStateBucketAsync
    // ══════════════════════════════════════════════════════════════════════

    public async Task<string> EnsureStateBucketAsync(
        string             region,
        IProgress<string>? progress = null,
        CancellationToken  ct       = default)
    {
        var sts      = _clients.GetSts(_session.GetCredentials(), region);
        var identity = await sts.GetCallerIdentityAsync(new Amazon.SecurityToken.Model.GetCallerIdentityRequest(), ct);
        var bucket   = $"atlas-tfstate-{identity.Account}";

        progress?.Report($"[State] Checking S3 state bucket: {bucket}");

        var s3 = _clients.GetS3(_session.GetCredentials(), region);

        bool exists;
        try
        {
            await s3.GetBucketLocationAsync(
                new Amazon.S3.Model.GetBucketLocationRequest { BucketName = bucket }, ct);
            exists = true;
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound
                                          || ex.ErrorCode == "NoSuchBucket")
        {
            exists = false;
        }

        if (!exists)
        {
            progress?.Report($"[State] Creating state bucket {bucket}…");

            var createReq = new Amazon.S3.Model.PutBucketRequest { BucketName = bucket };
            if (!string.Equals(region, "us-east-1", StringComparison.OrdinalIgnoreCase))
                createReq.BucketRegion = Amazon.S3.S3Region.FindValue(region);

            await s3.PutBucketAsync(createReq, ct);

            await s3.PutBucketVersioningAsync(new Amazon.S3.Model.PutBucketVersioningRequest
            {
                BucketName       = bucket,
                VersioningConfig = new Amazon.S3.Model.S3BucketVersioningConfig
                    { Status = Amazon.S3.VersionStatus.Enabled },
            }, ct);

            await s3.PutPublicAccessBlockAsync(new Amazon.S3.Model.PutPublicAccessBlockRequest
            {
                BucketName = bucket,
                PublicAccessBlockConfiguration = new Amazon.S3.Model.PublicAccessBlockConfiguration
                {
                    BlockPublicAcls = true, IgnorePublicAcls = true,
                    BlockPublicPolicy = true, RestrictPublicBuckets = true,
                },
            }, ct);

            await s3.PutBucketEncryptionAsync(new Amazon.S3.Model.PutBucketEncryptionRequest
            {
                BucketName = bucket,
                ServerSideEncryptionConfiguration = new Amazon.S3.Model.ServerSideEncryptionConfiguration
                {
                    ServerSideEncryptionRules =
                    [
                        new Amazon.S3.Model.ServerSideEncryptionRule
                        {
                            ServerSideEncryptionByDefault = new Amazon.S3.Model.ServerSideEncryptionByDefault
                                { ServerSideEncryptionAlgorithm = Amazon.S3.ServerSideEncryptionMethod.AWSKMS },
                        },
                    ],
                },
            }, ct);

            progress?.Report($"[State] ✔ Bucket created with versioning + encryption: {bucket}");
        }
        else
        {
            progress?.Report($"[State] ✔ Using existing state bucket: {bucket}");
        }

        return bucket;
    }

    // ══════════════════════════════════════════════════════════════════════
    // GenerateImportBlocksAsync
    // ══════════════════════════════════════════════════════════════════════

    public Task<string> GenerateImportBlocksAsync(
        IReadOnlyList<DiscoveredResource> resources,
        CancellationToken                 ct = default)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# ──────────────────────────────────────────────────────────────────");
        sb.AppendLine("# Import blocks generated by Atlas · Terraform 1.5+ syntax");
        sb.AppendLine("# Run: terraform plan -generate-config-out=generated_resources.tf");
        sb.AppendLine("# ──────────────────────────────────────────────────────────────────");
        sb.AppendLine();

        foreach (var r in resources)
        {
            sb.AppendLine($"# {r.ResourceType}  {r.AwsId}");
            if (!string.IsNullOrEmpty(r.ResourceName)) sb.AppendLine($"# Name: {r.ResourceName}");
            if (r.Notes.Count > 0) sb.AppendLine($"# Note: {string.Join(" | ", r.Notes)}");
            sb.AppendLine("import {");
            sb.AppendLine($"  to = {r.ResourceAddress}");
            sb.AppendLine($"  id = \"{r.ImportId}\"");
            sb.AppendLine("}");
            sb.AppendLine();
        }

        return Task.FromResult(sb.ToString());
    }

    // ══════════════════════════════════════════════════════════════════════
    // SuggestHclFromExistingResourcesAsync (kept for compatibility)
    // ══════════════════════════════════════════════════════════════════════

    public async Task<IReadOnlyList<HclSuggestion>> SuggestHclFromExistingResourcesAsync(
        IReadOnlyList<DiscoveredResource> resources,
        string?                           outputDir = null,
        CancellationToken                 ct        = default)
    {
        var suggestions = new List<HclSuggestion>();
        foreach (var resource in resources)
        {
            ct.ThrowIfCancellationRequested();
            string? outputPath = null;
            if (outputDir != null)
            {
                var fileName = resource.ResourceType switch
                {
                    // File names match GeneratedHclSplitter's per-service layout
                    AwsResourceType.Ec2Instance   => "ec2.tf",
                    AwsResourceType.SecurityGroup  => "security_groups.tf",
                    AwsResourceType.S3Bucket       => "s3.tf",
                    // IamRole/IamUser/Vpc/Subnet: no Atlas template for import — let Terraform
                    // generate the correct HCL (with real trust policy, path, CIDR, etc.)
                    _                              => null,
                };
                if (fileName != null) outputPath = Path.Combine(outputDir, fileName);
            }
            if (outputPath == null) continue;
            var hclResult = await GenerateHclForResourceAsync(resource, outputPath, ct);
            suggestions.Add(new HclSuggestion { Resource = resource, HclResult = hclResult });
        }
        return suggestions;
    }

    private Task<HclGenerationResult> GenerateHclForResourceAsync(
        DiscoveredResource resource, string? outputPath, CancellationToken ct) =>
        resource.HclModel switch
        {
            Ec2InstanceHclModel   ec2  => _hcl.GenerateEc2InstanceAsync(ec2, outputPath, ct),
            S3BucketHclModel      s3   => _hcl.GenerateS3BucketAsync(s3, outputPath, ct),
            SecurityGroupHclModel sg   => _hcl.GenerateSecurityGroupAsync(sg, outputPath, ct),
            IamRoleHclModel       role => _hcl.GenerateIamRoleAsync(role, outputPath, ct),
            _                          => Task.FromResult(HclGenerationResult.Fail(
                $"No template for {resource.TerraformType} — Terraform will generate it via plan.")),
        };

    // ══════════════════════════════════════════════════════════════════════
    // Utilities
    // ══════════════════════════════════════════════════════════════════════

    private static DiscoveredResource Resource(
        AwsResourceType                    type,
        string                             awsId,
        string                             name,
        string                             tfName,
        string                             tfType,
        string                             importId,
        string                             region,
        IReadOnlyDictionary<string, string>? tags      = null,
        object?                            hclModel   = null,
        IReadOnlyList<string>?             notes      = null,
        ImportConfidence                   confidence = ImportConfidence.High) =>
        new()
        {
            ResourceType    = type,
            AwsId           = awsId,
            ResourceName    = name,
            SuggestedTfName = tfName,
            TerraformType   = tfType,
            ImportId        = importId,
            Region          = region,
            Tags            = tags ?? new Dictionary<string, string>(),
            HclModel        = hclModel,
            Notes           = notes ?? [],
            Confidence      = string.IsNullOrEmpty(name) ? ImportConfidence.Medium : confidence,
        };

    private static async SysTask SafeDiscoverAsync(
        AwsResourceType type, Func<SysTask> action, Action<string> onError)
    {
        try { await action(); }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            FileLogger.Warning($"[ImportService] {type} discovery failed: {ex.Message}");
            onError(ex.Message);
        }
    }

    private static readonly Regex SanitizeRegex = new(@"[^a-z0-9_]", RegexOptions.Compiled);

    private static string SanitizeTfName(string preferred, string fallback)
    {
        var raw       = string.IsNullOrWhiteSpace(preferred) ? fallback : preferred;
        var lower     = raw.ToLowerInvariant().Replace('-', '_').Replace(' ', '_').Replace('.', '_').Replace('/', '_');
        var sanitized = Regex.Replace(SanitizeRegex.Replace(lower, "_"), "_+", "_").Trim('_');
        if (sanitized.Length > 0 && char.IsDigit(sanitized[0])) sanitized = "r_" + sanitized;
        return string.IsNullOrEmpty(sanitized) ? "resource" : sanitized;
    }

    private static string GetTag(IEnumerable<Ec2Tag> tags, string key) =>
        tags.FirstOrDefault(t => t.Key.Equals(key, StringComparison.OrdinalIgnoreCase))?.Value ?? string.Empty;

    private static Dictionary<string, string> ToDictionary(IEnumerable<Ec2Tag> tags) =>
        tags.ToDictionary(t => t.Key, t => t.Value, StringComparer.OrdinalIgnoreCase);

    private static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s;

    private static List<Ec2Filter> BuildTagFilters(IReadOnlyList<TagFilter> filters) =>
        filters.Select(f => new Ec2Filter
        {
            Name   = $"tag:{f.Key}",
            Values = f.Value is not null ? [f.Value] : [],
        }).ToList();

    private static bool MatchesTagFilters(Dictionary<string, string> tags, IReadOnlyList<TagFilter> filters)
    {
        foreach (var f in filters)
        {
            if (!tags.TryGetValue(f.Key, out var val)) return false;
            if (f.Value is not null && !val.Equals(f.Value, StringComparison.OrdinalIgnoreCase)) return false;
        }
        return true;
    }

    private static IReadOnlyList<string> BuildEc2Notes(Amazon.EC2.Model.Instance i)  // fully qualified to avoid ECS ambiguity
    {
        var notes = new List<string>();
        if (i.State.Name.Value == "stopped")      notes.Add("Instance is currently stopped.");
        if (string.IsNullOrEmpty(i.KeyName))      notes.Add("No key pair — SSH via SSM only.");
        if (i.IamInstanceProfile == null)          notes.Add("No IAM instance profile.");
        if (i.MetadataOptions?.HttpTokens?.Value == "optional") notes.Add("IMDSv1 enabled (IMDSv2 recommended).");
        return notes;
    }

    private static SgRule MapToSgRule(Amazon.EC2.Model.IpPermission p)
    {
        var cidr = p.Ipv4Ranges.Count > 0
            ? p.Ipv4Ranges.Select(r => r.CidrIp).ToList()
            : p.Ipv6Ranges.Count > 0
                ? p.Ipv6Ranges.Select(r => r.CidrIpv6).ToList()
                : ["0.0.0.0/0"];
        return new SgRule
        {
            Description = p.Ipv4Ranges.FirstOrDefault()?.Description ?? p.Ipv6Ranges.FirstOrDefault()?.Description ?? string.Empty,
            FromPort    = p.FromPort,
            ToPort      = p.ToPort,
            Protocol    = p.IpProtocol == "-1" ? "-1" : p.IpProtocol,
            CidrBlocks  = cidr,
        };
    }
}
