import SwiftUI
import AppKit

/// How a node presents itself: the service it belongs to, a symbol for it and the family that colors it.
struct TerraformNodeStyle: Equatable {
    enum Category: String, Equatable, Sendable {
        case network, compute, storage, security, observability, module, value, other

        var color: Color {
            switch self {
            case .network: Palette.blue
            case .compute: Palette.warning
            case .storage: Palette.success
            case .security: Palette.danger
            case .observability: Palette.purple
            case .module: Palette.accent
            case .value, .other: Palette.neutral
            }
        }
    }

    let label: String
    let symbol: String
    var category: Category = .other

    /// Longest prefix first, so `aws_security_group` is not taken for `aws_s`.
    private static let services: [(prefix: String, label: String, symbol: String, category: Category)] = [
        ("aws_security_group", "Security group", "lock.shield", .security),
        ("aws_vpc_security_group", "Security group", "lock.shield", .security),
        ("aws_ec2_traffic_mirror", "Traffic mirror", "point.3.connected.trianglepath.dotted", .network),
        ("aws_iam", "IAM", "person.badge.key", .security),
        ("aws_s3", "S3", "archivebox", .storage),
        ("aws_instance", "EC2", "server.rack", .compute),
        ("aws_launch_template", "EC2", "server.rack", .compute),
        ("aws_autoscaling", "Auto Scaling", "square.stack.3d.forward.dottedline", .compute),
        ("aws_ami", "EC2", "opticaldisc", .compute),
        ("aws_key_pair", "EC2", "key.horizontal", .security),
        ("aws_ebs", "EBS", "externaldrive", .storage),
        ("aws_ec2", "EC2", "server.rack", .compute),
        ("aws_eip", "VPC", "network", .network),
        ("aws_vpc", "VPC", "network", .network),
        ("aws_subnet", "VPC", "square.split.2x2", .network),
        ("aws_route53", "Route 53", "globe", .network),
        ("aws_route", "VPC", "arrow.triangle.turn.up.right.diamond", .network),
        ("aws_internet_gateway", "VPC", "network", .network),
        ("aws_nat_gateway", "VPC", "network", .network),
        ("aws_network", "VPC", "network", .network),
        ("aws_flow_log", "VPC", "list.bullet.rectangle", .observability),
        ("aws_lb", "Load balancer", "arrow.triangle.branch", .network),
        ("aws_alb", "Load balancer", "arrow.triangle.branch", .network),
        ("aws_acm", "ACM", "checkmark.seal", .security),
        ("aws_db", "RDS", "cylinder.split.1x2", .storage),
        ("aws_rds", "RDS", "cylinder.split.1x2", .storage),
        ("aws_elasticache", "ElastiCache", "bolt.horizontal", .storage),
        ("aws_dynamodb", "DynamoDB", "tablecells", .storage),
        ("aws_efs", "EFS", "externaldrive.connected.to.line.below", .storage),
        ("aws_eks", "EKS", "circle.hexagongrid", .compute),
        ("aws_ecs", "ECS", "shippingbox", .compute),
        ("aws_ecr", "ECR", "shippingbox", .storage),
        ("aws_lambda", "Lambda", "function", .compute),
        ("aws_cloudwatch", "CloudWatch", "waveform.path.ecg", .observability),
        ("aws_cloudtrail", "CloudTrail", "list.bullet.rectangle", .observability),
        ("aws_cloudfront", "CloudFront", "globe.americas", .network),
        ("aws_kms", "KMS", "key", .security),
        ("aws_secretsmanager", "Secrets Manager", "lock.doc", .security),
        ("aws_ssm", "Systems Manager", "terminal", .compute),
        ("aws_sqs", "SQS", "tray.full", .observability),
        ("aws_sns", "SNS", "bell", .observability),
        ("aws_guardduty", "GuardDuty", "shield.lefthalf.filled", .security),
        ("aws_wafv2", "WAF", "flame", .security),
        ("aws_caller_identity", "Account", "person.crop.circle", .value),
        ("aws_region", "Region", "mappin.and.ellipse", .value),
        ("aws_availability_zones", "Region", "mappin.and.ellipse", .value),
        ("kubernetes", "Kubernetes", "helm", .compute),
        ("helm", "Helm", "helm", .compute),
        ("http", "HTTP", "arrow.down.doc", .value),
        ("random", "Random", "dice", .value),
        ("tls", "TLS", "lock", .security),
        ("null", "Utility", "circle.dashed", .value),
        ("time", "Time", "clock", .value),
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// A module that mostly builds the network looks like the network.
    static func of(_ node: TerraformGraph.Node, summary: TerraformModuleSummary? = nil) -> TerraformNodeStyle {
        switch node.kind {
        case .module:
            return summary?.services.first == "VPC" ? .init(label: "Module · Network", symbol: "network", category: .network)
                : .init(label: "Module", symbol: "shippingbox", category: .module)
        case .variable where node.isNetworkRoot: return .init(label: "VPC", symbol: "network", category: .network)
        case .variable: return .init(label: "Input", symbol: "slider.horizontal.3", category: .value)
        case .local: return .init(label: "Local", symbol: "function", category: .value)
        case .output: return .init(label: "Output", symbol: "arrow.up.right.square", category: .value)
        case .resource, .data:
            if let s = services.first(where: { node.type == $0.prefix || node.type.hasPrefix($0.prefix + "_") }) {
                return .init(label: s.label, symbol: s.symbol, category: s.category)
            }
            let provider = node.type.split(separator: "_").first.map { $0.uppercased() } ?? "Resource"
            return .init(label: provider, symbol: "cube")
        }
    }
}

/// What a module of the stack holds, read from its own folder.
struct TerraformModuleSummary: Equatable, Sendable {
    let resources: Int
    let dataSources: Int
    let modules: Int
    /// The services it uses most, most used first (at most four).
    let services: [String]

    init(_ graph: TerraformGraph) {
        resources = graph.count(.resource)
        dataSources = graph.count(.data)
        modules = graph.count(.module)
        let labels = graph.nodes.filter { $0.kind == .resource }.map { TerraformNodeStyle.of($0).label }
        let counts = Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)
        services = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(4).map(\.key)
    }

