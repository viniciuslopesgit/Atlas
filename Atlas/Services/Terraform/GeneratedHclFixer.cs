using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace Atlas.Services.Terraform;

/// <summary>
/// Fixes known invalid attribute patterns that <c>terraform plan -generate-config-out</c>
/// emits across multiple resource types.
/// </summary>
internal static class GeneratedHclFixer
{
    public readonly record struct FixSummary(
        int TagsAllFixes    = 0,
        int LambdaFixes     = 0,
        int SubnetFixes     = 0,
        int VpcFixes        = 0,
        int RouteTableFixes = 0,
        int DynamoDbFixes   = 0,
        int AcmFixes        = 0,
        int ApiGatewayFixes = 0,
        int IamFixes        = 0)
    {
        public int TotalFixes =>
            TagsAllFixes + LambdaFixes + SubnetFixes + VpcFixes +
            RouteTableFixes + DynamoDbFixes + AcmFixes + ApiGatewayFixes + IamFixes;

        public IEnumerable<string> ToLines()
        {
            if (TagsAllFixes    > 0) yield return $"    tags_all removed (provider-managed): {TagsAllFixes}";
            if (LambdaFixes     > 0) yield return $"    lambda deployment conflicts resolved: {LambdaFixes}";
            if (SubnetFixes     > 0) yield return $"    subnet attribute conflicts resolved: {SubnetFixes}";
            if (VpcFixes        > 0) yield return $"    vpc orphaned ipv6 attributes removed: {VpcFixes}";
            if (RouteTableFixes > 0) yield return $"    route table sanitized (list→block, empty attrs stripped): {RouteTableFixes}";
            if (DynamoDbFixes   > 0) yield return $"    dynamodb invalid recovery block removed: {DynamoDbFixes}";
            if (AcmFixes        > 0) yield return $"    acm validation_method=NONE removed: {AcmFixes}";
            if (ApiGatewayFixes > 0) yield return $"    api gateway empty vpc_endpoint_ids fixed: {ApiGatewayFixes}";
            if (IamFixes        > 0) yield return $"    iam/secrets name_prefix conflicts resolved: {IamFixes}";
        }
    }

    // ─────────────────────────────────────────────────────────────────────────

    private static readonly Regex ResourceStartRx = new(
        @"^resource\s+""([^""]+)""", RegexOptions.Compiled);

    // ─────────────────────────────────────────────────────────────────────────

    public static async Task<FixSummary> FixAsync(string filePath)
    {
        if (!File.Exists(filePath)) return default;

        var original = await File.ReadAllTextAsync(filePath, Encoding.UTF8);
        var (result, summary) = FixContent(original);

        if (summary.TotalFixes > 0)
            await File.WriteAllTextAsync(filePath, result, Encoding.UTF8);

        return summary;
    }

    internal static (string result, FixSummary summary) FixContent(string content)
    {
        var lines    = content.Split('\n');
        var segments = new List<string>();
        var nonBlock = new List<string>();
        var block    = new List<string>();
        string? resType = null;
        int     depth   = 0;
        var     c       = new Counters();

        foreach (var line in lines)
        {
            var t = line.TrimStart();

            if (resType is null)
            {
                var rm = ResourceStartRx.Match(t);
                if (rm.Success)
                {
                    segments.AddRange(nonBlock);
                    nonBlock.Clear();
                    resType = rm.Groups[1].Value;
                    depth   = CountBraces(line);
                    block.Add(line);
                }
                else
                {
                    nonBlock.Add(line);
                }
                continue;
            }

            depth += CountBraces(line);
            block.Add(line);

            if (depth <= 0)
            {
                segments.AddRange(ProcessBlock(block, resType, c));
                block.Clear();
                resType = null;
                depth   = 0;
            }
        }

        segments.AddRange(nonBlock);
        segments.AddRange(block);

        return (string.Join('\n', segments), c.ToSummary());
    }

