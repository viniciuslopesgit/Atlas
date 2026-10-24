import Foundation

/// The blocks of a Terraform configuration folder (resources, data sources, modules, variables, locals, outputs) and
/// the references between them, read from its `.tf` files without running the engine. Drawn as the stack's diagram.
struct TerraformGraph: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable, Comparable {
        case variable, local, data, module, resource, output

        static func < (a: Kind, b: Kind) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

        var title: String {
            switch self {
            case .variable: "Variables"
            case .local: "Locals"
            case .data: "Data sources"
            case .module: "Modules"
            case .resource: "Resources"
            case .output: "Outputs"
            }
        }
    }

    struct Node: Identifiable, Sendable, Equatable, Hashable {
        /// The address Terraform uses: `aws_vpc.main`, `data.aws_ami.ubuntu`, `module.network`, `var.region`,
        /// `local.tags`, `output.vpc_id`.
        let id: String
        let kind: Kind
        /// The resource or data source type (`aws_vpc`); empty for other kinds.
        let type: String
        let name: String
        let file: String
        let line: Int
        /// The block as written, for the inspector.
        var source: String
        /// A module's `source`.
        var moduleSource: String?
        /// `count` or `for_each`, when the block makes several instances.
        var repeated: String?
        /// The nodes this one references, sorted.
        var dependencies: [String] = []
        /// The block with comments blanked.
        var body = ""
        /// A variable's default, when it is a plain string (`vpc-0f7d…`).
        var defaultValue: String?

        /// The network the rest runs in, and so the start of the diagram: a VPC created here (`aws_vpc`), read with a
        /// data source, or an existing one given as an input (`var.vpc_id`). Never hidden.
        var isNetworkRoot: Bool {
            switch kind {
            case .resource, .data: type == "aws_vpc" || type == "aws_default_vpc"
            case .variable: name == "vpc_id" || name == "vpc" || name.hasSuffix("_vpc_id")
            default: false
            }
        }
    }

    struct Edge: Hashable, Sendable {
        let from: String
        let to: String
    }

    var nodes: [Node]

    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// From each dependency to the node that uses it.
    var edges: [Edge] { nodes.flatMap { n in n.dependencies.map { Edge(from: $0, to: n.id) } } }

    func dependents(of id: String) -> [String] { nodes.filter { $0.dependencies.contains(id) }.map(\.id).sorted() }

    /// The graph without the `hidden` kinds. A hidden node does not break a chain: what it used is linked to what used it.
    func hiding(_ hidden: Set<Kind>) -> TerraformGraph {
        guard !hidden.isEmpty else { return self }
        let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        func isHidden(_ n: Node) -> Bool { hidden.contains(n.kind) && !n.isNetworkRoot }
        func visible(from id: String, seen: inout Set<String>) -> Set<String> {
            guard seen.insert(id).inserted, let n = byId[id] else { return [] }
            if !isHidden(n) { return [id] }
            return n.dependencies.reduce(into: Set<String>()) { $0.formUnion(visible(from: $1, seen: &seen)) }
        }
        return TerraformGraph(nodes: nodes.filter { !isHidden($0) }.map { n in
            var n = n
            var seen: Set<String> = [n.id]
            n.dependencies = n.dependencies.reduce(into: Set<String>()) { $0.formUnion(visible(from: $1, seen: &seen)) }
                .subtracting([n.id]).sorted()
            return n
        })
    }

    func count(_ kind: Kind) -> Int { nodes.filter { $0.kind == kind }.count }
}

// MARK: - Reading the configuration

enum TerraformConfig {
    /// Bigger files are left out: a configuration file is a few hundred KB at most.
    static let maxFileBytes = 2_000_000