    var text: String {
        var parts = ["\(resources) \(resources == 1 ? "resource" : "resources")"]
        if modules > 0 { parts.append("\(modules) \(modules == 1 ? "module" : "modules")") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Geometry, camera and keyboard

/// Where each block and each stop of a long link sits on the diagram, in points.
struct DiagramGeometry: Equatable {
    static let nodeSize = CGSize(width: 248, height: 86)
    static let spacing = CGSize(width: 88, height: 26)
    static let margin: CGFloat = 48

    /// A box of the architecture view: AWS, a region, a VPC, a zone, a subnet, a cluster.
    struct Box: Equatable {
        let id: String
        let kind: TerraformArchitecture.Kind
        let title: String
        let subtitle: String
        let node: String?
        let rect: CGRect

        var header: CGRect { CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: DiagramGeometry.header) }
    }

    static let padding: CGFloat = 16
    static let header: CGFloat = 46
    static let gap: CGFloat = 20

    private(set) var centers: [String: CGPoint]
    private(set) var waypoints: [TerraformGraph.Edge: [CGPoint]]
    private(set) var size: CGSize
    private(set) var boxes: [Box] = []
    /// Blocks folded into a card (or a box) are drawn and selected as it.
    private(set) var aliases: [String: String] = [:]
    var isArchitecture: Bool { !boxes.isEmpty }

    init(_ layout: TerraformGraphLayout.Layout) {
        centers = layout.slots.mapValues(Self.point)
        waypoints = layout.waypoints.mapValues { $0.map(Self.point) }
        let all = Array(layout.slots.values) + layout.waypoints.values.flatMap { $0 }
        let columns = CGFloat((all.map(\.column).max() ?? 0) + 1)
        let rows = CGFloat((all.map(\.row).max() ?? 0) + 1)
        size = CGSize(width: Self.margin * 2 + columns * Self.nodeSize.width + (columns - 1) * Self.spacing.width,
                      height: Self.margin * 2 + rows * Self.nodeSize.height + (rows - 1) * Self.spacing.height)
    }

    static func point(_ slot: TerraformGraphLayout.Slot) -> CGPoint {
        CGPoint(x: margin + CGFloat(slot.column) * (nodeSize.width + spacing.width) + nodeSize.width / 2,
                y: margin + CGFloat(slot.row) * (nodeSize.height + spacing.height) + nodeSize.height / 2)
    }

    /// Boxes inside boxes, cards in a grid in each: the AWS way of drawing a stack.
    init(architecture: TerraformArchitecture) {
        centers = [:]
        waypoints = [:]
        size = .zero
        aliases = architecture.foldedInto
        let measured = Self.measure(architecture.root)
        place(architecture.root, in: CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: measured))
        size = CGSize(width: measured.width + Self.margin * 2, height: measured.height + Self.margin * 2)
    }

    private static func columns(_ kind: TerraformArchitecture.Kind) -> Int {
        switch kind {
        case .zone, .publicSubnet, .privateSubnet, .subnet: 1
        case .global: 2
        case .outside: 4
        default: 6
        }
    }

    private static func insets(_ box: TerraformArchitecture.Box) -> (side: CGFloat, top: CGFloat) {
        box.kind == .group ? (0, 0) : (padding, header)
    }

    private static func grid(_ box: TerraformArchitecture.Box) -> CGSize {
        guard !box.cards.isEmpty else { return .zero }
        let columns = CGFloat(min(box.cards.count, Self.columns(box.kind)))
        let rows = (CGFloat(box.cards.count) / columns).rounded(.up)
        return CGSize(width: columns * nodeSize.width + (columns - 1) * gap, height: rows * nodeSize.height + (rows - 1) * gap)
    }

    static func measure(_ box: TerraformArchitecture.Box) -> CGSize {
        let grid = grid(box)
        let kids = box.children.map(measure)
        var width = grid.width, height = grid.height
        if !kids.isEmpty {
            let spacing = gap * CGFloat(kids.count - 1)
            let w = box.isRow ? kids.map(\.width).reduce(0, +) + spacing : kids.map(\.width).max()!
            let h = box.isRow ? kids.map(\.height).max()! : kids.map(\.height).reduce(0, +) + spacing
            width = max(width, w)
            height += (grid.height > 0 ? gap : 0) + h
        }
        let (side, top) = insets(box)
        let minimum: CGFloat = box.kind == .group ? 0 : 260
        return CGSize(width: max(width + side * 2, minimum), height: height + top + side)
    }

    private mutating func place(_ box: TerraformArchitecture.Box, in rect: CGRect) {
        if box.kind != .group {
            boxes.append(Box(id: box.id, kind: box.kind, title: box.title, subtitle: box.subtitle, node: box.node, rect: rect))
        }
        let (side, top) = Self.insets(box)
        let inner = CGRect(x: rect.minX + side, y: rect.minY + top, width: rect.width - side * 2, height: rect.height - top - side)
        let columns = min(box.cards.count, Self.columns(box.kind))
        for (i, id) in box.cards.enumerated() {
            let c = CGFloat(i % columns), r = CGFloat(i / columns)
            centers[id] = CGPoint(x: inner.minX + c * (Self.nodeSize.width + Self.gap) + Self.nodeSize.width / 2,
                                  y: inner.minY + r * (Self.nodeSize.height + Self.gap) + Self.nodeSize.height / 2)
        }
        let grid = Self.grid(box)
        var y = inner.minY + grid.height + (grid.height > 0 && !box.children.isEmpty ? Self.gap : 0)
        let kids = box.children.map(Self.measure)
        if box.isRow {
            // Side by side, as tall as each other; extra width shared out.
            let extra = max(inner.width - kids.map(\.width).reduce(0, +) - Self.gap * CGFloat(max(kids.count - 1, 0)), 0) / CGFloat(max(kids.count, 1))
            let height = max(inner.maxY - y, kids.map(\.height).max() ?? 0)
            var x = inner.minX
            for (child, size) in zip(box.children, kids) {
                place(child, in: CGRect(x: x, y: y, width: size.width + extra, height: height))
                x += size.width + extra + Self.gap
            }
        } else {
            for (child, size) in zip(box.children, kids) {
                place(child, in: CGRect(x: inner.minX, y: y, width: inner.width, height: size.height))
                y += size.height + Self.gap
            }
        }
    }

    /// The card a block is drawn as, or the header of the box it stands for.
    func rect(_ id: String) -> CGRect? {
        let id = aliases[id] ?? id
        if let c = centers[id] {
            return CGRect(x: c.x - Self.nodeSize.width / 2, y: c.y - Self.nodeSize.height / 2, width: Self.nodeSize.width, height: Self.nodeSize.height)
        }
        return boxes.last { $0.node == id }?.header
    }

    /// The block under a point of the diagram: a card, or a box's title.
    func node(at point: CGPoint) -> String? {
        if let card = centers.keys.sorted().first(where: { rect($0)!.contains(point) }) { return card }
        return boxes.last { $0.node != nil && $0.header.contains(point) }?.node
    }
}

/// How the diagram is seen: a zoom and where its top-left corner is in the view.
struct DiagramCamera: Equatable {
    static let zoomRange: ClosedRange<CGFloat> = 0.2...2

    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: pan.width + p.x * zoom, y: pan.height + p.y * zoom) }
    func content(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - pan.width) / zoom, y: (p.y - pan.height) / zoom) }

    /// Zooms keeping the point under `anchor` where it is.
    mutating func zoom(to value: CGFloat, around anchor: CGPoint) {
        let target = content(anchor)
        zoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        pan = CGSize(width: anchor.x - target.x * zoom, height: anchor.y - target.y * zoom)
    }

    mutating func move(by delta: CGSize) {
        pan = CGSize(width: pan.width + delta.width, height: pan.height + delta.height)
    }

    /// The whole diagram in `area`, never enlarged past 100 %.
    mutating func fit(_ size: CGSize, in area: CGRect) {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return }
        zoom = min(max(min(area.width / size.width, area.height / size.height), Self.zoomRange.lowerBound), 1)
        pan = CGSize(width: area.minX + (area.width - size.width * zoom) / 2, height: area.minY + (area.height - size.height * zoom) / 2)
    }

    mutating func center(_ point: CGPoint, in area: CGRect) {
        pan = CGSize(width: area.midX - point.x * zoom, height: area.midY - point.y * zoom)
    }

    /// The part of the diagram seen through a view of `size`.
    func visible(in size: CGSize) -> CGRect {
        CGRect(origin: content(.zero), size: CGSize(width: size.width / zoom, height: size.height / zoom))
    }

    /// Whether a rectangle of the diagram is wholly inside `area` of the view.
    func shows(_ rect: CGRect, in area: CGRect) -> Bool {
        area.contains(CGRect(origin: screen(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom)))
    }
}

