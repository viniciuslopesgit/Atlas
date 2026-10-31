import Foundation

/// Line-level helpers shared by the passes over `terraform plan -generate-config-out` output.
enum HclLine {
    /// `name` from `name = value`, or "" when the line is not an attribute.
    static func attrName(_ trimmed: String) -> String {
        guard let m = trimmed.firstMatch(#"^(\w+)\s*="#) else { return "" }
        return String(m[1])
    }

    /// The value of `attr = value` (trimmed), or nil when the line sets another attribute.
    static func value(_ trimmed: String, _ attr: String) -> String? {
        guard attrName(trimmed) == attr, let eq = trimmed.firstIndex(of: "=") else { return nil }
        let v = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    static func isReal(_ v: String?) -> Bool {
        guard let v, !v.isEmpty else { return false }
        return !["null", "\"\"", "\"null\""].contains(v)
    }

    /// Net `open - close` count outside double-quoted strings (escaped quotes respected).
    static func depth(_ line: String, open: Character = "{", close: Character = "}") -> Int {
        var count = 0, inString = false, escaped = false
        for ch in line {
            if escaped { escaped = false; continue }
            if ch == "\\" && inString { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == open { count += 1 } else if ch == close { count -= 1 }
        }
        return count
    }

    static func indent(_ line: String) -> Int { line.count - line.drop(while: { $0 == " " }).count }

    static func trimmedStart(_ line: String) -> String { String(line.drop(while: { $0 == " " || $0 == "\t" })) }

    /// The type of `resource "<type>" "<name>" {`, or nil.
    static func resourceType(_ trimmed: String) -> String? {
        guard let m = trimmed.firstMatch(#"^resource\s+"([^"]+)""#) else { return nil }
        return String(m[1])
    }

    /// Splits a file into top-level resource blocks and the text between them.
    /// Returns segments in order; resource segments carry their type.
    static func segments(_ content: String) -> [(type: String?, lines: [String])] {
        var out: [(type: String?, lines: [String])] = []
        var other: [String] = []
        var block: [String] = []
        var type: String?
        var d = 0
        for line in content.components(separatedBy: "\n") {
            let t = trimmedStart(line)
            if type == nil {
                if let rt = resourceType(t) {
                    if !other.isEmpty { out.append((nil, other)); other = [] }
                    type = rt
                    d = depth(line)
                    block = [line]
                    if d <= 0 { out.append((rt, block)); block = []; type = nil }
                } else {
                    other.append(line)
                }
                continue
            }
            d += depth(line)
            block.append(line)
            if d <= 0 { out.append((type, block)); block = []; type = nil }
        }
        if !other.isEmpty { out.append((nil, other)) }
        if !block.isEmpty { out.append((nil, block)) }
        return out
    }
}

/// Fixes the invalid attribute patterns that `terraform plan -generate-config-out` emits
/// (rules ported from Atlas 1.0.1's GeneratedHclFixer).
enum GeneratedHclFixer {
    struct Summary: Equatable {
        var tagsAll = 0, lambda = 0, subnet = 0, vpc = 0, routeTable = 0, dynamoDb = 0, acm = 0, apiGateway = 0, iam = 0
        var total: Int { tagsAll + lambda + subnet + vpc + routeTable + dynamoDb + acm + apiGateway + iam }

        var lines: [String] {
            [(tagsAll, "tags_all removed (provider-managed)"),
             (lambda, "lambda zip package placeholder + lifecycle applied"),
             (subnet, "subnet attribute conflicts resolved"),
             (vpc, "vpc orphaned ipv6 attributes removed"),
             (routeTable, "route table sanitized (list→block, empty attrs stripped)"),
             (dynamoDb, "dynamodb invalid recovery block removed"),
             (acm, "acm validation_method=NONE removed"),
             (apiGateway, "api gateway empty vpc_endpoint_ids fixed"),
             (iam, "iam/secrets name_prefix conflicts resolved")]
                .filter { $0.0 > 0 }.map { "    \($0.1): \($0.0)" }
        }
    }

    /// Placeholder deployment package for imported Zip Lambdas: terraform must hash a real file on plan.
    static let lambdaPlaceholderFile = "lambda_placeholder.zip"
    static let lambdaIgnoredChanges = ["filename", "source_code_hash", "last_modified", "publish"]
    /// An empty zip: one End-Of-Central-Directory record.
    static let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))

    /// Fixes the file in place; writes the placeholder zip next to it when a Lambda needs it.
    @discardableResult
    static func fix(file: URL) throws -> Summary {
        guard let original = try? String(contentsOf: file, encoding: .utf8) else { return Summary() }
        let (result, summary) = fix(original)
        if summary.total > 0 {
            try Data(result.utf8).write(to: file, options: .atomic)
            let zip = file.deletingLastPathComponent().appendingPathComponent(lambdaPlaceholderFile)
            if result.contains(lambdaPlaceholderFile), !FileManager.default.fileExists(atPath: zip.path) {
                try emptyZip.write(to: zip)
            }
        }
        return summary
    }

    static func fix(_ content: String) -> (String, Summary) {
        var s = Summary()
        var out: [String] = []
        for seg in HclLine.segments(content) {
            guard let type = seg.type else { out += seg.lines; continue }
            let stripped = stripTagsAll(seg.lines, &s)
            switch type {
            case "aws_lambda_function": out += lambda(stripped, &s)
            case "aws_subnet": out += drop(stripped, ["availability_zone_id", "enable_lni_at_device_index",
                                                      "map_customer_owned_ip_on_launch"], &s.subnet)
            case "aws_vpc": out += vpc(stripped, &s)
            case "aws_route_table": out += routeTable(stripped, &s)
            case "aws_dynamodb_table":
                out += dropNestedBlock(stripped, named: "point_in_time_recovery", &s.dynamoDb) { t in
                    guard let v = HclLine.value(t, "recovery_period_in_days") else { return false }
                    return v == "0" || !HclLine.isReal(v)
                }
            case "aws_acm_certificate":
                out += dropLines(stripped, &s.acm) { HclLine.value($0, "validation_method") == "\"NONE\"" }
            case "aws_api_gateway_rest_api":
                out += dropNestedBlock(stripped, named: "endpoint_configuration", &s.apiGateway) {
                    HclLine.value($0, "vpc_endpoint_ids") == "[]"
                }
            case "aws_iam_role", "aws_iam_policy", "aws_iam_user", "aws_secretsmanager_secret":
                out += nameConflict(stripped, &s)
            default: out += stripped
            }
        }
        return (out.joined(separator: "\n"), s)
    }

    /// Removes `tags_all = {…}` (single- or multi-line): it is computed by the provider.
    private static func stripTagsAll(_ lines: [String], _ s: inout Summary) -> [String] {
        var out: [String] = []
        var inBlock = false, d = 0
        for l in lines {
            let t = HclLine.trimmedStart(l)
            if !inBlock, t.firstMatch(#"^tags_all\s*=\s*\{"#) != nil {
                let x = HclLine.depth(l)
                if x <= 0 { s.tagsAll += 1 } else { inBlock = true; d = x }
                continue
            }
            if inBlock {
                d += HclLine.depth(l)
                if d <= 0 { inBlock = false; s.tagsAll += 1 }
                continue
            }
            out.append(l)
        }
        return out
    }

    private static func dropLines(_ lines: [String], _ counter: inout Int, where predicate: (String) -> Bool) -> [String] {
        let out = lines.filter { !predicate(HclLine.trimmedStart($0)) }
        if out.count != lines.count { counter += 1 }
        return out
    }

    private static func drop(_ lines: [String], _ attrs: Set<String>, _ counter: inout Int) -> [String] {
        dropLines(lines, &counter) { attrs.contains(HclLine.attrName($0)) }
    }

    /// Drops a nested `name { … }` block when any of its lines matches `when`.
    private static func dropNestedBlock(_ lines: [String], named name: String, _ counter: inout Int,
                                        when predicate: (String) -> Bool) -> [String] {
        var out: [String] = [], buf: [String] = []
        var inside = false, dropIt = false, d = 0, fixed = false
        for l in lines {
            let t = HclLine.trimmedStart(l)
            if !inside, t.hasPrefix(name), t.dropFirst(name.count).trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                inside = true; dropIt = false; d = HclLine.depth(l); buf = [l]
                if d <= 0 { inside = false; out += buf }
                continue
            }
            if inside {
                d += HclLine.depth(l)
                buf.append(l)
                if predicate(t) { dropIt = true }
                if d <= 0 {
                    inside = false
                    if dropIt { fixed = true } else { out += buf }
                }
                continue
            }
            out.append(l)
        }
        if fixed { counter += 1 }
        return out
    }

    /// Image functions stay as generated; Zip functions point at the placeholder and ignore the package.
    private static func lambda(_ lines: [String], _ s: inout Summary) -> [String] {
        var imageUri: String?, s3Bucket: String?, filename: String?
        for l in lines {
            let t = HclLine.trimmedStart(l)
            if let v = HclLine.value(t, "image_uri") { imageUri = v }
            if let v = HclLine.value(t, "s3_bucket") { s3Bucket = v }
            if let v = HclLine.value(t, "filename") { filename = v }
        }
        if HclLine.isReal(imageUri) {
            if filename == nil && s3Bucket == nil { return lines }
            return drop(lines, ["filename", "s3_bucket", "s3_key", "s3_object_version"], &s.lambda)
        }
        let keepS3 = HclLine.isReal(s3Bucket)
        let hasLifecycle = lines.contains { HclLine.trimmedStart($0).hasPrefix("lifecycle") }
        var out: [String] = []
        var fixed = false, filenameWritten = false
        for l in lines {
            let t = HclLine.trimmedStart(l)
            let attr = HclLine.attrName(t)
            if attr == "publish" { fixed = true; continue }
            if keepS3 {
                if attr == "image_uri" || attr == "filename" { fixed = true; continue }
            } else {
                if ["image_uri", "s3_bucket", "s3_key", "s3_object_version"].contains(attr) { fixed = true; continue }
                if attr == "filename" {
                    let desired = String(repeating: " ", count: HclLine.indent(l)) + "filename = \"\(lambdaPlaceholderFile)\""
                    if l.trimmingTrailingWhitespace() != desired { fixed = true }
                    out.append(desired)
                    filenameWritten = true
                    continue
                }
            }
            if t.hasPrefix("}") && HclLine.indent(l) == 0 {
                if !keepS3 && !filenameWritten {
                    out.append("  filename = \"\(lambdaPlaceholderFile)\"")
                    filenameWritten = true
                    fixed = true
                }
                if !hasLifecycle {
                    out += ["  lifecycle {", "    ignore_changes = [\(lambdaIgnoredChanges.joined(separator: ", "))]", "  }"]
                    fixed = true
                }
            }
            out.append(l)
        }
        if fixed { s.lambda += 1 }
        return out
    }

    /// `ipv6_netmask_length` needs `ipv6_ipam_pool_id`; both go when there is no pool.
    private static func vpc(_ lines: [String], _ s: inout Summary) -> [String] {
        let pool = lines.compactMap { HclLine.value(HclLine.trimmedStart($0), "ipv6_ipam_pool_id") }.last
        guard !HclLine.isReal(pool) else { return lines }
        return drop(lines, ["ipv6_netmask_length", "ipv6_ipam_pool_id"], &s.vpc)
    }

    /// Keeps only routes with a destination, strips empty attributes and turns `route = [{…}]` into blocks.
    private static func routeTable(_ lines: [String], _ s: inout Summary) -> [String] {
        var out: [String] = []
        var fixed = false
        var inBlock = false, bd = 0, hasDest = false
        var blockBuf: [String] = []
        var inList = false, ld = 0
        var listBuf: [String] = []
        for l in lines {
            let t = HclLine.trimmedStart(l)
            if !inBlock && !inList, t.firstMatch(#"^route\s*\{"#) != nil {
                inBlock = true; bd = HclLine.depth(l); hasDest = false; blockBuf = [l]
                continue
            }
            if inBlock {
                bd += HclLine.depth(l)
                if HclLine.isReal(HclLine.value(t, "cidr_block")) || HclLine.isReal(HclLine.value(t, "ipv6_cidr_block")) {
                    hasDest = true
                }
                blockBuf.append(l)
                if bd <= 0 {
                    inBlock = false
                    if hasDest {
                        for bl in blockBuf {
                            let bt = HclLine.trimmedStart(bl)
                            let a = HclLine.attrName(bt)
                            if !a.isEmpty, let v = HclLine.value(bt, a), !HclLine.isReal(v) { fixed = true; continue }
                            if !a.isEmpty, HclLine.value(bt, a) == nil { fixed = true; continue }
                            out.append(bl)
                        }
                    } else {
                        fixed = true
                    }
                }
                continue
            }
            if !inList, t.firstMatch(#"^route\s*=\s*\["#) != nil {
                ld = HclLine.depth(l, open: "[", close: "]")
                listBuf = [l]
                if ld <= 0 { fixed = true } else { inList = true }
                continue
            }
            if inList {
                ld += HclLine.depth(l, open: "[", close: "]")
                listBuf.append(l)
                if ld <= 0 {
                    inList = false
                    out += routeListToBlocks(listBuf)
                    fixed = true
                }
                continue
            }
            out.append(l)
        }
        if fixed { s.routeTable += 1 }
        return out
    }

    private static func routeListToBlocks(_ raw: [String]) -> [String] {
        // One structural token per line: "route = [{" / "}, {" / "}]" are split.
        var lines: [String] = []
        for l in raw {
            let t = HclLine.trimmedStart(l)
            let pad = String(repeating: " ", count: HclLine.indent(l))
            if t.firstMatch(#"\[\s*\{"#) != nil, let brace = l.lastIndex(of: "{") {
                lines.append(String(l[..<brace]).trimmingTrailingWhitespace())
                lines.append(pad + "{")
            } else if t.firstMatch(#"^\}\s*,\s*\{"#) != nil {
                lines += [pad + "},", pad + "{"]
            } else if t.firstMatch(#"^\}\s*\]"#) != nil, let bracket = l.firstIndex(of: "]") {
                lines += [pad + "}", pad + String(l[bracket...])]
            } else {
                lines.append(l)
            }
        }
        let base = String(repeating: " ", count: raw.first.map(HclLine.indent) ?? 2)
        let attrIndent = base + "  "
        var out: [String] = []
        var inObj = false, d = 0
        var attrs: [(String, String)] = []
        var hasDest = false
        for l in lines {
            let t = HclLine.trimmedStart(l)
            if !inObj {
                if t == "{" { inObj = true; d = 1; attrs = []; hasDest = false }
                continue
            }
            d += HclLine.depth(l)
            if d <= 0 {
                inObj = false
                if hasDest && !attrs.isEmpty {
                    out += [""] + ["\(base)route {"] + attrs.map { "\(attrIndent)\($0.0) = \($0.1)" } + ["\(base)}"]
                }
                continue
            }
            let a = HclLine.attrName(t)
            guard !a.isEmpty, let v = HclLine.value(t, a) else { continue }
            if (a == "cidr_block" || a == "ipv6_cidr_block") && HclLine.isReal(v) { hasDest = true }
            let cleaned = v.hasSuffix(",") ? String(v.dropLast()).trimmingCharacters(in: .whitespaces) : v
            if HclLine.isReal(cleaned) { attrs.append((a, cleaned)) }
        }
        return out
    }

    /// Generated IAM/Secrets resources sometimes set both `name` and `name_prefix`; keep `name`.
    private static func nameConflict(_ lines: [String], _ s: inout Summary) -> [String] {
        let attrs = Set(lines.map { HclLine.attrName(HclLine.trimmedStart($0)) })
        guard attrs.contains("name"), attrs.contains("name_prefix") else { return lines }
        return drop(lines, ["name_prefix"], &s.iam)
    }
}

/// Splits `generated_resources.tf` into one file per AWS service (ec2.tf, vpc.tf, iam.tf, …).
enum GeneratedHclSplitter {
    /// Splits the file in place (appending to existing service files) and deletes it.
    /// Returns (file name, resource count) sorted by file name.
    static func split(file: URL) throws -> [(file: String, count: Int)] {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let groups = split(content)
        guard !groups.isEmpty else { return [] }
        let dir = file.deletingLastPathComponent()
        var written: [(file: String, count: Int)] = []
        for name in groups.keys.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let target = dir.appendingPathComponent(name)
            var text = (try? String(contentsOf: target, encoding: .utf8)).map { $0.trimmingTrailingWhitespace() + "\n" } ?? ""
            for block in groups[name]! { text += "\n" + block.trimmingTrailingWhitespace() + "\n" }
            try Data(text.utf8).write(to: target, options: .atomic)
            written.append((name, groups[name]!.count))
        }
        try FileManager.default.removeItem(at: file)
        return written
    }