    /// Reads every `.tf` file of `folder` (not its subfolders) into a graph.
    static func graph(folder: URL) -> TerraformGraph {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".tf") }.sorted()
        var nodes: [TerraformGraph.Node] = []
        for name in files {
            let url = folder.appendingPathComponent(name)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= maxFileBytes,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            nodes += blocks(in: text, file: name)
        }
        return link(nodes)
    }

    /// Fills each node's dependencies with the declared nodes its block references.
    static func link(_ nodes: [TerraformGraph.Node]) -> TerraformGraph {
        var unique: [String: TerraformGraph.Node] = [:]
        for n in nodes where unique[n.id] == nil { unique[n.id] = n }
        let ids = Set(unique.keys)
        let linked = nodes.filter { unique[$0.id] == $0 }.map { n -> TerraformGraph.Node in
            var n = n
            n.dependencies = references(in: expressions(n.body.isEmpty ? n.source : n.body)).filter { ids.contains($0) && $0 != n.id }.sorted()
            return n
        }
        return TerraformGraph(nodes: linked)
    }

    private static let referencePattern = try! NSRegularExpression(pattern:
        #"(?<![\w.\-])(data\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+|module\.[A-Za-z0-9_\-]+|var\.[A-Za-z0-9_\-]+|local\.[A-Za-z0-9_\-]+|[a-z][a-z0-9]*_[a-z0-9_]+\.[A-Za-z_][A-Za-z0-9_\-]*)"#)

    /// Every address-like reference in a block's text (`aws_vpc.main`, `module.x`, `var.y`…).
    static func references(in text: String) -> Set<String> {
        let ns = text as NSString
        return Set(referencePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    private static let twoLabels = try! NSRegularExpression(pattern: #"^(resource|data)\s+"([^"]+)"\s+"([^"]+)"\s*\{"#)
    private static let oneLabel = try! NSRegularExpression(pattern: #"^(module|variable|output)\s+"([^"]+)"\s*\{"#)
    private static let localsBlock = try! NSRegularExpression(pattern: #"^locals\s*\{"#)
    private static let attribute = try! NSRegularExpression(pattern: #"^([A-Za-z_][A-Za-z0-9_\-]*)\s*="#)

    /// The top-level blocks of one file.
    static func blocks(in text: String, file: String) -> [TerraformGraph.Node] {
        let text = unixLines(text)
        let scanned = scan(text)
        let lines = scanned.lines
        let rawLines = text.components(separatedBy: "\n")
        var nodes: [TerraformGraph.Node] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard scanned.depths[i] == 0, !trimmed.isEmpty else { i += 1; continue }
            // The block ends on the first later line that starts back at depth 0.
            var end = i + 1
            while end < lines.count && scanned.depths[end] > 0 { end += 1 }
            let body = lines[i..<min(end, lines.count)].joined(separator: "\n")
            let raw = rawLines[i..<min(end, rawLines.count)].joined(separator: "\n")
            if let m = match(twoLabels, trimmed) {
                let isData = m[0] == "data"
                var n = TerraformGraph.Node(id: isData ? "data.\(m[1]).\(m[2])" : "\(m[1]).\(m[2])", kind: isData ? .data : .resource,
                                            type: m[1], name: m[2], file: file, line: i + 1, source: raw)
                n.repeated = topAttribute(body, ["count", "for_each"]).first
                nodes.append(n.withBody(body))
            } else if let m = match(oneLabel, trimmed) {
                let kind: TerraformGraph.Kind = m[0] == "module" ? .module : m[0] == "variable" ? .variable : .output
                let prefix = kind == .module ? "module" : kind == .variable ? "var" : "output"
                var n = TerraformGraph.Node(id: "\(prefix).\(m[1])", kind: kind, type: "", name: m[1], file: file, line: i + 1, source: raw)
                if kind == .module {
                    n.moduleSource = body.firstMatch(of: #/(?m)^\s*source\s*=\s*"([^"]*)"/#).map { String($0.1) }
                    n.repeated = topAttribute(body, ["count", "for_each"]).first
                }
                if kind == .variable {
                    n.defaultValue = attributes(body)["default"]?.wholeMatch(of: #/"([^"$]*)"/#).map { String($0.1) }
                }
                nodes.append(n.withBody(body))
            } else if match(localsBlock, trimmed) != nil {
                nodes += locals(lines: lines, raw: rawLines, depths: scanned.depths,
                                range: i..<min(end, lines.count), file: file)
            }
            i = max(end, i + 1)
        }
        return nodes
    }

    /// One node per attribute of a `locals` block.
    private static func locals(lines: [String], raw: [String], depths: [Int], range: Range<Int>, file: String) -> [TerraformGraph.Node] {
        let starts = range.dropFirst().filter { depths[$0] == 1 && match(attribute, lines[$0].trimmingCharacters(in: .whitespaces)) != nil }
        return starts.enumerated().map { k, start in
            let stop = k + 1 < starts.count ? starts[k + 1] : range.upperBound - 1
            let name = match(attribute, lines[start].trimmingCharacters(in: .whitespaces))![0]
            let body = lines[start..<max(stop, start + 1)].joined(separator: "\n")
            return TerraformGraph.Node(id: "local.\(name)", kind: .local, type: "", name: name, file: file, line: start + 1,
                                       source: raw[start..<max(stop, start + 1)].joined(separator: "\n")).withBody(body)
        }
    }

    /// Which of `names` are set at the first level of a block.
    private static func topAttribute(_ body: String, _ names: [String]) -> [String] {
        let scanned = scan(body)
        return names.filter { name in
            scanned.lines.indices.contains { scanned.depths[$0] == 1 && scanned.lines[$0].trimmingCharacters(in: .whitespaces)
                .hasPrefix(name) && match(attribute, scanned.lines[$0].trimmingCharacters(in: .whitespaces))?.first == name }
        }
    }

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    /// The text with comments blanked (line breaks kept), and the brace depth at each line's start.
    /// Braces inside strings do not count.
    /// Files saved on Windows end their lines with CR LF, which Swift reads as one character, not as `\n`: without this,
    /// such a file is one long line and none of its blocks are found.
    static func unixLines(_ text: String) -> String {
        text.utf8.contains(13) ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : text
    }

    static func scan(_ text: String) -> (lines: [String], depths: [Int]) {
        let text = unixLines(text)
        enum State { case code, string, lineComment, blockComment, heredoc(String) }
        var state = State.code
        var depth = 0
        var out = ""
        var depths = [0]
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "\n" {
                if case .lineComment = state { state = .code }
                out.append("\n")
                depths.append(max(depth, 0))
                i += 1
                if case .heredoc(let marker) = state {
                    // The heredoc ends at a line that is only its marker.
                    var j = i
                    while j < chars.count && chars[j] != "\n" { j += 1 }
                    if String(chars[i..<j]).trimmingCharacters(in: .whitespaces) == marker { state = .code }
                }
                continue
            }
            switch state {
            case .code:
                if c == "\"" { state = .string; out.append(c) }
                else if c == "#" || (c == "/" && next == "/") { state = .lineComment; out.append(" ") }
                else if c == "/" && next == "*" { state = .blockComment; out.append("  "); i += 1 }
                else if c == "<" && next == "<", let marker = heredocMarker(chars, i) { state = .heredoc(marker); out.append(c) }
                else {
                    if c == "{" { depth += 1 } else if c == "}" { depth -= 1 }
                    out.append(c)
                }
            case .string:
                out.append(c)
                if c == "\\", let next { out.append(next); i += 1 } else if c == "\"" { state = .code }
            case .lineComment:
                out.append(" ")
            case .blockComment:
                if c == "*" && next == "/" { state = .code; out.append("  "); i += 1 } else { out.append(" ") }
            case .heredoc:
                out.append(c)
            }
            i += 1
        }
        return (out.components(separatedBy: "\n"), depths)
    }

    /// The text with the literal parts of strings and heredocs blanked: only code and `${…}` interpolations are left, so
    /// `"aws_vpc.main"` written as plain text links nothing while `"${aws_vpc.main.arn}"` does.
    static func expressions(_ text: String) -> String {
        let chars = Array(unixLines(text))
        var out = ""
        var inString = false
        var heredoc: String?
        var interpolation = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if interpolation > 0 {
                if c == "{" { interpolation += 1 } else if c == "}" { interpolation -= 1 }
                out.append(interpolation == 0 ? " " : c)
            } else if c == "\n" {
                out.append(c)
                i += 1
                if let marker = heredoc {
                    var j = i
                    while j < chars.count && chars[j] != "\n" { j += 1 }
                    if String(chars[i..<j]).trimmingCharacters(in: .whitespaces) == marker { heredoc = nil; i = j }
                }
                continue
            } else if inString || heredoc != nil {
                if (c == "$" || c == "%") && next == "{" { interpolation = 1; out.append("  "); i += 1 }
                else if inString && c == "\\" { out.append("  "); i += 1 }
                else if inString && c == "\"" { inString = false; out.append(c) }
                else { out.append(" ") }
            } else if c == "\"" {
                inString = true; out.append(c)
            } else if c == "<" && next == "<", let marker = heredocMarker(chars, i) {
                heredoc = marker; out.append(c)
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    /// `<<EOF` or `<<-EOF` at `i`, followed by the end of the line.
    private static func heredocMarker(_ chars: [Character], _ i: Int) -> String? {
        var j = i + 2
        if j < chars.count && chars[j] == "-" { j += 1 }
        let start = j
        while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
        guard j > start, j >= chars.count || chars[j] == "\n" || chars[j] == "\r" else { return nil }
        return String(chars[start..<j])
    }
}

private extension TerraformGraph.Node {
    /// Keeps the block with comments blanked, where references are looked for, so commented-out code links nothing.
    func withBody(_ body: String) -> Self {
        var n = self
        n.body = body
        return n
    }
}

// MARK: - Layout

/// Columns from left to right: a node sits one column after the furthest node it depends on, so every edge points
/// right. A link that crosses several columns gets an invisible stop in each, so it runs between the blocks instead of
/// under them. Within a column, nodes are ordered near the nodes they connect to (a few barycenter sweeps).
enum TerraformGraphLayout {
    struct Slot: Equatable { let column: Int; let row: Double }

    struct Layout: Equatable {
        var slots: [String: Slot]
        /// The stops of the links that cross more than one column, in order.
        var waypoints: [TerraformGraph.Edge: [Slot]]
    }

    static func slots(_ graph: TerraformGraph) -> [String: Slot] { layout(graph).slots }

    static func layout(_ graph: TerraformGraph) -> Layout {
        let byId = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        var rank: [String: Int] = [:]
        var visiting = Set<String>()
        func rankOf(_ id: String) -> Int {
            if let r = rank[id] { return r }
            guard visiting.insert(id).inserted, let n = byId[id] else { return 0 } // a cycle: stop
            let r = n.dependencies.map { rankOf($0) + 1 }.max() ?? 0
            visiting.remove(id)
            rank[id] = r
            return r
        }
        graph.nodes.forEach { _ = rankOf($0.id) }
        // A block that uses nothing sits just before the first block that uses it, not in the first column: the first
        // column is the network's, which the rest is built on.
        let users = Dictionary(grouping: graph.edges, by: \.from).mapValues { $0.map(\.to) }
        for n in graph.nodes where n.dependencies.isEmpty && !n.isNetworkRoot {
            if let first = users[n.id]?.compactMap({ rank[$0] }).min(), first > 0 { rank[n.id] = first - 1 }
        }
        // Outputs end the graph; nothing depends on them.
        let last = rank.values.max() ?? 0
        for n in graph.nodes where n.kind == .output { rank[n.id] = max(rank[n.id] ?? 0, last) }

        var column = rank
        var before: [String: [String]] = [:], after: [String: [String]] = [:]
        var chains: [TerraformGraph.Edge: [String]] = [:]
        func link(_ a: String, _ b: String) { after[a, default: []].append(b); before[b, default: []].append(a) }
        for e in graph.edges {
            guard let a = rank[e.from], let b = rank[e.to] else { continue }
            var previous = e.from
            if b - a > 1 {
                let stops = ((a + 1)..<b).map { "\u{1}\(e.from)>\(e.to)#\($0)" }
                for (c, stop) in zip((a + 1)..<b, stops) { column[stop] = c; link(previous, stop); previous = stop }
                chains[e] = stops
            }
            link(previous, e.to)
        }

        let columnCount = (column.values.max() ?? -1) + 1
        var columns: [[String]] = Array(repeating: [], count: columnCount)
        for n in graph.nodes.sorted(by: { ($0.isNetworkRoot ? 0 : 1, $0.kind, $0.id) < ($1.isNetworkRoot ? 0 : 1, $1.kind, $1.id) }) {
            columns[rank[n.id] ?? 0].append(n.id)
        }
        for stop in column.keys.filter({ byId[$0] == nil }).sorted() { columns[column[stop]!].append(stop) }

        func position(in cols: [[String]]) -> [String: Int] {
            var p: [String: Int] = [:]
            for col in cols { for (i, id) in col.enumerated() { p[id] = i } }
            return p
        }
        for sweep in 0..<6 {
            let p = position(in: columns)
            let order = sweep % 2 == 0 ? Array(columns.indices.dropFirst()) : Array(columns.indices.dropLast().reversed())
            for c in order {
                func center(_ id: String) -> Double {
                    let near = sweep % 2 == 0 ? before[id] ?? [] : after[id] ?? []
                    let known = near.compactMap { p[$0] }
                    return known.isEmpty ? Double(p[id] ?? 0) : Double(known.reduce(0, +)) / Double(known.count)
                }
                columns[c] = columns[c].enumerated().sorted { (center($0.element), $0.offset) < (center($1.element), $1.offset) }.map(\.element)
                // The network stays at the top of its column.
                columns[c] = columns[c].filter { byId[$0]?.isNetworkRoot == true } + columns[c].filter { byId[$0]?.isNetworkRoot != true }
            }
        }
        // Columns are centered on the tallest one.
        let tallest = columns.map(\.count).max() ?? 0
        var all: [String: Slot] = [:]
        for (c, col) in columns.enumerated() {
            let offset = Double(tallest - col.count) / 2
            for (r, id) in col.enumerated() { all[id] = Slot(column: c, row: Double(r) + offset) }
        }
        return Layout(slots: all.filter { byId[$0.key] != nil },
                      waypoints: chains.mapValues { $0.compactMap { all[$0] } })
    }
}

// MARK: - Documentation

/// Links to the Terraform Registry documentation, built only from names checked against the registry's formats.
enum TerraformDocs {
    /// Providers published under the `hashicorp` namespace.
    static let hashicorpProviders: Set<String> = ["aws", "azurerm", "google", "kubernetes", "helm", "random", "null", "tls",
                                                  "time", "local", "archive", "http", "external", "cloudinit", "vault", "consul", "dns"]

    /// A resource's or data source's page, for a `hashicorp` provider.
    static func url(type: String, kind: TerraformGraph.Kind) -> URL? {
        guard kind == .resource || kind == .data, type.wholeMatch(of: #/[a-z0-9]+_[a-z0-9_]+/#) != nil,
              let provider = type.split(separator: "_").first.map(String.init), hashicorpProviders.contains(provider) else { return nil }
        let page = type.dropFirst(provider.count + 1)
        return URL(string: "https://registry.terraform.io/providers/hashicorp/\(provider)/latest/docs/\(kind == .data ? "data-sources" : "resources")/\(page)")
    }

    /// A registry module's page (`namespace/name/provider`, optionally on registry.terraform.io).
    static func url(moduleSource source: String) -> URL? {
        let plain = source.hasPrefix("registry.terraform.io/") ? String(source.dropFirst("registry.terraform.io/".count)) : source
        guard plain.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9_\-]*\/[A-Za-z0-9][A-Za-z0-9_\-]*\/[a-z0-9]+/#) != nil else { return nil }
        return URL(string: "https://registry.terraform.io/modules/\(plain)/latest")
    }

    /// A module kept in the stack's own folders (`./modules/x`), resolved inside `root`; nil for anything else
    /// or a path that leaves `root`.
    static func localModule(_ source: String, from folder: URL, root: URL) -> URL? {
        guard source.hasPrefix("./") || source.hasPrefix("../") else { return nil }
        let url = folder.appendingPathComponent(source, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path == base || url.path.hasPrefix(base + "/") else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }
}