/// Moving the selection with the arrow keys: ← to what a block uses, → to what uses it, ↑ ↓ within its column.
enum DiagramNavigation {
    enum Direction { case left, right, up, down }

    static func next(from id: String?, _ direction: Direction, in graph: TerraformGraph,
                     slots: [String: TerraformGraphLayout.Slot]) -> String? {
        guard let id, let here = slots[id] else {
            return slots.min { ($0.value.column, $0.value.row, $0.key) < ($1.value.column, $1.value.row, $1.key) }?.key
        }
        func closest(_ ids: [String]) -> String? {
            ids.compactMap { i in slots[i].map { (i, $0) } }
                .min { (abs($0.1.column - here.column), abs($0.1.row - here.row), $0.0) < (abs($1.1.column - here.column), abs($1.1.row - here.row), $1.0) }?.0
        }
        switch direction {
        case .up:
            return slots.filter { $0.value.column == here.column && $0.value.row < here.row }.max { $0.value.row < $1.value.row }?.key
        case .down:
            return slots.filter { $0.value.column == here.column && $0.value.row > here.row }.min { $0.value.row < $1.value.row }?.key
        case .right:
            return closest(graph.dependents(of: id)) ?? closest(slots.filter { $0.value.column > here.column }.map(\.key))
        case .left:
            return closest(graph.node(id)?.dependencies ?? []) ?? closest(slots.filter { $0.value.column < here.column }.map(\.key))
        }
    }
}

extension DiagramNavigation {
    /// In the architecture view the arrows move to the nearest card on that side.
    static func nearest(from id: String?, _ direction: Direction, centers: [String: CGPoint]) -> String? {
        guard let id, let here = centers[id] else {
            return centers.min { ($0.value.y, $0.value.x, $0.key) < ($1.value.y, $1.value.x, $1.key) }?.key
        }
        let candidates = centers.filter { other in
            let dx = other.value.x - here.x, dy = other.value.y - here.y
            switch direction {
            case .left: return dx < -1 && abs(dy) <= abs(dx) * 1.5
            case .right: return dx > 1 && abs(dy) <= abs(dx) * 1.5
            case .up: return dy < -1 && abs(dx) <= abs(dy) * 1.5
            case .down: return dy > 1 && abs(dx) <= abs(dy) * 1.5
            }
        }
        return candidates.min { a, b in
            func cost(_ p: CGPoint) -> CGFloat {
                let dx = abs(p.x - here.x), dy = abs(p.y - here.y)
                return direction == .left || direction == .right ? dx + dy * 2 : dy + dx * 2
            }
            return (cost(a.value), a.key) < (cost(b.value), b.key)
        }?.key
    }
}

/// The blocks that are drawn and where.
struct DiagramScene: Equatable {
    let graph: TerraformGraph
    let layout: TerraformGraphLayout.Layout?
    let geometry: DiagramGeometry
    let architecture: TerraformArchitecture?
    /// The blocks drawn as cards.
    let cards: [TerraformGraph.Node]

    init(_ graph: TerraformGraph) {
        self.graph = graph
        let layout = TerraformGraphLayout.layout(graph)
        self.layout = layout
        geometry = DiagramGeometry(layout)
        architecture = nil
        cards = graph.nodes
    }

    init(architecture: TerraformArchitecture) {
        graph = architecture.graph
        layout = nil
        geometry = DiagramGeometry(architecture: architecture)
        self.architecture = architecture
        let byId = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        cards = architecture.cards.compactMap { byId[$0] }
    }

    /// A block, what it uses and what uses it, as drawn (folded blocks as the card they are in).
    func neighbourhood(of id: String) -> Set<String> {
        let near = (graph.node(id)?.dependencies ?? []) + graph.dependents(of: id) + [id] + (architecture?.folded[id] ?? [])
        return Set(near.map { geometry.aliases[$0] ?? $0 })
    }
}

// MARK: - Diagram

/// The stack's configuration as a diagram. Scroll with two fingers or drag to move around, pinch or ⌘-scroll to zoom,
/// click a block to see what it uses and what uses it, double-click a module of the stack to open it, use the arrow
/// keys to follow the links.
struct TerraformDiagramView: View {
    let root: URL
    let title: String

    struct Step: Equatable { let title: String; let folder: URL; let module: String? }

    /// Architecture: where each resource lives in AWS (global, region, VPC, zone, subnet, cluster), modules included.
    /// Dependencies: what each block of one folder uses, from left to right.
    enum Mode: String, CaseIterable { case architecture = "Architecture", dependencies = "Dependencies" }

    @State private var mode: Mode = .architecture
    @State private var stack: TerraformStack?
    /// The folders opened after the stack's own: its modules, each with the block that opened it.
    @State private var trail: [Step] = []
    @State private var graph: TerraformGraph?
    @State private var modules: [String: TerraformModuleSummary] = [:]
    @State private var scene: DiagramScene?
    @State private var hidden: Set<TerraformGraph.Kind> = [.variable, .local, .output]
    @State private var selection: String?
    @State private var hovered: String?
    @State private var camera = DiagramCamera()
    @State private var dragStart: CGSize?
    @State private var viewport: CGSize = .zero
    @State private var pointer: CGPoint?
    @State private var needsFit = true
    @State private var search = ""
    @State private var monitor: Any?
    @FocusState private var focused: Bool