    /// file name → resource blocks (each with its preceding `#` comments).
    static func split(_ content: String) -> [String: [String]] {
        var groups: [String: [String]] = [:]
        var comments: [String] = []
        for seg in HclLine.segments(content) {
            if let type = seg.type {
                groups[fileName(for: type), default: []].append((comments + seg.lines).joined(separator: "\n"))
                comments = []
            } else {
                // Comments right before a resource belong to it; anything else resets them.
                comments = []
                for l in seg.lines {
                    if HclLine.trimmedStart(l).hasPrefix("#") { comments.append(l) } else { comments = [] }
                }
            }
        }
        return groups
    }

    private static let ec2: Set<String> = [
        "aws_instance", "aws_launch_template", "aws_launch_configuration", "aws_autoscaling_group",
        "aws_autoscaling_policy", "aws_autoscaling_schedule", "aws_autoscaling_attachment", "aws_key_pair", "aws_ami",
        "aws_ami_copy", "aws_ebs_volume", "aws_ebs_snapshot", "aws_volume_attachment", "aws_eip", "aws_eip_association",
        "aws_placement_group", "aws_spot_instance_request"]
    private static let vpc: Set<String> = [
        "aws_vpc", "aws_subnet", "aws_route_table", "aws_route", "aws_route_table_association",
        "aws_main_route_table_association", "aws_internet_gateway", "aws_egress_only_internet_gateway", "aws_nat_gateway",
        "aws_network_acl", "aws_network_acl_rule", "aws_network_acl_association", "aws_network_interface",
        "aws_network_interface_attachment", "aws_dhcp_options", "aws_vpc_dhcp_options_association", "aws_flow_log",
        "aws_customer_gateway", "aws_vpn_gateway", "aws_vpn_connection", "aws_vpn_gateway_attachment",
        "aws_default_route_table", "aws_default_network_acl", "aws_default_vpc", "aws_default_subnet", "aws_vpc_endpoint",
        "aws_vpc_endpoint_route_table_association", "aws_vpc_peering_connection", "aws_vpc_ipv4_cidr_block_association"]
    private static let securityGroups: Set<String> = [
        "aws_security_group", "aws_security_group_rule", "aws_default_security_group",
        "aws_vpc_security_group_ingress_rule", "aws_vpc_security_group_egress_rule"]
    private static let elb: Set<String> = [
        "aws_lb", "aws_lb_listener", "aws_lb_listener_rule", "aws_lb_listener_certificate", "aws_lb_target_group",
        "aws_lb_target_group_attachment", "aws_alb", "aws_alb_listener", "aws_alb_listener_rule", "aws_alb_target_group",
        "aws_alb_target_group_attachment", "aws_elb", "aws_elb_attachment", "aws_app_cookie_stickiness_policy",
        "aws_lb_cookie_stickiness_policy"]
    private static let rds: Set<String> = [
        "aws_db_instance", "aws_db_subnet_group", "aws_db_parameter_group", "aws_db_option_group", "aws_db_snapshot",
        "aws_db_event_subscription", "aws_db_proxy", "aws_db_proxy_default_target_group", "aws_db_proxy_target",
        "aws_rds_cluster", "aws_rds_cluster_instance", "aws_rds_cluster_parameter_group", "aws_rds_cluster_endpoint",
        "aws_rds_global_cluster"]

    static func fileName(for type: String) -> String {
        if ec2.contains(type) { return "ec2.tf" }
        if vpc.contains(type) { return "vpc.tf" }
        if securityGroups.contains(type) { return "security_groups.tf" }
        if elb.contains(type) { return "elb.tf" }
        if rds.contains(type) { return "rds.tf" }
        if type.hasPrefix("aws_api_gateway_") || type.hasPrefix("aws_apigatewayv2_") { return "apigateway.tf" }
        guard type.hasPrefix("aws_") else { return "misc.tf" }
        let service = type.dropFirst(4).split(separator: "_").first.map(String.init) ?? ""
        return service.isEmpty ? "misc.tf" : "\(service).tf"
    }
}
