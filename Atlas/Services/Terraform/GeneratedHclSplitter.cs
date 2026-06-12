using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace Atlas.Services.Terraform;

/// <summary>
/// Splits the single <c>generated_resources.tf</c> emitted by
/// <c>terraform plan -generate-config-out</c> into one .tf file per AWS service
/// (ec2.tf, vpc.tf, iam.tf, s3.tf, …). Terraform merges all .tf files in a
/// directory, so this is purely an organizational change — the configuration
/// is identical.
/// </summary>
internal static class GeneratedHclSplitter
{
    private static readonly Regex ResourceStartRx = new(
        @"^resource\s+""([^""]+)""\s+""([^""]+)""", RegexOptions.Compiled);

    /// <summary>
    /// Splits <paramref name="generatedTfPath"/> into per-service files in the
    /// same directory, appending when a target file already exists, then deletes
    /// the original. Returns (fileName, resourceCount) per file written,
    /// ordered by file name. Returns an empty list when the file doesn't exist.
    /// </summary>
    public static async Task<IReadOnlyList<(string FileName, int ResourceCount)>> SplitAsync(
        string generatedTfPath)
    {
        if (!File.Exists(generatedTfPath)) return [];

        var dir     = Path.GetDirectoryName(generatedTfPath)!;
        var content = await File.ReadAllTextAsync(generatedTfPath, Encoding.UTF8);

        // fileName → accumulated blocks (each block = comment lines + resource lines)
        var groups = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

        var lines           = content.Split('\n');
        var pendingComments = new List<string>();
        var block           = new List<string>();
        string? resType     = null;
        int     depth       = 0;

        foreach (var line in lines)
        {
            var t = line.TrimStart();

            if (resType is null)
            {
                if (t.StartsWith("#"))
                {
                    // __generated__ comments belong to the next resource block
                    pendingComments.Add(line);
                    continue;
                }

                var m = ResourceStartRx.Match(t);
                if (m.Success)
                {
                    resType = m.Groups[1].Value;
                    depth   = CountBraces(line);
                    block.Clear();
                    block.AddRange(pendingComments);
                    pendingComments.Clear();
                    block.Add(line);

                    if (depth <= 0)
                    {
                        AddBlock(groups, counts, resType, block);
                        resType = null;
                    }
                }
                else
                {
                    pendingComments.Clear(); // blank/unknown line — drop stale comments
                }
                continue;
            }

            depth += CountBraces(line);
            block.Add(line);

            if (depth <= 0)
            {
                AddBlock(groups, counts, resType, block);
                block.Clear();
                resType = null;
            }
        }

        if (groups.Count == 0) return [];

        var written = new List<(string FileName, int ResourceCount)>();
        foreach (var (fileName, blocks) in groups.OrderBy(g => g.Key, StringComparer.OrdinalIgnoreCase))
        {
            var path = Path.Combine(dir, fileName);
            var sb   = new StringBuilder();

            if (File.Exists(path))
            {
                var existing = await File.ReadAllTextAsync(path, Encoding.UTF8);
                sb.Append(existing.TrimEnd('\r', '\n'));
                sb.AppendLine();
            }

            foreach (var b in blocks)
            {
                sb.AppendLine();
                sb.AppendLine(b.TrimEnd('\r', '\n'));
            }

            await File.WriteAllTextAsync(path, sb.ToString(), Encoding.UTF8);
            written.Add((fileName, counts[fileName]));
        }

        File.Delete(generatedTfPath);
        return written;
    }

    private static void AddBlock(
        Dictionary<string, List<string>> groups,
        Dictionary<string, int>          counts,
        string                           resType,
        List<string>                     block)
    {
        var file = GetServiceFileName(resType);
        if (!groups.TryGetValue(file, out var list))
        {
            list = [];
            groups[file] = list;
            counts[file] = 0;
        }
        list.Add(string.Join('\n', block));
        counts[file]++;
    }

    // ── Service mapping ───────────────────────────────────────────────────────
    // Curated map for types whose name prefix doesn't match their service,
    // then a generic fallback that uses the first token after "aws_".