    static let inspectorWidth: CGFloat = 300
    private static let inset: CGFloat = 12

    private var folder: URL { trail.last?.folder ?? root }

    private var matches: Set<String>? {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let scene else { return nil }
        return Set(scene.graph.nodes.filter { $0.id.lowercased().contains(q) }.map(\.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    canvas
                    overlays(geo.size)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let p) = phase { point(at: p) } else { point(at: nil) }
                }
                .onAppear { resize(geo.size) }
                .onChange(of: geo.size) { _, s in resize(s) }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
        .card(radius: Radius.tile)
        .task(id: "\(mode.rawValue)|\(folder.path)") { await load() }
        .onChange(of: mode) { _, _ in go(to: [], selecting: nil) }
        .onChange(of: hidden) { _, _ in rebuild() }
        .onAppear(perform: watchScrolling)
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Architecture: where each resource lives in AWS. Dependencies: what each block uses.")
            breadcrumb
            Spacer(minLength: 8)
            Menu {
                ForEach(mode == .architecture ? [TerraformGraph.Kind.data] : [.variable, .local, .data, .output], id: \.self) { kind in
                    Toggle("\(kind.title) (\(graph?.count(kind) ?? 0))", isOn: Binding(
                        get: { !hidden.contains(kind) }, set: { on in if on { hidden.remove(kind) } else { hidden.insert(kind) } }))
                }
            } label: {
                Label("Show", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Show or hide variables, locals, data sources and outputs; hidden blocks keep their links")
            HStack(spacing: 4) {
                TextField("Find a block", text: $search)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .onSubmit(findNext)
                    .onExitCommand { search = "" }
                if let matches {
                    Text(matches.isEmpty ? "None" : "\(matches.count)").font(.caption.monospacedDigit())
                        .foregroundStyle(matches.isEmpty ? Palette.danger : .secondary).frame(minWidth: 28)
                }
            }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Read the configuration files again")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            let steps = mode == .architecture ? [Step(title: title, folder: root, module: nil)] : [Step(title: title, folder: root, module: nil)] + trail
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                if i == steps.count - 1 {
                    Text(step.title).font(.callout.weight(.medium)).lineLimit(1)
                } else {
                    Button(step.title) { back(to: i) }.buttonStyle(.link).font(.callout)
                }
            }
            if mode == .architecture, let stack {
                Text(Self.counts(stack)).font(.caption).foregroundStyle(.secondary).padding(.leading, 6).lineLimit(1)
            } else if let graph {
                Text(Self.counts(graph)).font(.caption).foregroundStyle(.secondary).padding(.leading, 6).lineLimit(1)
            }
        }
    }

    static func counts(_ stack: TerraformStack) -> String {
        let resources = stack.graph.count(.resource), modules = Set(stack.modules.values).count
        return "\(resources) resource\(resources == 1 ? "" : "s")" + (modules > 0 ? " in \(modules) module\(modules == 1 ? "" : "s")" : "")
    }

