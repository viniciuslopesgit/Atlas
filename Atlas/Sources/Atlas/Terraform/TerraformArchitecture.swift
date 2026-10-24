import Foundation

// MARK: - The whole stack

/// The stack with its local modules as one configuration: every resource and data source, with the blocks it really
/// uses. References are followed through module inputs, outputs and locals, so a node group that gets
/// `var.nodegroup_subnet_ids["a"]` uses `module.network`'s `aws_subnet.eks_new_private_1a`, not "a variable".
struct TerraformStack: Sendable {
    /// Addresses as Terraform writes them (`module.cluster.aws_eks_node_group.kong`); files relative to the stack's
    /// folder. Also holds the stack's inputs that name an existing network (`var.vpc_id`, `var.private_subnet_ids`).
    var graph: TerraformGraph
    /// Each block's module, as a path (`cluster`, `cluster/eks_cluster`); the stack's own blocks have none.
    var modules: [String: String]
    /// Plain values of a few attributes (zones, CIDR blocks, names), followed through variables to their defaults.
    var values: [String: [String: String]]
    /// The stack's region, from its `aws_region` or `region` input.
    var region: String?

    static let maxModuleDepth = 6
    static let valueAttributes = ["availability_zone", "cidr_block", "map_public_ip_on_launch", "name", "cluster_name"]

    static func load(root: URL) -> TerraformStack {
        let top = Scope.load(folder: root, root: root, prefix: "", path: "", parent: nil, call: nil, depth: 0, seen: [])
        var resolver = Resolver()
        var nodes: [TerraformGraph.Node] = []
        var modules: [String: String] = [:]
        var values: [String: [String: String]] = [:]
        var leaves = Set<String>()
        for scope in top.all {
            for n in scope.graph.nodes where n.kind == .resource || n.kind == .data {
                let id = scope.prefix + n.id
                let uses = resolver.resolve(n.body, in: scope, key: nil).subtracting([id])
                leaves.formUnion(uses.filter { $0.hasPrefix("var.") })
                var copy = TerraformGraph.Node(id: id, kind: n.kind, type: n.type, name: n.name,
                                               file: scope.relative.isEmpty ? n.file : scope.relative + "/" + n.file,
                                               line: n.line, source: n.source, moduleSource: nil, repeated: n.repeated,
                                               dependencies: uses.sorted())
                copy.defaultValue = n.defaultValue
                nodes.append(copy)
                if !scope.path.isEmpty { modules[id] = scope.path }
                let attributes = TerraformConfig.attributes(n.body)
                var found: [String: String] = [:]
                for name in valueAttributes {
                    if let expr = attributes[name], let value = resolver.literal(expr, in: scope, key: nil) { found[name] = value }
                }
                if !found.isEmpty { values[id] = found }
            }
        }
        // The stack's own inputs that the blocks end up using: an existing VPC or existing subnets.
        for n in top.graph.nodes where n.kind == .variable && leaves.contains(n.id) {
            var copy = n
            copy.body = ""
            nodes.append(copy)
            if let value = TerraformConfig.attributes(n.body)["default"].flatMap({ resolver.literal($0, in: top, key: nil) }) {
                values[n.id] = ["default": value]
            }
        }
        let region = ["aws_region", "region"].lazy.compactMap { top.byId["var.\($0)"] }.first
            .flatMap { TerraformConfig.attributes($0.body)["default"] }.flatMap { resolver.literal($0, in: top, key: nil) }
        return TerraformStack(graph: TerraformGraph(nodes: nodes), modules: modules, values: values, region: region)
    }
}

/// One folder of the stack: the stack's own or a module's, with the block that calls it.
private final class Scope {
    let prefix: String
    let path: String
    let relative: String
    let graph: TerraformGraph
    let byId: [String: TerraformGraph.Node]
    let call: TerraformGraph.Node?
    weak var parent: Scope?
    var children: [String: Scope] = [:]