    // ── Block dispatcher ─────────────────────────────────────────────────────
    // Pre-strip tags_all (both single-line and multi-line) before dispatching,
    // so individual fixers never need to handle it.

    private static IReadOnlyList<string> ProcessBlock(
        List<string> lines, string resType, Counters c)
    {
        var (stripped, tagsCount) = StripTagsAll(lines);
        c.TagsAll += tagsCount;

        return resType switch
        {
            "aws_lambda_function"        => FixLambda(stripped, c),
            "aws_subnet"                 => FixSubnet(stripped, c),
            "aws_vpc"                    => FixVpc(stripped, c),
            "aws_route_table"            => FixRouteTable(stripped, c),
            "aws_dynamodb_table"         => FixDynamoDb(stripped, c),
            "aws_acm_certificate"        => FixAcm(stripped, c),
            "aws_api_gateway_rest_api"   => FixApiGateway(stripped, c),
            "aws_iam_role"               or
            "aws_iam_policy"             or
            "aws_iam_user"               or
            "aws_secretsmanager_secret"  => FixNameConflict(stripped, c),
            _                            => stripped,
        };
    }

    // ── tags_all pre-pass ─────────────────────────────────────────────────────
    // Removes both:
    //   single-line : tags_all = {}
    //   multi-line  : tags_all = {\n  ...\n}

    private static (List<string> result, int count) StripTagsAll(List<string> lines)
    {
        var  result  = new List<string>(lines.Count);
        bool inBlock = false;
        int  depth   = 0;
        int  count   = 0;

        foreach (var l in lines)
        {
            var t = l.TrimStart();

            if (!inBlock && Regex.IsMatch(t, @"^tags_all\s*=\s*\{"))
            {
                int d = CountBraces(l);
                if (d <= 0) count++;                     // single-line: tags_all = {}
                else        { inBlock = true; depth = d; }  // multi-line block opens
                continue;
            }

            if (inBlock)
            {
                depth += CountBraces(l);
                if (depth <= 0) { inBlock = false; count++; }
                continue;
            }

            result.Add(l);
        }

        return (result, count);
    }

    // ── Lambda ───────────────────────────────────────────────────────────────
    // Terraform sometimes generates filename, image_uri, and s3_bucket together.
    // Only one may be set; remove the null/empty ones. If all are null, fall back
    // to a placeholder filename so the HCL is syntactically valid for import.

    private static IReadOnlyList<string> FixLambda(List<string> lines, Counters c)
    {
        string? imageUri = null, s3Bucket = null, filename = null;
        foreach (var l in lines)
        {
            var t = l.TrimStart();
            if (TryGetValue(t, "image_uri", out var v))  imageUri = v;
            if (TryGetValue(t, "s3_bucket", out var v2)) s3Bucket = v2;
            if (TryGetValue(t, "filename",  out var v3)) filename = v3;
        }

        bool hasImage = IsRealValue(imageUri);
        bool hasS3    = IsRealValue(s3Bucket);
        bool hasFile  = IsRealValue(filename);

        bool imagePresent = imageUri != null;
        bool s3Present    = s3Bucket != null;
        bool filePresent  = filename != null;
        int  presentCount = (imagePresent ? 1 : 0) + (s3Present ? 1 : 0) + (filePresent ? 1 : 0);

        if (presentCount < 2 && (hasImage || hasS3 || hasFile))
            return lines; // no conflict — tags_all already stripped by pre-pass

        // Resolve conflict by priority: image > s3 > file
        bool keepImage = hasImage;
        bool keepS3    = !keepImage && hasS3;

        var  result  = new List<string>(lines.Count);
        bool didFix  = false;
        bool filenamePlaceholderInserted = false;

        foreach (var l in lines)
        {
            var t    = l.TrimStart();
            var attr = GetAttrName(t);

            if (keepImage)
            {
                if (attr is "filename" or "s3_bucket" or "s3_key" or "s3_object_version")
                { didFix = true; continue; }
            }
            else if (keepS3)
            {
                if (attr is "image_uri" or "filename")
                { didFix = true; continue; }
            }
            else
            {
                if (attr is "image_uri" or "s3_bucket" or "s3_key" or "s3_object_version")
                { didFix = true; continue; }

                if (!hasFile && !filenamePlaceholderInserted && filePresent &&
                    attr is "filename")
                {
                    var indent = l.Length - t.Length;
                    result.Add(new string(' ', indent) + "filename = \"/dev/null\"");
                    filenamePlaceholderInserted = true;
                    didFix = true;
                    continue;
                }
            }

            if (!hasImage && !hasS3 && !hasFile && !filenamePlaceholderInserted &&
                presentCount == 0 && t.StartsWith("}"))
            {
                var indent = l.Length - t.Length;
                result.Add(new string(' ', indent + 2) + "filename = \"/dev/null\"");
                filenamePlaceholderInserted = true;
                didFix = true;
            }

            result.Add(l);
        }

        if (didFix) c.Lambda++;
        return result;
    }