    static func counts(_ graph: TerraformGraph) -> String {
        let parts = [(graph.count(.resource), "resource"), (graph.count(.module), "module"), (graph.count(.data), "data source")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "No blocks" : parts.joined(separator: ", ")
    }

    // MARK: Canvas

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            DotGrid(camera: camera).allowsHitTesting(false)
            if let scene {
                DiagramContent(scene: scene, selection: selection, hovered: hovered, matches: matches, modules: modules)
                    .equatable()
                    .scaleEffect(camera.zoom, anchor: .topLeading)
                    .offset(camera.pan)
                    .allowsHitTesting(false)
            }
            if let graph, let scene, scene.cards.isEmpty && scene.geometry.boxes.allSatisfy({ $0.node == nil }) {
                EmptyStateView(icon: "point.3.connected.trianglepath.dotted", title: "Nothing to draw",
                               message: graph.nodes.isEmpty
                                   ? "There are no Terraform blocks in this folder's .tf files."
                                   : "Every block here is hidden. Choose what to show in Show.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if graph == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape]) { press in key(press.key) }
        .onTapGesture(count: 1, coordinateSpace: .local) { p in click(at: p) }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { v in
                if dragStart == nil { dragStart = camera.pan; NSCursor.closedHand.push() }
                let start = dragStart ?? camera.pan
                camera.pan = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
            }
            .onEnded { _ in dragStart = nil; NSCursor.pop() })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Diagram of \(trail.last?.title ?? title)")
        .accessibilityChildren {
            ForEach(scene?.graph.nodes ?? []) { node in
                Button("\(TerraformNodeStyle.of(node).label) \(node.name), \(node.id)") { select(node.id, reveal: true) }
            }
        }
    }

    @ViewBuilder
    private func overlays(_ size: CGSize) -> some View {
        let rects = overlayRects(size)
        zoomControls
            .offset(x: rects.zoom.minX, y: rects.zoom.minY)
        if let minimap = rects.minimap, let scene {
            DiagramMinimap(scene: scene, visible: camera.visible(in: size)) { p in
                camera.center(p, in: freeArea)
            }
            .offset(x: minimap.minX, y: minimap.minY)
        }
        if let inspector = rects.inspector, let id = selection, let node = graph?.node(id), let graph {
            DiagramInspector(node: node, graph: graph, summary: modules[id], folder: folder, root: root,
                             module: scene?.architecture?.modules[id], attached: scene?.architecture?.folded[id] ?? [],
                             onSelect: { select($0, reveal: true) }, onOpenModule: open,
                             onCenter: { reveal(id, always: true) }, onClose: { selection = nil })
                .frame(width: inspector.width, height: inspector.height)
                .offset(x: inspector.minX, y: inspector.minY)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button { zoom(by: 1 / 1.25) } label: { Image(systemName: "minus").frame(width: 26, height: 24) }
                .keyboardShortcut("-", modifiers: .command).help("Zoom out (⌘−)")
            Text("\(Int((camera.zoom * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 42)
            Button { zoom(by: 1.25) } label: { Image(systemName: "plus").frame(width: 26, height: 24) }
                .keyboardShortcut("=", modifiers: .command).help("Zoom in (⌘+)")
            Divider().frame(height: 16)
            Button { fit(animated: true) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 24) }
                .keyboardShortcut("0", modifiers: .command).help("Fit the diagram (⌘0)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.tile))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(Color.primary.opacity(0.1)))
        .contentShape(Rectangle())
    }

    /// Where the floating controls sit; the pointer over them does not move the diagram.
    private func overlayRects(_ size: CGSize) -> (zoom: CGRect, minimap: CGRect?, inspector: CGRect?) {
        let inset = Self.inset
        let inspector = selection.flatMap { graph?.node($0) } == nil ? nil
            : CGRect(x: size.width - Self.inspectorWidth - inset, y: inset, width: Self.inspectorWidth, height: max(size.height - inset * 2, 0))
        let zoom = CGRect(x: inset, y: size.height - 32 - inset, width: 140, height: 32)
        var minimap: CGRect?
        if let scene, !scene.graph.nodes.isEmpty, !fits(scene.geometry.size) {
            let m = DiagramMinimap.size(for: scene.geometry.size)
            let right = (inspector.map { $0.minX } ?? size.width) - inset
            minimap = CGRect(x: right - m.width, y: size.height - m.height - inset, width: m.width, height: m.height)
        }
        return (zoom, minimap, inspector)
    }

    /// The part of the view not covered by the inspector.
    private var freeArea: CGRect {
        let covered = selection.flatMap { graph?.node($0) } == nil ? 0 : Self.inspectorWidth + Self.inset
        return CGRect(x: 0, y: 0, width: max(viewport.width - covered, 1), height: viewport.height)
    }

    private func fits(_ size: CGSize) -> Bool {
        size.width * camera.zoom <= freeArea.width + 1 && size.height * camera.zoom <= freeArea.height + 1
    }

    private func overOverlay(_ p: CGPoint) -> Bool {
        let r = overlayRects(viewport)
        return [r.zoom, r.minimap, r.inspector].compactMap { $0 }.contains { $0.contains(p) }
    }

    // MARK: Input

    private func point(at p: CGPoint?) {
        pointer = p
        let id = p.flatMap { overOverlay($0) ? nil : scene?.geometry.node(at: camera.content($0)) }
        if id != hovered { hovered = id }
    }

    private func click(at p: CGPoint) {
        focused = true
        guard !overOverlay(p) else { return }
        let id = scene?.geometry.node(at: camera.content(p))
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            if let id, let node = graph?.node(id), node.kind == .module { open(node) } else if id == nil { fit(animated: true) }
            return
        }
        if let id { select(id, reveal: true) } else { selection = nil }
    }

    private func key(_ key: KeyEquivalent) -> KeyPress.Result {
        switch key {
        case .escape:
            guard selection != nil else { return .ignored }
            selection = nil
        case .return:
            guard let id = selection, let node = graph?.node(id), node.kind == .module else { return .ignored }
            open(node)
        default:
            guard let scene else { return .ignored }
            let direction: DiagramNavigation.Direction = key == .leftArrow ? .left : key == .rightArrow ? .right : key == .upArrow ? .up : .down
            let from = selection.map { scene.geometry.aliases[$0] ?? $0 }
            let next = scene.layout.map { DiagramNavigation.next(from: from, direction, in: scene.graph, slots: $0.slots) }
                ?? DiagramNavigation.nearest(from: from, direction, centers: scene.geometry.centers)
            guard let next else { return .handled }
            select(next, reveal: true)
        }
        return .handled
    }

    /// Two-finger scrolling moves the diagram; with ⌘ (or a pinch) it zooms around the pointer. Only while the pointer
    /// is over the diagram and not over the inspector, which scrolls on its own.
    private func watchScrolling() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard let p = pointer, scene != nil, !overOverlay(p) else { return event }
            if event.type == .magnify {
                camera.zoom(to: camera.zoom * (1 + event.magnification), around: p)
            } else if event.modifierFlags.contains(.command) {
                let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
                camera.zoom(to: camera.zoom * (1 + step), around: p)
            } else {
                let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                camera.move(by: CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
            }
            return nil
        }
    }

    // MARK: Actions

    private func load() async {
        let folder = folder, root = root
        if mode == .architecture {
            let read = await Task.detached(priority: .userInitiated) { TerraformStack.load(root: root) }.value
            guard mode == .architecture else { return }
            let first = graph == nil
            stack = read
            graph = read.graph
            modules = [:]
            if let selection, read.graph.node(selection) == nil { self.selection = nil }
            rebuild()
            if first { needsFit = true; fitWhenReady() }
            return
        }
        let (read, summaries) = await Task.detached(priority: .userInitiated) { () -> (TerraformGraph, [String: TerraformModuleSummary]) in
            let graph = TerraformConfig.graph(folder: folder)
            var summaries: [String: TerraformModuleSummary] = [:]
            for n in graph.nodes where n.kind == .module {
                if let source = n.moduleSource, let url = TerraformDocs.localModule(source, from: folder, root: root) {
                    summaries[n.id] = TerraformModuleSummary(TerraformConfig.graph(folder: url))
                }
            }
            return (graph, summaries)
        }.value
        guard folder == self.folder, mode == .dependencies else { return }
        let first = graph == nil
        graph = read
        modules = summaries
        // Something always shows: a folder with only variables and outputs shows them.
        if read.hiding(hidden).nodes.isEmpty { hidden = [] }
        if let selection, read.node(selection) == nil { self.selection = nil }
        rebuild()
        if first { needsFit = true; fitWhenReady() }
    }

    private func rebuild() {
        if mode == .architecture {
            scene = stack.map { DiagramScene(architecture: TerraformArchitecture($0, showData: !hidden.contains(.data))) }
        } else {
            scene = graph.map { DiagramScene($0.hiding(hidden)) }
        }
        if let selection, scene?.graph.node(selection) == nil, graph?.node(selection) == nil { self.selection = nil }
    }

    private func resize(_ size: CGSize) {
        viewport = size
        fitWhenReady()
    }

    /// Fits once there is both a diagram and a view to fit it in; then shows the block the user came back from.
    private func fitWhenReady() {
        guard needsFit, let scene, viewport.width > 0, viewport.height > 0 else { return }
        needsFit = false
        camera.fit(scene.geometry.size, in: freeArea)
        if let id = selection { reveal(id) }
    }

    private func fit(animated: Bool) {
        guard let scene else { return }
        withAnimation(animated ? .easeOut(duration: 0.25) : nil) { camera.fit(scene.geometry.size, in: freeArea) }
    }

    private func zoom(by factor: CGFloat) {
        let area = freeArea
        withAnimation(.easeOut(duration: 0.15)) { camera.zoom(to: camera.zoom * factor, around: CGPoint(x: area.midX, y: area.midY)) }
    }

    private func open(_ node: TerraformGraph.Node) {
        guard node.kind == .module, let source = node.moduleSource,
              let url = TerraformDocs.localModule(source, from: folder, root: root) else { return }
        go(to: trail + [Step(title: node.name, folder: url, module: node.id)], selecting: nil)
    }

    /// Back to the stack (0) or one of the modules opened, with the module just left selected.
    private func back(to index: Int) {
        let left = trail[index].module
        go(to: Array(trail.prefix(index)), selecting: left)
    }

    private func go(to steps: [Step], selecting id: String?) {
        trail = steps
        graph = nil
        stack = nil
        scene = nil
        modules = [:]
        selection = id
        hovered = nil
        search = ""
    }

    /// Selects a block, showing its kind if it was hidden, and moves the view to it if it is out of sight.
    private func select(_ id: String, reveal show: Bool) {
        if scene?.graph.node(id) == nil, let kind = graph?.node(id)?.kind {
            hidden.remove(kind)
            rebuild()
        }
        selection = id
        if show { reveal(id) }
    }

    private func reveal(_ id: String, always: Bool = false) {
        guard let rect = scene?.geometry.rect(id) else { return }
        let area = freeArea.insetBy(dx: 16, dy: 16)
        guard always || !camera.shows(rect, in: area) else { return }
        withAnimation(.easeOut(duration: 0.25)) { camera.center(CGPoint(x: rect.midX, y: rect.midY), in: freeArea) }
    }

    private func findNext() {
        guard let matches, !matches.isEmpty else { return }
        let ordered = matches.sorted()
        let next = ordered.firstIndex(of: selection ?? "").map { ordered[($0 + 1) % ordered.count] } ?? ordered[0]
        select(next, reveal: true)
    }
}

// MARK: - Pieces

/// The blocks and their links, at 100 %; the camera scales and moves it. Redrawn only when what it shows changes,
/// not while moving around.
struct DiagramContent: View, Equatable {
    let scene: DiagramScene
    let selection: String?
    let hovered: String?
    let matches: Set<String>?
    let modules: [String: TerraformModuleSummary]

