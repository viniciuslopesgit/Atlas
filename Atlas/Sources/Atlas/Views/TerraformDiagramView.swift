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

    static func of(_ node: TerraformGraph.Node) -> TerraformNodeStyle {
        switch node.kind {
        case .module: return .init(label: "Module", symbol: "shippingbox", category: .module)
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

    let centers: [String: CGPoint]
    let waypoints: [TerraformGraph.Edge: [CGPoint]]
    let size: CGSize

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

    func rect(_ id: String) -> CGRect? {
        centers[id].map { CGRect(x: $0.x - Self.nodeSize.width / 2, y: $0.y - Self.nodeSize.height / 2,
                                 width: Self.nodeSize.width, height: Self.nodeSize.height) }
    }

    /// The block under a point of the diagram.
    func node(at point: CGPoint) -> String? {
        centers.keys.sorted().first { rect($0)!.contains(point) }
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

/// The blocks that are drawn and where.
struct DiagramScene: Equatable {
    let graph: TerraformGraph
    let layout: TerraformGraphLayout.Layout
    let geometry: DiagramGeometry

    init(_ graph: TerraformGraph) {
        self.graph = graph
        layout = TerraformGraphLayout.layout(graph)
        geometry = DiagramGeometry(layout)
    }

    /// A block, what it uses and what uses it.
    func neighbourhood(of id: String) -> Set<String> {
        Set((graph.node(id)?.dependencies ?? []) + graph.dependents(of: id) + [id])
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
        .task(id: folder) { await load() }
        .onChange(of: hidden) { _, _ in rebuild() }
        .onAppear(perform: watchScrolling)
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            breadcrumb
            Spacer(minLength: 8)
            Menu {
                ForEach([TerraformGraph.Kind.variable, .local, .data, .output], id: \.self) { kind in
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
            let steps = [Step(title: title, folder: root, module: nil)] + trail
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                if i == steps.count - 1 {
                    Text(step.title).font(.callout.weight(.medium)).lineLimit(1)
                } else {
                    Button(step.title) { back(to: i) }.buttonStyle(.link).font(.callout)
                }
            }
            if let graph {
                Text(Self.counts(graph)).font(.caption).foregroundStyle(.secondary).padding(.leading, 6).lineLimit(1)
            }
        }
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
            if let graph, let scene, scene.graph.nodes.isEmpty {
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
            guard let next = DiagramNavigation.next(from: selection, direction, in: scene.graph, slots: scene.layout.slots) else { return .handled }
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
        guard folder == self.folder else { return }
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
        scene = graph.map { DiagramScene($0.hiding(hidden)) }
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
        ZStack(alignment: .topLeading) {
            DiagramEdges(edges: scene.graph.edges, geometry: scene.geometry, selection: selection, hovered: hovered)
            ForEach(scene.graph.nodes) { node in
                if let center = scene.geometry.centers[node.id] {
                    DiagramNode(node: node, style: .of(node), summary: modules[node.id],
                                isSelected: selection == node.id, isHovered: hovered == node.id,
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
    var isSelected = false
    var isHovered = false
    var isDimmed = false

    private var subtitle: String {
        switch node.kind {
        case .resource, .data: node.type
        case .module: [node.moduleSource ?? "", summary?.text ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        default: "\(node.file):\(node.line)"
        }
    }

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
                        Spacer(minLength: 0)
                        if node.kind == .module, summary != nil {
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                                .help("Double-click to open the module")
                        }
                    }
                    Text(node.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
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
            let lit = edges.filter { focus != nil && ($0.from == focus || $0.to == focus) }
            for e in edges where !lit.contains(e) {
                draw(e, in: &context, color: .primary.opacity(selection == nil ? 0.3 : 0.08), width: 1.2)
            }
            for e in lit { draw(e, in: &context, color: Palette.accent, width: 2) }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
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
    let onSelect: (String) -> Void
    let onOpenModule: (TerraformGraph.Node) -> Void
    let onCenter: () -> Void
    let onClose: () -> Void

    var body: some View {
        let style = TerraformNodeStyle.of(node)
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
                        row("Kind", node.kind == .data ? "\(style.label) data source (read only)" : node.kind == .resource ? "\(style.label) resource" : style.label)
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
                    links("Uses", node.dependencies)
                    links("Used by", graph.dependents(of: node.id))
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