    // ── Subnet ───────────────────────────────────────────────────────────────
    // Remove attributes that conflict or require unsupported companion arguments.

    private static IReadOnlyList<string> FixSubnet(List<string> lines, Counters c)
    {
        var  result = new List<string>(lines.Count);
        bool didFix = false;
        foreach (var l in lines)
        {
            var attr = GetAttrName(l.TrimStart());
            // availability_zone_id conflicts with availability_zone (keep availability_zone)
            // enable_lni_at_device_index must not be zero
            // map_customer_owned_ip_on_launch requires customer_owned_ipv4_pool + outpost_arn
            if (attr is "availability_zone_id"        or
                        "enable_lni_at_device_index"  or
                        "map_customer_owned_ip_on_launch")
            { didFix = true; continue; }
            result.Add(l);
        }
        if (didFix) c.Subnet++;
        return result;
    }

    // ── VPC ──────────────────────────────────────────────────────────────────
    // ipv6_netmask_length requires ipv6_ipam_pool_id; remove both when pool is absent.

    private static IReadOnlyList<string> FixVpc(List<string> lines, Counters c)
    {
        string? ipamPool = null;
        foreach (var l in lines)
            if (TryGetValue(l.TrimStart(), "ipv6_ipam_pool_id", out var v)) ipamPool = v;

        bool removeIpv6 = !IsRealValue(ipamPool);

        var  result = new List<string>(lines.Count);
        bool didFix = false;
        foreach (var l in lines)
        {
            var attr = GetAttrName(l.TrimStart());
            if (removeIpv6 && attr is "ipv6_netmask_length" or "ipv6_ipam_pool_id")
            { didFix = true; continue; }
            result.Add(l);
        }
        if (didFix) c.Vpc++;
        return result;
    }

    // ── Route Table ──────────────────────────────────────────────────────────
    // Block format : route { ... }
    //   → keep when cidr_block OR ipv6_cidr_block is non-empty
    //   → strip all empty/null attributes from kept blocks
    // List  format : route = [{ ... }, { ... }]
    //   → convert each object to a route { } block
    //   → include only non-empty attributes
    //   → drop objects that have no valid destination