    var body: some View {
        let focus = selection.map { scene.neighbourhood(of: $0) }
        let selected = selection.map { scene.geometry.aliases[$0] ?? $0 }
        ZStack(alignment: .topLeading) {
            ForEach(scene.geometry.boxes, id: \.id) { box in
                DiagramBoxView(box: box, isSelected: box.node != nil && box.node == selected)
                    .frame(width: box.rect.width, height: box.rect.height)
                    .position(x: box.rect.midX, y: box.rect.midY)
            }
            DiagramEdges(edges: scene.graph.edges, geometry: scene.geometry, selection: selected, hovered: hovered)
            ForEach(scene.cards) { node in
                if let center = scene.geometry.centers[node.id] {
                    DiagramNode(node: node, style: .of(node, summary: modules[node.id]), summary: modules[node.id],
                                module: scene.architecture?.modules[node.id], attached: scene.architecture?.folded[node.id]?.count ?? 0,
                                isSelected: selected == node.id, isHovered: hovered == node.id,
                                isDimmed: !(focus?.contains(node.id) ?? true) || !(matches?.contains(node.id) ?? true))
                        .frame(width: DiagramGeometry.nodeSize.width, height: DiagramGeometry.nodeSize.height)
                        .position(center)
                }
            }
        }
        .frame(width: scene.geometry.size.width, height: scene.geometry.size.height, alignment: .topLeading)
    }
}

/// A block: the service's symbol in its family's color, its label, the block's name and its address. Data sources have
/// a dashed outline (they only read); blocks with count or for_each are drawn as a small stack.
struct DiagramNode: View {
    let node: TerraformGraph.Node
    let style: TerraformNodeStyle
    var summary: TerraformModuleSummary?
    /// In the architecture view: the module the block is in, and how many blocks are folded into it.
    var module: String?
    var attached = 0
    var isSelected = false
    var isHovered = false
    var isDimmed = false

    private var subtitle: String {
        switch node.kind {
        case .resource, .data: [node.type, module ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case .module: [node.moduleSource ?? "", summary?.text ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case .variable where node.isNetworkRoot: "existing · \(node.id)"
        default: "\(node.file):\(node.line)"
        }
    }

    /// An existing VPC is named by its id when the input has one.
    private var title: String { node.kind == .variable && node.isNetworkRoot ? node.defaultValue ?? node.name : node.name }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel)
        ZStack {
            if node.repeated != nil {
                shape.fill(Color(nsColor: .controlBackgroundColor)).overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
                    .offset(x: 5, y: 5).opacity(isDimmed ? 0.5 : 1)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(style.category.color)
                    .frame(width: 32, height: 32)
                    .background(style.category.color.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.tile))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(style.label.uppercased()).font(.system(size: 10, weight: .medium)).tracking(0.6)
                            .foregroundStyle(.secondary).lineLimit(1)
                        if let repeated = node.repeated {
                            Text(repeated).font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.tile))
                                .foregroundStyle(Palette.accent)
                        }
                        if attached > 0 {
                            Text("+\(attached)").font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.tile))
                                .foregroundStyle(.secondary)
                                .help("\(attached) attached blocks (policies, associations, settings)")
                        }
                        Spacer(minLength: 0)
                        if node.kind == .module, summary != nil {
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                                .help("Double-click to open the module")
                        }
                    }
                    Text(title).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .opacity(isDimmed ? 0.35 : 1)
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(
                isSelected ? Palette.accent : Color.primary.opacity(isHovered ? 0.32 : isDimmed ? 0.07 : 0.14),
                style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: node.kind == .data ? [4, 3] : [])))
            .overlay(alignment: .leading) { Port(isLit: isSelected).offset(x: -4) }
            .overlay(alignment: .trailing) { Port(isLit: isSelected).offset(x: 4) }
            .shadow(color: .black.opacity(isSelected ? 0.22 : isHovered ? 0.12 : 0.05), radius: isSelected ? 10 : 4, y: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.label) \(node.name), \(node.id)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private struct Port: View {
        var isLit = false
        var body: some View {
            Circle().fill(isLit ? Palette.accent : Color(nsColor: .controlBackgroundColor)).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(isLit ? Palette.accent : Color.primary.opacity(0.3)))
        }
    }
}

/// Curves from each block's right side to the left side of the block that uses it, through the gaps between columns
/// for links that cross several, ending in an arrow.
struct DiagramEdges: View {
    let edges: [TerraformGraph.Edge]
    let geometry: DiagramGeometry
    let selection: String?
    var hovered: String?