    internal static string GetServiceFileName(string resType) => resType switch
    {
        // EC2 (compute)
        "aws_instance" or "aws_launch_template" or "aws_launch_configuration" or
        "aws_autoscaling_group" or "aws_autoscaling_policy" or
        "aws_autoscaling_schedule" or "aws_autoscaling_attachment" or
        "aws_key_pair" or "aws_ami" or "aws_ami_copy" or
        "aws_ebs_volume" or "aws_ebs_snapshot" or "aws_volume_attachment" or
        "aws_eip" or "aws_eip_association" or
        "aws_placement_group" or "aws_spot_instance_request"
            => "ec2.tf",

        // VPC (networking)
        "aws_vpc" or "aws_subnet" or "aws_route_table" or "aws_route" or
        "aws_route_table_association" or "aws_main_route_table_association" or
        "aws_internet_gateway" or "aws_egress_only_internet_gateway" or
        "aws_nat_gateway" or "aws_network_acl" or "aws_network_acl_rule" or
        "aws_network_acl_association" or "aws_network_interface" or
        "aws_network_interface_attachment" or "aws_dhcp_options" or
        "aws_vpc_dhcp_options_association" or "aws_flow_log" or
        "aws_customer_gateway" or "aws_vpn_gateway" or "aws_vpn_connection" or
        "aws_vpn_gateway_attachment" or "aws_default_route_table" or
        "aws_default_network_acl" or "aws_default_vpc" or "aws_default_subnet" or
        "aws_vpc_endpoint" or "aws_vpc_endpoint_route_table_association" or
        "aws_vpc_peering_connection" or "aws_vpc_ipv4_cidr_block_association"
            => "vpc.tf",

        // Security groups
        "aws_security_group" or "aws_security_group_rule" or
        "aws_default_security_group" or
        "aws_vpc_security_group_ingress_rule" or
        "aws_vpc_security_group_egress_rule"
            => "security_groups.tf",

        // Load balancing
        "aws_lb" or "aws_lb_listener" or "aws_lb_listener_rule" or
        "aws_lb_listener_certificate" or "aws_lb_target_group" or
        "aws_lb_target_group_attachment" or
        "aws_alb" or "aws_alb_listener" or "aws_alb_listener_rule" or
        "aws_alb_target_group" or "aws_alb_target_group_attachment" or
        "aws_elb" or "aws_elb_attachment" or "aws_app_cookie_stickiness_policy" or
        "aws_lb_cookie_stickiness_policy"
            => "elb.tf",

        // RDS
        "aws_db_instance" or "aws_db_subnet_group" or "aws_db_parameter_group" or
        "aws_db_option_group" or "aws_db_snapshot" or "aws_db_event_subscription" or
        "aws_db_proxy" or "aws_db_proxy_default_target_group" or "aws_db_proxy_target" or
        "aws_rds_cluster" or "aws_rds_cluster_instance" or
        "aws_rds_cluster_parameter_group" or "aws_rds_cluster_endpoint" or
        "aws_rds_global_cluster"
            => "rds.tf",

        // API Gateway (REST + v2)
        _ when resType.StartsWith("aws_api_gateway_", StringComparison.Ordinal) ||
               resType.StartsWith("aws_apigatewayv2_", StringComparison.Ordinal)
            => "apigateway.tf",

        // Generic fallback: aws_<service>_… → <service>.tf
        _ => FallbackFileName(resType),
    };

    private static string FallbackFileName(string resType)
    {
        if (!resType.StartsWith("aws_", StringComparison.Ordinal))
            return "misc.tf";

        var rest = resType[4..];
        int us   = rest.IndexOf('_');
        var svc  = us > 0 ? rest[..us] : rest;

        return string.IsNullOrEmpty(svc) ? "misc.tf" : $"{svc}.tf";
    }

    private static int CountBraces(string line)
    {
        int  count    = 0;
        bool inString = false;
        foreach (char ch in line)
        {
            if (ch == '"') inString = !inString;
            if (inString) continue;
            if      (ch == '{') count++;
            else if (ch == '}') count--;
        }
        return count;
    }
}