    private static IReadOnlyList<string> FixRouteTable(List<string> lines, Counters c)
    {
        var  result = new List<string>(lines.Count);
        bool didFix = false;

        // ── Block-format state ─────────────────────────────────────────────
        bool inRouteBlock = false;
        int  rbDepth = 0;
        bool rbHasCidr = false, rbHasIpv6 = false;
        var  rbBuf = new List<string>();

        // ── List-format state ──────────────────────────────────────────────
        bool inRouteList  = false;
        int  rlSquareDepth = 0;
        var  rlBuf = new List<string>();

        foreach (var l in lines)
        {
            var t = l.TrimStart();

            // ── Block format ───────────────────────────────────────────────
            if (!inRouteBlock && !inRouteList &&
                (t == "route {" || Regex.IsMatch(t, @"^route\s*\{")))
            {
                inRouteBlock = true;
                rbDepth      = CountBraces(l);
                rbHasCidr    = false;
                rbHasIpv6    = false;
                rbBuf.Clear();
                rbBuf.Add(l);
                continue;
            }

            if (inRouteBlock)
            {
                rbDepth += CountBraces(l);
                if (TryGetValue(t, "cidr_block",      out var cv) && IsRealValue(cv)) rbHasCidr = true;
                if (TryGetValue(t, "ipv6_cidr_block", out var iv) && IsRealValue(iv)) rbHasIpv6 = true;
                rbBuf.Add(l);

                if (rbDepth <= 0)
                {
                    inRouteBlock = false;
                    if (rbHasCidr || rbHasIpv6)
                    {
                        // Keep block but strip empty/null attributes
                        foreach (var bl in rbBuf)
                        {
                            var bt    = bl.TrimStart();
                            var bAttr = GetAttrName(bt);
                            if (!string.IsNullOrEmpty(bAttr) &&
                                TryGetValue(bt, bAttr, out var bVal) && !IsRealValue(bVal))
                            { didFix = true; continue; }
                            result.Add(bl);
                        }
                    }
                    else
                    {
                        didFix = true; // no valid destination — drop block
                    }
                    rbBuf.Clear();
                }
                continue;
            }

            // ── List format: route = [ ... ] ───────────────────────────────
            if (!inRouteList && Regex.IsMatch(t, @"^route\s*=\s*\["))
            {
                rlSquareDepth = CountSquareBrackets(l);
                rlBuf.Clear();
                rlBuf.Add(l);

                if (rlSquareDepth <= 0)
                {
                    // route = [] — empty list, drop silently
                    rlBuf.Clear();
                    didFix = true;
                }
                else
                {
                    inRouteList = true;
                }
                continue;
            }

            if (inRouteList)
            {
                rlSquareDepth += CountSquareBrackets(l);
                rlBuf.Add(l);

                if (rlSquareDepth <= 0)
                {
                    inRouteList = false;
                    result.AddRange(ConvertRouteListToBlocks(rlBuf, ref didFix));
                    rlBuf.Clear();
                }
                continue;
            }

            result.Add(l);
        }

        if (didFix) c.RouteTable++;
        return result;
    }