    init(graph: TerraformGraph, prefix: String, path: String, relative: String, parent: Scope?, call: TerraformGraph.Node?) {
        self.graph = graph
        self.byId = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.prefix = prefix; self.path = path; self.relative = relative; self.parent = parent; self.call = call
    }

    static func load(folder: URL, root: URL, prefix: String, path: String, parent: Scope?, call: TerraformGraph.Node?,
                     depth: Int, seen: Set<String>) -> Scope {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let here = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let relative = here == base ? "" : String(here.dropFirst(base.count + 1))
        let scope = Scope(graph: TerraformConfig.graph(folder: folder), prefix: prefix, path: path, relative: relative,
                          parent: parent, call: call)
        guard depth < TerraformStack.maxModuleDepth else { return scope }
        for n in scope.graph.nodes where n.kind == .module {
            guard let source = n.moduleSource, let url = TerraformDocs.localModule(source, from: folder, root: root),
                  !seen.contains(url.path) else { continue }
            scope.children[n.name] = load(folder: url, root: root, prefix: prefix + "module.\(n.name).",
                                          path: path.isEmpty ? n.name : path + "/" + n.name, parent: scope, call: n,
                                          depth: depth + 1, seen: seen.union([here]))
        }
        return scope
    }

    /// This scope and every module under it.
    var all: [Scope] { [self] + children.keys.sorted().flatMap { children[$0]!.all } }
}

/// Follows references to the blocks behind them, and expressions to plain values.
private struct Resolver {
    private var memo: [String: Set<String>] = [:]
    private var depth = 0

    /// The resources, data sources and stack inputs an expression ends up using. `key` picks one entry of a map
    /// (`["a"]`) when the expression is one.
    mutating func resolve(_ text: String, in scope: Scope, key: String?) -> Set<String> {
        guard depth < 40 else { return [] }
        depth += 1
        defer { depth -= 1 }
        var expr = text
        var key = key
        if let k = key, let entry = TerraformConfig.entry(k, in: expr) { expr = entry; key = nil }
        var out = Set<String>()
        for ref in TerraformConfig.references(in: TerraformConfig.expressions(expr)) {
            if ref.hasPrefix("module.") {
                let name = String(ref.dropFirst("module.".count))
                guard let child = scope.children[name] else { continue }
                for (output, k) in Self.uses(of: "module.\(name).", in: expr, outputs: true) {
                    guard let o = child.byId["output.\(output)"] else { continue }
                    out.formUnion(cached("\(ObjectIdentifier(child))|output.\(output)|\(k ?? key ?? "")") {
                        $0.resolve(TerraformConfig.attributes(o.body)["value"] ?? o.body, in: child, key: k ?? key)
                    })
                }
            } else if ref.hasPrefix("var.") {
                let name = String(ref.dropFirst("var.".count))
                guard scope.byId[ref] != nil else { continue }
                guard let parent = scope.parent, let call = scope.call else { out.insert(ref); continue }
                guard let argument = TerraformConfig.attributes(call.body)[name] else { continue }
                for (_, k) in Self.uses(of: ref, in: expr, outputs: false) {
                    out.formUnion(cached("\(ObjectIdentifier(scope))|\(ref)|\(k ?? key ?? "")") {
                        $0.resolve(argument, in: parent, key: k ?? key)
                    })
                }
            } else if ref.hasPrefix("local.") {
                guard let local = scope.byId[ref] else { continue }
                for (_, k) in Self.uses(of: ref, in: expr, outputs: false) {
                    out.formUnion(cached("\(ObjectIdentifier(scope))|\(ref)|\(k ?? key ?? "")") {
                        $0.resolve(TerraformConfig.localValue(local.body), in: scope, key: k ?? key)
                    })
                }
            } else if scope.byId[ref] != nil {
                out.insert(scope.prefix + ref)
            }
        }
        return out
    }