    var body: some View {
        Canvas { context, _ in
            let focus = selection ?? hovered
            let alias = geometry.aliases
            let lit = edges.filter { focus != nil && (alias[$0.from] ?? $0.from) != (alias[$0.to] ?? $0.to)
                && ((alias[$0.from] ?? $0.from) == focus || (alias[$0.to] ?? $0.to) == focus) }
            if geometry.isArchitecture {
                // Boxes already say where things are: only the links of the block in focus are drawn.
                var drawn = Set<String>()
                for e in lit {
                    let from = alias[e.from] ?? e.from, to = alias[e.to] ?? e.to
                    guard drawn.insert(from + ">" + to).inserted else { continue }
                    connect(from, to, in: &context, color: selection == nil ? Palette.accent.opacity(0.6) : Palette.accent)
                }
                return
            }
            for e in edges where !lit.contains(e) {
                draw(e, in: &context, color: .primary.opacity(selection == nil ? 0.3 : 0.08), width: 1.2)
            }
            for e in lit { draw(e, in: &context, color: Palette.accent, width: 2) }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }

    /// From the side of one block that faces the other, to the facing side of the other.
    private func connect(_ from: String, _ to: String, in context: inout GraphicsContext, color: Color) {
        guard let a = geometry.rect(from), let b = geometry.rect(to) else { return }
        // A block inside the box it uses (a subnet, the VPC, the cluster) needs no line: it is drawn there.
        let outer = { (id: String) in geometry.boxes.last { $0.node == id }?.rect }
        if outer(to)?.contains(a) == true || outer(from)?.contains(b) == true { return }
        let start: CGPoint, end: CGPoint, out: CGVector
        if b.minX > a.maxX + 8 {
            start = CGPoint(x: a.maxX, y: a.midY); end = CGPoint(x: b.minX, y: b.midY); out = CGVector(dx: 1, dy: 0)
        } else if b.maxX < a.minX - 8 {
            start = CGPoint(x: a.minX, y: a.midY); end = CGPoint(x: b.maxX, y: b.midY); out = CGVector(dx: -1, dy: 0)
        } else if b.minY > a.maxY {
            start = CGPoint(x: a.midX, y: a.maxY); end = CGPoint(x: b.midX, y: b.minY); out = CGVector(dx: 0, dy: 1)
        } else {
            start = CGPoint(x: a.midX, y: a.minY); end = CGPoint(x: b.midX, y: b.maxY); out = CGVector(dx: 0, dy: -1)
        }
        let bend = max(hypot(end.x - start.x, end.y - start.y) / 3, 30)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + out.dx * bend, y: start.y + out.dy * bend),
                      control2: CGPoint(x: end.x - out.dx * bend, y: end.y - out.dy * bend))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        // The arrow points into the block that uses the other.
        let angle = atan2(out.dy, out.dx)
        var arrow = Path()
        for side in [-1.0, 1.0] {
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(x: end.x - 8 * cos(angle + side * 0.5), y: end.y - 8 * sin(angle + side * 0.5)))
        }
        context.stroke(arrow, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        context.fill(Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)), with: .color(color))
    }

    private func draw(_ e: TerraformGraph.Edge, in context: inout GraphicsContext, color: Color, width: CGFloat) {
        guard let a = geometry.centers[e.from], let b = geometry.centers[e.to] else { return }
        let half = DiagramGeometry.nodeSize.width / 2
        let start = CGPoint(x: a.x + half + 4, y: a.y), end = CGPoint(x: b.x - half - 4, y: b.y)
        var path = Path()
        path.move(to: start)
        var from = start
        func curve(to p: CGPoint) {
            let bend = max(abs(p.x - from.x) / 2, 30)
            path.addCurve(to: p, control1: CGPoint(x: from.x + bend, y: from.y), control2: CGPoint(x: p.x - bend, y: p.y))
            from = p
        }
        for w in geometry.waypoints[e] ?? [] {
            curve(to: CGPoint(x: w.x - half, y: w.y))
            path.addLine(to: CGPoint(x: w.x + half, y: w.y))
            from = CGPoint(x: w.x + half, y: w.y)
        }
        curve(to: end)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        var arrow = Path()
        arrow.move(to: CGPoint(x: end.x - 7, y: end.y - 4.5))
        arrow.addLine(to: end)
        arrow.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4.5))
        context.stroke(arrow, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

/// A box of the architecture view, styled the way AWS diagrams draw it: the region dashed, the VPC solid, zones
/// dashed, public subnets green, private subnets blue, the cluster orange.
struct DiagramBoxView: View {
    let box: DiagramGeometry.Box
    var isSelected = false

    struct Look {
        let symbol: String
        let color: Color
        let dashed: Bool
        let fill: Double
        let stroke: Double
    }

    static func look(_ kind: TerraformArchitecture.Kind) -> Look {
        switch kind {
        case .cloud: Look(symbol: "cloud", color: Palette.neutral, dashed: false, fill: 0.02, stroke: 0.6)
        case .global: Look(symbol: "globe", color: Palette.danger, dashed: false, fill: 0.04, stroke: 0.35)
        case .region: Look(symbol: "mappin.and.ellipse", color: Palette.accent, dashed: true, fill: 0, stroke: 0.8)
        case .services: Look(symbol: "square.grid.2x2", color: Palette.neutral, dashed: false, fill: 0.03, stroke: 0.25)
        case .vpc: Look(symbol: "network", color: Palette.purple, dashed: false, fill: 0.04, stroke: 0.8)
        case .zone: Look(symbol: "building.2", color: Palette.blue, dashed: true, fill: 0, stroke: 0.6)
        case .publicSubnet: Look(symbol: "lock.open", color: Palette.success, dashed: false, fill: 0.08, stroke: 0.5)
        case .privateSubnet: Look(symbol: "lock", color: Palette.blue, dashed: false, fill: 0.08, stroke: 0.5)
        case .subnet: Look(symbol: "square.split.2x2", color: Palette.neutral, dashed: false, fill: 0.06, stroke: 0.4)
        case .spread: Look(symbol: "square.split.3x1", color: Palette.blue, dashed: true, fill: 0.05, stroke: 0.5)
        case .existing: Look(symbol: "square.dashed", color: Palette.neutral, dashed: true, fill: 0.03, stroke: 0.5)
        case .cluster: Look(symbol: "circle.hexagongrid", color: Palette.warning, dashed: false, fill: 0.04, stroke: 0.7)
        case .outside: Look(symbol: "puzzlepiece.extension", color: Palette.neutral, dashed: true, fill: 0.02, stroke: 0.4)
        case .group: Look(symbol: "square", color: .clear, dashed: false, fill: 0, stroke: 0)
        }
    }

    var body: some View {
        let look = Self.look(box.kind)
        let shape = RoundedRectangle(cornerRadius: Radius.panel)
        ZStack(alignment: .topLeading) {
            shape.fill(look.color.opacity(look.fill))
            shape.strokeBorder(isSelected ? Palette.accent : look.color.opacity(look.stroke),
                               style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: look.dashed ? [6, 4] : []))
            HStack(spacing: 8) {
                Image(systemName: look.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(look.color)
                    .frame(width: 26, height: 26)
                    .background(look.color.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.tile))
                VStack(alignment: .leading, spacing: 1) {
                    Text(box.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    if !box.subtitle.isEmpty {
                        Text(box.subtitle).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, DiagramGeometry.padding).padding(.top, 10)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A quiet dot grid that moves and scales with the diagram, so moving it reads as moving.
private struct DotGrid: View {
    let camera: DiagramCamera

    var body: some View {
        Canvas { context, size in
            var step: CGFloat = 22 * camera.zoom
            while step < 11 { step *= 2 }
            let x0 = camera.pan.width.truncatingRemainder(dividingBy: step) - step
            let y0 = camera.pan.height.truncatingRemainder(dividingBy: step) - step
            var dots = Path()
            for x in stride(from: x0, to: size.width, by: step) {
                for y in stride(from: y0, to: size.height, by: step) {
                    dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                }
            }
            context.fill(dots, with: .color(.primary.opacity(0.09)))
        }
    }
}

/// The whole diagram in small, with the part in view outlined; click or drag in it to move there.
struct DiagramMinimap: View {
    let scene: DiagramScene
    let visible: CGRect
    let onMove: (CGPoint) -> Void

    static let padding: CGFloat = 6

    static func size(for content: CGSize) -> CGSize {
        let scale = min(180 / max(content.width, 1), 110 / max(content.height, 1))
        return CGSize(width: content.width * scale + padding * 2, height: content.height * scale + padding * 2)
    }

    var body: some View {
        let outer = Self.size(for: scene.geometry.size)
        let scale = (outer.width - Self.padding * 2) / max(scene.geometry.size.width, 1)
        Canvas { context, _ in
            for node in scene.graph.nodes {
                guard let r = scene.geometry.rect(node.id) else { continue }
                let small = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
                context.fill(Path(small), with: .color(TerraformNodeStyle.of(node).category.color.opacity(0.6)))
            }
            let view = CGRect(x: visible.minX * scale, y: visible.minY * scale, width: visible.width * scale, height: visible.height * scale)
            context.fill(Path(view), with: .color(Palette.accent.opacity(0.08)))
            context.stroke(Path(view), with: .color(Palette.accent), lineWidth: 1.2)
        }
        .frame(width: outer.width - Self.padding * 2, height: outer.height - Self.padding * 2)
        .clipped()
        .padding(Self.padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.tile))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(Color.primary.opacity(0.1)))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            onMove(CGPoint(x: (v.location.x - Self.padding) / scale, y: (v.location.y - Self.padding) / scale))
        })
        .help("Click or drag to move around the diagram")
        .accessibilityHidden(true)
    }
}

/// The selected block: what it is, where it is written, what it holds, what it uses and what uses it, its code and its
/// documentation.
private struct DiagramInspector: View {
    let node: TerraformGraph.Node
    let graph: TerraformGraph
    let summary: TerraformModuleSummary?
    let folder: URL
    let root: URL
    var module: String?
    /// Blocks folded into this one in the architecture view.
    var attached: [String] = []
    let onSelect: (String) -> Void
    let onOpenModule: (TerraformGraph.Node) -> Void
    let onCenter: () -> Void
    let onClose: () -> Void

    var body: some View {
        let style = TerraformNodeStyle.of(node, summary: summary)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(style.category.color)
                    .frame(width: 34, height: 34)
                    .background(style.category.color.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.tile))
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(Typo.panelTitle).lineLimit(2)
                    Text(node.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(action: onClose) { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.borderless).help("Close (Esc)")
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        row("Kind", kind(style))
                        if node.isNetworkRoot, node.kind == .variable, let value = node.defaultValue { row("Id", value) }
                        if let module { row("Module", module) }
                        row("File", "\(node.file), line \(node.line)")
                        if let repeated = node.repeated { row("Instances", "Several, with \(repeated)") }
                        if let source = node.moduleSource { row("Source", source) }
                        if let summary {
                            row("Holds", [summary.text, summary.dataSources > 0 ? "\(summary.dataSources) data sources" : ""]
                                .filter { !$0.isEmpty }.joined(separator: ", "))
                            if !summary.services.isEmpty { row("Services", summary.services.joined(separator: ", ")) }
                        }
                    }
                    actions
                    links("Uses", node.dependencies.filter { graph.node($0) != nil })
                    links("Used by", graph.dependents(of: node.id))
                    if !attached.isEmpty { links("Attached", attached.sorted()) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Code").font(.callout.weight(.medium))
                        ScrollView(.horizontal) {
                            Text(node.source.count > 6000 ? String(node.source.prefix(6000)) + "\n…" : node.source)
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.tile))
                    }
                }
                .padding(14)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .contentShape(Rectangle())
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if node.kind == .module, let source = node.moduleSource, TerraformDocs.localModule(source, from: folder, root: root) != nil {
                Button("Open Module") { onOpenModule(node) }.buttonStyle(.borderedProminent).help("Open the module (Return or double-click)")
            }
            if let url = node.moduleSource.flatMap(TerraformDocs.url(moduleSource:)) ?? TerraformDocs.url(type: node.type, kind: node.kind) {
                Link(destination: url) { Label("Docs", systemImage: "book") }
                    .help("Terraform Registry: \(url.absoluteString)")
            }
            Spacer(minLength: 0)
            Button(action: onCenter) { Image(systemName: "scope") }.buttonStyle(.borderless).help("Center on the block")
            Button { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(node.file)]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal \(node.file) in Finder")
        }
    }

    private func kind(_ style: TerraformNodeStyle) -> String {
        switch node.kind {
        case .data: "\(style.label) data source (read only)"
        case .resource: "\(style.label) resource"
        case .variable where node.isNetworkRoot: "An existing VPC, given as an input: this stack does not create it"
        default: style.label
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func links(_ title: String, _ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(ids.count))").font(.callout.weight(.medium))
            if ids.isEmpty {
                Text("Nothing").font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(ids, id: \.self) { id in
                    Button { onSelect(id) } label: {
                        HStack(spacing: 6) {
                            if let n = graph.node(id) {
                                let s = TerraformNodeStyle.of(n)
                                Image(systemName: s.symbol).foregroundStyle(s.category.color).frame(width: 16)
                            }
                            Text(id).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
            }
        }
    }
}