    // Converts the buffered "route = [ { ... }, { ... } ]" lines into
    // individual "route { ... }" blocks, stripping every empty attribute.
    private static List<string> ConvertRouteListToBlocks(List<string> rawLines, ref bool didFix)
    {
        // Normalise compound tokens so the main loop sees one structural char per line:
        //   "route = [{"  →  "route = ["  +  "{"
        //   "}, {"        →  "},"         +  "{"
        //   "}]"          →  "}"          +  "]"
        var lines = new List<string>(rawLines.Count + 4);
        foreach (var l in rawLines)
        {
            var t      = l.TrimStart();
            int indent = l.Length - t.Length;
            var pad    = new string(' ', indent);

            if (Regex.IsMatch(t, @"\[\s*\{"))
            {
                lines.Add(l[..l.LastIndexOf('{')].TrimEnd());
                lines.Add(pad + "{");
            }
            else if (Regex.IsMatch(t, @"^\}\s*,\s*\{"))
            {
                lines.Add(pad + "},");
                lines.Add(pad + "{");
            }
            else if (Regex.IsMatch(t, @"^\}\s*\]"))
            {
                int bi = l.IndexOf(']');
                lines.Add(pad + "}");
                lines.Add(pad + l[bi..]);
            }
            else
            {
                lines.Add(l);
            }
        }

        var result = new List<string>();

        // Derive indentation from the first line ("  route = [" → 2-space base).
        string baseIndent = rawLines.Count > 0
            ? new string(' ', rawLines[0].Length - rawLines[0].TrimStart().Length)
            : "  ";
        string attrIndent = baseIndent + "  ";

        bool    inObj    = false;
        int     objDepth = 0;
        string? cidrVal  = null;
        string? ipv6Val  = null;
        var     objAttrs = new List<(string name, string val)>();

        foreach (var l in lines)
        {
            var t = l.TrimStart();

            if (!inObj)
            {
                // Skip the list header and footer lines
                if (Regex.IsMatch(t, @"^route\s*=\s*\[") || t is "]" or "],")
                    continue;

                if (t == "{")
                {
                    inObj    = true;
                    objDepth = 1;
                    cidrVal  = null;
                    ipv6Val  = null;
                    objAttrs.Clear();
                }
            }
            else
            {
                objDepth += CountBraces(l);

                if (objDepth <= 0)
                {
                    inObj = false;
                    EmitRouteBlock(objAttrs, cidrVal, ipv6Val, baseIndent, attrIndent, result, ref didFix);
                    objAttrs.Clear();
                }
                else
                {
                    var attrName = GetAttrName(t);
                    if (!string.IsNullOrEmpty(attrName) && TryGetValue(t, attrName, out var val))
                    {
                        if (attrName == "cidr_block")      cidrVal = val;
                        if (attrName == "ipv6_cidr_block") ipv6Val = val;
                        if (IsRealValue(val))
                            objAttrs.Add((attrName, val));
                    }
                }
            }
        }

        didFix = true; // list format was always converted to block format
        return result;
    }

    private static void EmitRouteBlock(
        List<(string name, string val)> attrs,
        string? cidrVal, string? ipv6Val,
        string indent, string attrIndent,
        List<string> result, ref bool didFix)
    {
        if (!IsRealValue(cidrVal) && !IsRealValue(ipv6Val))
        {
            didFix = true; // no valid destination — drop
            return;
        }

        if (attrs.Count == 0) { didFix = true; return; }

        result.Add(string.Empty);
        result.Add($"{indent}route {{");
        foreach (var (name, val) in attrs)
            result.Add($"{attrIndent}{name} = {val}");
        result.Add($"{indent}}}");
    }

    // ── DynamoDB ─────────────────────────────────────────────────────────────
    // Remove point_in_time_recovery block when recovery_period_in_days is 0 or null.

    private static IReadOnlyList<string> FixDynamoDb(List<string> lines, Counters c)
    {
        var  result    = new List<string>(lines.Count);
        bool didFix    = false;
        bool inPITR    = false;
        bool dropPITR  = false;
        int  pitrDepth = 0;
        var  pitrBuf   = new List<string>();

        foreach (var l in lines)
        {
            var t = l.TrimStart();

            if (!inPITR && Regex.IsMatch(t, @"^point_in_time_recovery\s*\{"))
            {
                inPITR    = true;
                dropPITR  = false;
                pitrDepth = CountBraces(l);
                pitrBuf.Clear();
                pitrBuf.Add(l);
                continue;
            }

            if (inPITR)
            {
                pitrDepth += CountBraces(l);
                pitrBuf.Add(l);

                if (TryGetValue(t, "recovery_period_in_days", out var v) &&
                    (v == "0" || !IsRealValue(v)))
                    dropPITR = true;

                if (pitrDepth <= 0)
                {
                    inPITR = false;
                    if (!dropPITR) result.AddRange(pitrBuf);
                    else           didFix = true;
                    pitrBuf.Clear();
                }
                continue;
            }

            result.Add(l);
        }

        if (didFix) c.DynamoDb++;
        return result;
    }

    // ── ACM Certificate ──────────────────────────────────────────────────────
    // validation_method = "NONE" is not a valid value; remove the attribute.