    private mutating func cached(_ key: String, _ work: (inout Resolver) -> Set<String>) -> Set<String> {
        if let hit = memo[key] { return hit }
        memo[key] = [] // a reference that leads back to itself stops here
        let value = work(&self)
        memo[key] = value
        return value
    }

    /// Each use of `prefix` in `expr` with the map key it picks (`var.x["a"]` → `a`); for a module, each output used.
    static func uses(of prefix: String, in expr: String, outputs: Bool) -> [(String, String?)] {
        let escaped = NSRegularExpression.escapedPattern(for: prefix)
        let pattern = outputs ? escaped + #"([A-Za-z0-9_\-]+)(?:\["([^"]+)"\])?"# : escaped + #"(?![A-Za-z0-9_\-])()(?:\["([^"]+)"\])?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = expr as NSString
        var found: [(String, String?)] = []
        for m in re.matches(in: expr, range: NSRange(location: 0, length: ns.length)) {
            let name = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
            let key = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
            if !found.contains(where: { $0.0 == name && $0.1 == key }) { found.append((name, key)) }
        }
        return found.isEmpty ? [("", nil)] : found
    }

    /// A plain value: a string (with `${…}` filled in when it can be), or a variable followed to the argument or
    /// default that sets it.
    mutating func literal(_ text: String, in scope: Scope, key: String?) -> String? {
        guard depth < 40 else { return nil }
        depth += 1
        defer { depth -= 1 }
        var expr = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if expr.hasSuffix(",") { expr.removeLast() }
        if let key, let entry = TerraformConfig.entry(key, in: expr) { return literal(entry, in: scope, key: nil) }
        if let m = expr.wholeMatch(of: #/"((?:[^"\\]|\\.)*)"/#) {
            var value = String(m.1)
            for part in value.matches(of: #/\$\{([^}]+)\}/#).reversed() {
                guard let inner = literal(String(part.1), in: scope, key: nil) else { return nil }
                value.replaceSubrange(part.range, with: inner)
            }
            return value
        }
        if ["true", "false"].contains(expr) || expr.wholeMatch(of: #/-?[0-9.]+/#) != nil { return expr }
        if let m = expr.wholeMatch(of: #/var\.([A-Za-z0-9_\-]+)(?:\["([^"]+)"\])?/#) {
            let name = String(m.1), k = m.2.map(String.init) ?? key
            guard let variable = scope.byId["var.\(name)"] else { return nil }
            if let parent = scope.parent, let call = scope.call, let argument = TerraformConfig.attributes(call.body)[name] {
                return literal(argument, in: parent, key: k)
            }
            return TerraformConfig.attributes(variable.body)["default"].flatMap { literal($0, in: scope, key: k) }
        }
        if let m = expr.wholeMatch(of: #/local\.([A-Za-z0-9_\-]+)/#), let local = scope.byId["local.\(m.1)"] {
            return literal(TerraformConfig.localValue(local.body), in: scope, key: key)
        }
        return nil
    }
}

extension TerraformConfig {
    private static let attributeStart = try! NSRegularExpression(pattern: #"^\s*([A-Za-z_][A-Za-z0-9_\-]*)\s*="#)

    /// The first-level attributes of a block and the expression each is set to (comments left out).
    private static let blockStart = try! NSRegularExpression(pattern: #"^\s*[A-Za-z_][A-Za-z0-9_\-]*(\s+"[^"]*")*\s*\{"#)

    static func attributes(_ block: String) -> [String: String] {
        let scanned = scan(oneStatementPerLine(block))
        let lines = scanned.lines
        func matches(_ re: NSRegularExpression, _ i: Int) -> NSTextCheckingResult? {
            let ns = lines[i] as NSString
            return scanned.depths[i] == 1 ? re.firstMatch(in: lines[i], range: NSRange(location: 0, length: ns.length)) : nil
        }
        func name(_ i: Int) -> String? {
            matches(attributeStart, i).map { (lines[i] as NSString).substring(with: $0.range(at: 1)) }
        }
        // An attribute ends where the next attribute or nested block (`vpc_config {`) starts.
        let starts = lines.indices.filter { name($0) != nil || matches(blockStart, $0) != nil }
        var out: [String: String] = [:]
        for (k, start) in starts.enumerated() where name(start) != nil {
            let stop = k + 1 < starts.count ? starts[k + 1] : lines.count
            var text = lines[start..<stop].joined(separator: "\n")
            text = String(text[text.index(after: text.firstIndex(of: "=")!)...])
            // The block's own closing brace is not part of its last attribute.
            if k == starts.count - 1, stop == lines.count, let close = text.lastIndex(of: "}"),
               text[close...].trimmingCharacters(in: .whitespacesAndNewlines) == "}" { text = String(text[..<close]) }
            if out[name(start)!] == nil { out[name(start)!] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return out
    }

    /// `variable "x" { default = "y" }` written on one line, opened onto several so its attribute is on a line of
    /// its own.
    static func oneStatementPerLine(_ block: String) -> String {
        let block = unixLines(block)
        let first = block.prefix { $0 != "\n" }
        let code = scan(String(first)).lines.first ?? ""
        guard let open = code.firstIndex(of: "{") else { return block }
        let offset = code.distance(from: code.startIndex, to: open)
        let head = first.prefix(offset + 1)
        var rest = String(first.dropFirst(offset + 1))
        guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return block }
        let tail = block.dropFirst(first.count)
        if tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let close = rest.lastIndex(of: "}") {
            rest = String(rest[..<close]) + "\n}"
        }
        return head + "\n" + rest + tail
    }

    /// The expression a `local` is set to.
    static func localValue(_ body: String) -> String {
        guard let eq = body.firstIndex(of: "=") else { return body }
        return String(body[body.index(after: eq)...])
    }

    /// One entry of a map written in place: `a = aws_subnet.x.id` for key `a`.
    static func entry(_ key: String, in expr: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let re = try? NSRegularExpression(pattern: #"(?m)^\s*"?"# + escaped + #""?\s*[=:]\s*(.+?)\s*,?\s*$"#) else { return nil }
        let ns = expr as NSString
        guard let m = re.firstMatch(in: expr, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}

// MARK: - Where things live in AWS

/// The stack drawn the way AWS is organised: global services, then the region with its regional services, the VPC,
/// its availability zones with their public and private subnets, and what runs in each; the EKS cluster with its
/// Kubernetes resources; other providers outside AWS. Small blocks that only attach one thing to another (policy
/// attachments, route table associations, bucket settings) are folded into the block they attach to.
struct TerraformArchitecture: Sendable, Equatable {
    enum Kind: String, Sendable {
        case group, cloud, global, region, services, vpc, zone, publicSubnet, privateSubnet, subnet, spread, existing, cluster, outside
    }

    struct Box: Sendable, Equatable {
        var id: String
        var kind: Kind
        var title: String
        var subtitle = ""
        /// The block the box stands for: a VPC, a subnet, a cluster.
        var node: String?
        var cards: [String] = []
        var children: [Box] = []
        /// Children side by side (zones) instead of one under the other.
        var isRow = false

        var isEmpty: Bool { cards.isEmpty && children.allSatisfy(\.isEmpty) && node == nil }
    }

    let graph: TerraformGraph
    let modules: [String: String]
    let root: Box
    /// Blocks folded into a card or a box.
    let folded: [String: [String]]
    /// Where each folded block went.
    let foldedInto: [String: String]

    static let globalPrefixes = ["aws_iam_", "aws_route53_", "aws_cloudfront_", "aws_organizations_", "aws_budgets_", "aws_shield_",
                                 "aws_globalaccelerator_", "aws_caller_identity", "aws_partition"]
    static let vpcPrefixes = ["aws_security_group", "aws_route_table", "aws_route", "aws_internet_gateway", "aws_egress_only_internet_gateway",
                              "aws_vpc_", "aws_network_acl", "aws_ec2_traffic_mirror", "aws_flow_log", "aws_vpn_gateway",
                              "aws_customer_gateway", "aws_lb_target_group", "aws_service_discovery_private_dns_namespace"]
    static let clusterProviders: Set<String> = ["kubernetes", "helm", "kubectl"]

    /// Blocks that only connect or configure another one.
    static func isAttachment(_ type: String) -> Bool {
        type.hasSuffix("_attachment") || type.hasSuffix("_association") || type.hasPrefix("aws_s3_bucket_")
            || ["aws_iam_role_policy", "aws_iam_instance_profile", "aws_security_group_rule", "aws_vpc_security_group_ingress_rule",
                "aws_vpc_security_group_egress_rule", "aws_ec2_traffic_mirror_filter_rule", "aws_route"].contains(type)
    }

    /// An input that names existing subnets: `private_subnet_ids`, `subnet_id`, `public_subnets`.
    static func namesSubnets(_ name: String) -> Bool {
        name.contains("subnet") && (name.contains("_id") || name.hasSuffix("subnets"))
    }

    static func provider(_ type: String) -> String { type.split(separator: "_").first.map(String.init) ?? type }

    init(_ stack: TerraformStack, showData: Bool = true) {
        let graph = stack.graph
        self.graph = graph
        self.modules = stack.modules
        let byId = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let values = stack.values

        // The network: VPCs, subnets (created here or read), the inputs naming existing ones.
        let vpcs = graph.nodes.filter(\.isNetworkRoot).map(\.id)
        let subnets = graph.nodes.filter { $0.kind != .variable && $0.type == "aws_subnet" }.map(\.id)
        let existing = graph.nodes.filter { $0.kind == .variable && !$0.isNetworkRoot && Self.namesSubnets($0.name) }.map(\.id)
        let clusters = graph.nodes.filter { $0.kind == .resource && $0.type == "aws_eks_cluster" }.map(\.id)

        // Attachments fold into the block they attach to: the one whose type they share most of their name with.
        var folded: [String: [String]] = [:], foldedInto: [String: String] = [:]
        for n in graph.nodes where n.kind == .resource && Self.isAttachment(n.type) {
            let targets = n.dependencies.compactMap { byId[$0] }.filter { $0.kind == .resource && !Self.isAttachment($0.type) }
            guard let target = targets.max(by: { (Self.shared($0.type, n.type), $1.id) < (Self.shared($1.type, n.type), $0.id) }) else { continue }
            folded[target.id, default: []].append(n.id)
            foldedInto[n.id] = target.id
        }
        self.folded = folded
        self.foldedInto = foldedInto

        func vpc(of id: String, seen: Set<String> = []) -> String? {
            guard let n = byId[id], !seen.contains(id) else { return nil }
            if let v = n.dependencies.first(where: { vpcs.contains($0) }) { return v }
            for d in n.dependencies where subnets.contains(d) || clusters.contains(d) || byId[d]?.type == "aws_security_group" {
                if let v = vpc(of: d, seen: seen.union([id])) { return v }
            }
            return nil
        }
        let defaultVpc = vpcs.first ?? "vpc"
        func tier(_ id: String) -> Kind {
            let n = byId[id]
            let text = (id + " " + (values[id]?["name"] ?? "")).lowercased()
            if values[id]?["map_public_ip_on_launch"] == "true" || text.contains("public") { return .publicSubnet }
            if text.contains("private") || n?.kind == .variable { return .privateSubnet }
            return .subnet
        }
        func zone(_ id: String) -> String {
            guard let az = values[id]?["availability_zone"] else { return "" }
            return az
        }

        // Where each card goes.
        enum Place: Hashable { case global, region, vpc(String), subnet(String), spread(String, Kind), existing(String), cluster(String), outside }
        var places: [Place: [String]] = [:]
        let boxNodes = Set(vpcs + subnets + clusters + existing)
        for n in graph.nodes where (n.kind == .resource || (n.kind == .data && showData)) && foldedInto[n.id] == nil && !boxNodes.contains(n.id) {
            let provider = Self.provider(n.type)
            let place: Place
            if Self.clusterProviders.contains(provider) || (n.type.hasPrefix("aws_eks_") && n.type != "aws_eks_node_group") {
                place = .cluster(n.dependencies.first { clusters.contains($0) } ?? clusters.first ?? "kubernetes")
            } else if provider != "aws" {
                place = .outside
            } else if case let used = n.dependencies.filter({ subnets.contains($0) }), !used.isEmpty {
                if used.count == 1 { place = .subnet(used[0]) } else {
                    let tiers = Set(used.map(tier))
                    place = .spread(vpc(of: used[0]) ?? defaultVpc, tiers.count == 1 ? tiers.first! : .subnet)
                }
            } else if let e = n.dependencies.first(where: { existing.contains($0) }) {
                place = .existing(e)
            } else if Self.globalPrefixes.contains(where: { n.type.hasPrefix($0) }) || n.type == "aws_iam_policy_document" {
                place = .global
            } else if let v = vpc(of: n.id) ?? (Self.vpcPrefixes.contains(where: { n.type.hasPrefix($0) }) ? defaultVpc : nil) {
                place = .vpc(v)
            } else {
                place = .region
            }
            places[place, default: []].append(n.id)
        }
        func cards(_ place: Place) -> [String] {
            (places[place] ?? []).sorted { (byId[$0]!.type, byId[$0]!.name, $0) < (byId[$1]!.type, byId[$1]!.name, $1) }
        }

        // The boxes, from the inside out.
        let region = stack.region
        func clusterBox(_ id: String) -> Box {
            let name = values[id]?["name"] ?? byId[id]?.name ?? "Kubernetes"
            return Box(id: "cluster:\(id)", kind: .cluster, title: byId[id] == nil ? "Kubernetes" : "EKS cluster", subtitle: name,
                       node: byId[id] == nil ? nil : id, cards: cards(.cluster(id)))
        }
        let clusterIds = (clusters + places.keys.compactMap { if case .cluster(let c) = $0, !clusters.contains(c) { c } else { nil } }).uniqued()
        let clusterVpc = Dictionary(clusterIds.map { ($0, vpc(of: $0) ?? (vpcs.count <= 1 ? defaultVpc : nil)) }, uniquingKeysWith: { a, _ in a })
        let spreadKeys = places.keys.compactMap { if case let .spread(v, t) = $0 { (v, t) } else { nil } }
        let existingIds = places.keys.compactMap { if case .existing(let e) = $0 { e } else { nil } }.sorted()
        var vpcIds = vpcs
        if vpcIds.isEmpty && (!subnets.isEmpty || !spreadKeys.isEmpty || places.keys.contains(where: { if case .vpc = $0 { true } else { false } })) {
            vpcIds = ["vpc"]
        }

        func vpcBox(_ v: String) -> Box {
            let own = subnets.filter { (vpc(of: $0) ?? defaultVpc) == v }
            let zones = Dictionary(grouping: own, by: zone)
            let zoneBoxes = zones.keys.sorted().map { z -> Box in
                let inZone = zones[z]!.sorted { (tier($0) == .publicSubnet ? 0 : tier($0) == .privateSubnet ? 1 : 2, $0) < (tier($1) == .publicSubnet ? 0 : tier($1) == .privateSubnet ? 1 : 2, $1) }
                return Box(id: "zone:\(v):\(z)", kind: .zone, title: z.isEmpty ? "Zone not set" : "Availability Zone",
                           subtitle: z, children: inZone.map { s in
                               let k = tier(s)
                               let detail = [values[s]?["cidr_block"], byId[s]?.name].compactMap { $0 }.joined(separator: " · ")
                               return Box(id: "subnet:\(s)", kind: k, title: k == .publicSubnet ? "Public subnet" : k == .privateSubnet ? "Private subnet" : "Subnet",
                                          subtitle: detail, node: s, cards: cards(.subnet(s)))
                           })
            }
            var children: [Box] = []
            if !zoneBoxes.isEmpty { children.append(Box(id: "zones:\(v)", kind: .group, title: "", children: zoneBoxes, isRow: true)) }
            for (_, t) in spreadKeys.filter({ $0.0 == v }).sorted(by: { $0.1.rawValue < $1.1.rawValue }) {
                let zonesUsed = Set(places[.spread(v, t)]!.flatMap { id in byId[id]!.dependencies.filter { subnets.contains($0) }.map(zone) })
                    .filter { !$0.isEmpty }.sorted()
                children.append(Box(id: "spread:\(v):\(t.rawValue)", kind: .spread,
                                    title: t == .publicSubnet ? "Across the public subnets" : t == .privateSubnet ? "Across the private subnets" : "Across several subnets",
                                    subtitle: zonesUsed.joined(separator: ", "), cards: cards(.spread(v, t))))
            }
            if v == defaultVpc {
                for e in existingIds {
                    children.append(Box(id: "existing:\(e)", kind: .existing,
                                        title: tier(e) == .publicSubnet ? "Existing public subnets" : "Existing subnets",
                                        subtitle: e, node: e, cards: cards(.existing(e))))
                }
            }
            children += clusterIds.filter { clusterVpc[$0] == v }.map(clusterBox)
            let n = byId[v]
            let detail = n.map { node -> String in
                node.kind == .variable ? "existing · " + (values[v]?["default"] ?? node.id) : [values[v]?["cidr_block"], node.name].compactMap { $0 }.joined(separator: " · ")
            } ?? ""
            return Box(id: "vpc:\(v)", kind: .vpc, title: "VPC", subtitle: detail, node: n == nil ? nil : v,
                       cards: cards(.vpc(v)), children: children)
        }

        var regionChildren: [Box] = []
        let regional = cards(.region)
        if !regional.isEmpty { regionChildren.append(Box(id: "services", kind: .services, title: "Regional services", cards: regional)) }
        regionChildren += vpcIds.map(vpcBox)
        regionChildren += clusterIds.filter { id in (clusterVpc[id] ?? nil).map { !vpcIds.contains($0) } ?? true }.map(clusterBox)
        // The region first, global services beside it.
        var cloud = [Box(id: "region", kind: .region, title: "Region", subtitle: region ?? "", children: regionChildren)]
        let global = cards(.global)
        if !global.isEmpty { cloud.append(Box(id: "global", kind: .global, title: "Global services", subtitle: "Not tied to a region", cards: global)) }
        var top = [Box(id: "cloud", kind: .cloud, title: "AWS Cloud", children: cloud, isRow: true)]
        let outside = cards(.outside)
        if !outside.isEmpty { top.append(Box(id: "outside", kind: .outside, title: "Outside AWS", subtitle: "Other Terraform providers", cards: outside)) }
        func prune(_ b: Box) -> Box? {
            var b = b
            b.children = b.children.compactMap(prune)
            return b.isEmpty && b.kind != .region ? nil : b
        }
        root = prune(Box(id: "root", kind: .group, title: "", children: top))!
    }

    /// How many leading characters two types share.
    static func shared(_ a: String, _ b: String) -> Int { zip(a, b).prefix { $0 == $1 }.count }

    /// Every box, outside first.
    var boxes: [Box] {
        func walk(_ b: Box) -> [Box] { [b] + b.children.flatMap(walk) }
        return walk(root)
    }

    /// Every card, in the order drawn.
    var cards: [String] { boxes.flatMap(\.cards) }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