    private static IReadOnlyList<string> FixAcm(List<string> lines, Counters c)
    {
        var  result = new List<string>(lines.Count);
        bool didFix = false;
        foreach (var l in lines)
        {
            var t = l.TrimStart();
            if (TryGetValue(t, "validation_method", out var v) && v == "\"NONE\"")
            { didFix = true; continue; }
            result.Add(l);
        }
        if (didFix) c.Acm++;
        return result;
    }

    // ── API Gateway ──────────────────────────────────────────────────────────
    // Drop endpoint_configuration block entirely when vpc_endpoint_ids = [].

    private static IReadOnlyList<string> FixApiGateway(List<string> lines, Counters c)
    {
        var  result    = new List<string>(lines.Count);
        bool didFix    = false;
        bool inEpCfg   = false;
        bool dropBlock = false;
        int  epDepth   = 0;
        var  epBuf     = new List<string>();

        foreach (var l in lines)
        {
            var t = l.TrimStart();

            if (!inEpCfg && Regex.IsMatch(t, @"^endpoint_configuration\s*\{"))
            {
                inEpCfg   = true;
                dropBlock = false;
                epDepth   = CountBraces(l);
                epBuf.Clear();
                epBuf.Add(l);
                continue;
            }

            if (inEpCfg)
            {
                epDepth += CountBraces(l);
                epBuf.Add(l);

                if (TryGetValue(t, "vpc_endpoint_ids", out var v) && v == "[]")
                    dropBlock = true;

                if (epDepth <= 0)
                {
                    inEpCfg = false;
                    if (!dropBlock) result.AddRange(epBuf);
                    else            didFix = true;
                    epBuf.Clear();
                }
                continue;
            }

            result.Add(l);
        }

        if (didFix) c.ApiGateway++;
        return result;
    }

    // ── IAM / Secrets name_prefix conflict ───────────────────────────────────
    // Terraform sometimes generates both `name` and `name_prefix`; remove `name_prefix`.

    private static IReadOnlyList<string> FixNameConflict(List<string> lines, Counters c)
    {
        bool hasName       = false;
        bool hasNamePrefix = false;
        foreach (var l in lines)
        {
            var attr = GetAttrName(l.TrimStart());
            if (attr == "name")        hasName       = true;
            if (attr == "name_prefix") hasNamePrefix = true;
        }

        if (!hasName || !hasNamePrefix) return lines;

        var  result = new List<string>(lines.Count);
        bool didFix = false;
        foreach (var l in lines)
        {
            if (GetAttrName(l.TrimStart()) == "name_prefix") { didFix = true; continue; }
            result.Add(l);
        }
        if (didFix) c.Iam++;
        return result;
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static string GetAttrName(string trimmed)
    {
        var m = Regex.Match(trimmed, @"^([\w]+)\s*=");
        return m.Success ? m.Groups[1].Value : string.Empty;
    }

    private static bool TryGetValue(string trimmed, string attrName, out string value)
    {
        var m = Regex.Match(trimmed, $@"^{Regex.Escape(attrName)}\s*=\s*(.+?)\s*$");
        if (m.Success) { value = m.Groups[1].Value.Trim(); return true; }
        value = string.Empty;
        return false;
    }

    private static bool IsRealValue(string? val) =>
        !string.IsNullOrEmpty(val) && val != "null" && val != "\"\"" && val != "\"null\"";

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

    private static int CountSquareBrackets(string line)
    {
        int  count    = 0;
        bool inString = false;
        foreach (char ch in line)
        {
            if (ch == '"') inString = !inString;
            if (inString) continue;
            if      (ch == '[') count++;
            else if (ch == ']') count--;
        }
        return count;
    }

    // ── Counters ──────────────────────────────────────────────────────────────

    private sealed class Counters
    {
        public int TagsAll, Lambda, Subnet, Vpc, RouteTable, DynamoDb, Acm, ApiGateway, Iam;

        public FixSummary ToSummary() =>
            new(TagsAll, Lambda, Subnet, Vpc, RouteTable, DynamoDb, Acm, ApiGateway, Iam);
    }
}
