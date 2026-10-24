import SwiftUI
import AppKit

/// How a node presents itself: the service it belongs to and a symbol for it.
struct TerraformNodeStyle: Equatable {
    let label: String
    let symbol: String

    /// Longest prefix first, so `aws_security_group` is not taken for `aws_s`.
    private static let services: [(prefix: String, label: String, symbol: String)] = [
        ("aws_security_group", "Security group", "lock.shield"),
        ("aws_vpc_security_group", "Security group", "lock.shield"),
        ("aws_ec2_traffic_mirror", "Traffic mirror", "point.3.connected.trianglepath.dotted"),
        ("aws_iam", "IAM", "person.badge.key"),
        ("aws_s3", "S3", "archivebox"),
        ("aws_instance", "EC2", "server.rack"),
        ("aws_launch_template", "EC2", "server.rack"),
        ("aws_autoscaling", "Auto Scaling", "square.stack.3d.forward.dottedline"),
        ("aws_ami", "EC2", "opticaldisc"),
        ("aws_key_pair", "EC2", "key.horizontal"),
        ("aws_ebs", "EBS", "externaldrive"),
        ("aws_ec2", "EC2", "server.rack"),
        ("aws_eip", "VPC", "network"),
        ("aws_vpc", "VPC", "network"),
        ("aws_subnet", "VPC", "square.split.2x2"),
        ("aws_route53", "Route 53", "globe"),
        ("aws_route", "VPC", "arrow.triangle.turn.up.right.diamond"),
        ("aws_internet_gateway", "VPC", "network"),
        ("aws_nat_gateway", "VPC", "network"),
        ("aws_network", "VPC", "network"),
        ("aws_flow_log", "VPC", "list.bullet.rectangle"),
        ("aws_lb", "Load balancer", "arrow.triangle.branch"),
        ("aws_alb", "Load balancer", "arrow.triangle.branch"),
        ("aws_acm", "ACM", "checkmark.seal"),
        ("aws_db", "RDS", "cylinder.split.1x2"),
        ("aws_rds", "RDS", "cylinder.split.1x2"),
        ("aws_elasticache", "ElastiCache", "bolt.horizontal"),
        ("aws_dynamodb", "DynamoDB", "tablecells"),
        ("aws_eks", "EKS", "circle.hexagongrid"),
        ("aws_ecs", "ECS", "shippingbox"),
        ("aws_ecr", "ECR", "shippingbox"),
        ("aws_lambda", "Lambda", "function"),
        ("aws_cloudwatch", "CloudWatch", "waveform.path.ecg"),
        ("aws_cloudfront", "CloudFront", "globe.americas"),
        ("aws_kms", "KMS", "key"),
        ("aws_secretsmanager", "Secrets Manager", "lock.doc"),
        ("aws_ssm", "Systems Manager", "terminal"),
        ("aws_sqs", "SQS", "tray.full"),
        ("aws_sns", "SNS", "bell"),
        ("aws_guardduty", "GuardDuty", "shield.lefthalf.filled"),
        ("aws_wafv2", "WAF", "flame"),
        ("aws_caller_identity", "Account", "person.crop.circle"),
        ("aws_region", "Region", "mappin.and.ellipse"),
        ("aws_availability_zones", "Region", "mappin.and.ellipse"),
        ("kubernetes", "Kubernetes", "helm"),
        ("helm", "Helm", "helm"),
        ("http", "HTTP", "arrow.down.doc"),
        ("random", "Random", "dice"),
        ("tls", "TLS", "lock"),
        ("null", "Utility", "circle.dashed"),
        ("time", "Time", "clock"),
    ].sorted { $0.prefix.count > $1.prefix.count }

    static func of(_ node: TerraformGraph.Node) -> TerraformNodeStyle {
        switch node.kind {
        case .module: return .init(label: "Module", symbol: "shippingbox")
        case .variable: return .init(label: "Input", symbol: "slider.horizontal.3")
        case .local: return .init(label: "Local", symbol: "function")
        case .output: return .init(label: "Output", symbol: "arrow.up.right.square")
        case .resource, .data:
            if let s = services.first(where: { node.type == $0.prefix || node.type.hasPrefix($0.prefix + "_") }) {
                return .init(label: s.label, symbol: s.symbol)
            }
            let provider = node.type.split(separator: "_").first.map { $0.uppercased() } ?? "Resource"
            return .init(label: provider, symbol: "cube")
        }
    }
}

// MARK: - Diagram

/// The stack's configuration as a diagram: drag to move around, pinch or ⌘+ / ⌘− to zoom, click a block to see
/// what it uses and what uses it, double-click a module of the stack to open it.
struct TerraformDiagramView: View {
    let root: URL
    let title: String

    /// The folders opened, the stack's first.
    @State private var path: [(title: String, folder: URL)] = []
    @State private var graph: TerraformGraph?
    @State private var hidden: Set<TerraformGraph.Kind> = [.variable, .local, .output]
    @State private var selection: String?
    @State private var hovered: String?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var search = ""
    @State private var viewport: CGSize = .zero

    static let nodeSize = CGSize(width: 248, height: 86)
    static let spacing = CGSize(width: 76, height: 26)
    static let margin: CGFloat = 48
    static let zoomRange: ClosedRange<CGFloat> = 0.25...2

    private var folder: URL { path.last?.folder ?? root }
    private var shown: TerraformGraph { (graph ?? TerraformGraph(nodes: [])).hiding(hidden) }

    var body: some View {
        let shown = shown
        let slots = TerraformGraphLayout.slots(shown)
        VStack(spacing: 0) {
            toolbar(shown)
            Divider()
            HStack(spacing: 0) {
                canvas(shown, slots)
                if let id = selection, let node = graph?.node(id) {
                    Divider()
                    DiagramInspector(node: node, graph: graph!, folder: folder, root: root,
                                     onSelect: { select($0, in: shown, slots) }, onOpenModule: open)
                        .frame(width: 300)
                }
            }
        }
        .card(radius: Radius.tile)
        .task(id: folder) { await load() }
        .onAppear { if path.isEmpty { path = [(title, root)] } }
    }

    // MARK: Toolbar

    private func toolbar(_ shown: TerraformGraph) -> some View {
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
            TextField("Find a block", text: $search)
                .textFieldStyle(.roundedBorder).frame(width: 180)
                .onSubmit { findNext(in: shown) }
            HStack(spacing: 2) {
                Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command).help("Zoom out (⌘−)")
                Button { fit(shown) } label: { Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 40) }
                    .keyboardShortcut("0", modifiers: .command).help("Fit the diagram (⌘0)")
                Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command).help("Zoom in (⌘+)")
            }
            .buttonStyle(.borderless)
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Read the configuration files again")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(Array(path.enumerated()), id: \.offset) { i, step in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                if i == path.count - 1 {
                    Text(step.title).font(.callout.weight(.medium)).lineLimit(1)
                } else {
                    Button(step.title) { path = Array(path.prefix(i + 1)); selection = nil }
                        .buttonStyle(.link).font(.callout)
                }
            }
            if let graph {
                Text("\(graph.count(.resource)) resources, \(graph.count(.module)) modules, \(graph.count(.data)) data sources")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 6).lineLimit(1)
            }
        }
    }

    // MARK: Canvas

    private func frame(_ slot: TerraformGraphLayout.Slot) -> CGPoint {
        CGPoint(x: Self.margin + CGFloat(slot.column) * (Self.nodeSize.width + Self.spacing.width) + Self.nodeSize.width / 2,
                y: Self.margin + CGFloat(slot.row) * (Self.nodeSize.height + Self.spacing.height) + Self.nodeSize.height / 2)
    }

    static func contentSize(_ slots: [String: TerraformGraphLayout.Slot]) -> CGSize {
        let columns = CGFloat((slots.values.map(\.column).max() ?? 0) + 1)
        let rows = CGFloat((slots.values.map(\.row).max() ?? 0) + 1)
        return CGSize(width: margin * 2 + columns * nodeSize.width + (columns - 1) * spacing.width,
                      height: margin * 2 + rows * nodeSize.height + (rows - 1) * spacing.height)
    }

    /// The node in focus (selected, or under the pointer) and its neighbours.
    private func focus(_ shown: TerraformGraph) -> Set<String>? {
        guard let id = selection ?? hovered, let n = shown.node(id) else { return nil }
        return Set(n.dependencies + shown.dependents(of: id) + [id])
    }

    private func canvas(_ shown: TerraformGraph, _ slots: [String: TerraformGraphLayout.Slot]) -> some View {
        let size = Self.contentSize(slots)
        let centers = slots.mapValues(frame)
        let focus = focus(shown)
        let focusId = selection ?? hovered
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                DotGrid().allowsHitTesting(false)
                ZStack(alignment: .topLeading) {
                    DiagramEdges(edges: shown.edges, centers: centers, focus: focusId)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                    ForEach(shown.nodes) { node in
                        if let center = centers[node.id] {
                            DiagramNode(node: node, style: .of(node), isSelected: selection == node.id,
                                        isDimmed: focus.map { !$0.contains(node.id) } ?? false)
                                .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
                                .position(center)
                                .onHover { inside in hovered = inside ? node.id : (hovered == node.id ? nil : hovered) }
                                .onTapGesture(count: 2) { if node.kind == .module { open(node) } }
                                .onTapGesture { selection = selection == node.id ? nil : node.id }
                        }
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .offset(pan)
                if graph != nil && shown.nodes.isEmpty {
                    EmptyStateView(icon: "point.3.connected.trianglepath.dotted", title: "Nothing to draw",
                                   message: graph?.nodes.isEmpty == true
                                       ? "There are no Terraform blocks in this folder's .tf files."
                                       : "Every block here is hidden. Choose what to show in Show.")
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if graph == nil {
                    ProgressView().frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { v in
                    let start = dragStart ?? pan
                    dragStart = start
                    pan = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    let start = zoomStart ?? zoom
                    zoomStart = start
                    setZoom(start * v.magnification, around: v.startLocation)
                }
                .onEnded { _ in zoomStart = nil })
            .onTapGesture { selection = nil }
            .onAppear { viewport = geo.size }
            .onChange(of: geo.size) { _, s in viewport = s }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    // MARK: Actions

    private func load() async {
        let folder = folder
        graph = nil
        let read = await Task.detached(priority: .userInitiated) { TerraformConfig.graph(folder: folder) }.value
        guard folder == self.folder else { return }
        graph = read
        if let selection, read.node(selection) == nil { self.selection = nil }
        // Something always shows: a folder with only variables and outputs shows them.
        if read.hiding(hidden).nodes.isEmpty { hidden = [] }
        fit(read.hiding(hidden))
    }

    private func open(_ node: TerraformGraph.Node) {
        guard node.kind == .module, let source = node.moduleSource,
              let url = TerraformDocs.localModule(source, from: folder, root: root) else { return }
        selection = nil
        path.append((node.name, url))
    }

    private func setZoom(_ value: CGFloat, around point: CGPoint? = nil) {
        let new = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        // Keeps the point under the pointer (or the middle of the view) where it is.
        let anchor = point ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let factor = new / zoom
        pan = CGSize(width: anchor.x - (anchor.x - pan.width) * factor, height: anchor.y - (anchor.y - pan.height) * factor)
        zoom = new
    }

    private func fit(_ shown: TerraformGraph) {
        let size = Self.contentSize(TerraformGraphLayout.slots(shown))
        guard viewport.width > 0, viewport.height > 0 else { return }
        zoom = min(max(min(viewport.width / size.width, viewport.height / size.height), Self.zoomRange.lowerBound), 1)
        pan = CGSize(width: (viewport.width - size.width * zoom) / 2, height: max((viewport.height - size.height * zoom) / 2, 0))
    }

    /// Selects a node and moves the view so it is in the middle.
    private func select(_ id: String, in shown: TerraformGraph, _ slots: [String: TerraformGraphLayout.Slot]) {
        if shown.node(id) == nil, let kind = graph?.node(id)?.kind { hidden.remove(kind) }
        selection = id
        let slots = TerraformGraphLayout.slots((graph ?? shown).hiding(hidden))
        guard let slot = slots[id] else { return }
        let c = frame(slot)
        withAnimation(.easeOut(duration: 0.25)) {
            pan = CGSize(width: viewport.width / 2 - c.x * zoom, height: viewport.height / 2 - c.y * zoom)
        }
    }

    private func findNext(in shown: TerraformGraph) {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let all = graph?.nodes else { return }
        let matches = all.filter { $0.id.lowercased().contains(q) }
        guard !matches.isEmpty else { return }
        let next = matches.firstIndex { $0.id == selection }.map { matches[($0 + 1) % matches.count] } ?? matches[0]
        select(next.id, in: shown, TerraformGraphLayout.slots(shown))
    }
}

// MARK: - Pieces

/// A block: the service's symbol, its label, the block's name and its address. Data sources have a dashed outline:
/// they only read.
struct DiagramNode: View {
    let node: TerraformGraph.Node
    let style: TerraformNodeStyle
    var isSelected = false
    var isDimmed = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.tile))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(style.label.uppercased()).font(.system(size: 10, weight: .medium)).tracking(0.6)
                        .foregroundStyle(.secondary)
                    if let repeated = node.repeated {
                        Text(repeated).font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Palette.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.tile)).foregroundStyle(Palette.accent)
                    }
                }
                Text(node.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Text(node.kind == .resource || node.kind == .data ? node.type : node.moduleSource ?? node.file)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel).strokeBorder(
            isSelected ? Palette.accent : Color.primary.opacity(0.14),
            style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: node.kind == .data ? [4, 3] : [])))
        .overlay(alignment: .leading) { Port().offset(x: -4) }
        .overlay(alignment: .trailing) { Port().offset(x: 4) }
        .shadow(color: .black.opacity(isSelected ? 0.18 : 0.06), radius: isSelected ? 8 : 3, y: 1)
        .opacity(isDimmed ? 0.35 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Radius.panel))
        .help("\(node.id)\n\(node.file):\(node.line)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.label) \(node.name), \(node.id)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private struct Port: View {
        var body: some View {
            Circle().fill(Color(nsColor: .controlBackgroundColor)).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.3)))
        }
    }
}

/// Curves from each dependency's right side to the left side of the block that uses it.
struct DiagramEdges: View {
    let edges: [TerraformGraph.Edge]
    let centers: [String: CGPoint]
    let focus: String?

    var body: some View {
        Canvas { context, _ in
            let half = TerraformDiagramView.nodeSize.width / 2
            for e in edges {
                guard let a = centers[e.from], let b = centers[e.to] else { continue }
                let start = CGPoint(x: a.x + half + 4, y: a.y), end = CGPoint(x: b.x - half - 4, y: b.y)
                let bend = max(abs(end.x - start.x) / 2, 40)
                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y), control2: CGPoint(x: end.x - bend, y: end.y))
                let lit = focus == e.from || focus == e.to
                let color: Color = lit ? Palette.accent : .primary.opacity(focus == nil ? 0.28 : 0.08)
                context.stroke(path, with: .color(color), lineWidth: lit ? 2 : 1.2)
            }
        }
    }
}

/// A quiet dot grid behind the diagram, so moving it reads as moving.
private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 22
            var dots = Path()
            for x in stride(from: step / 2, to: size.width, by: step) {
                for y in stride(from: step / 2, to: size.height, by: step) {
                    dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                }
            }
            context.fill(dots, with: .color(.primary.opacity(0.09)))
        }
    }
}

/// The selected block: what it is, where it is written, what it uses and what uses it, its code and its documentation.
private struct DiagramInspector: View {
    let node: TerraformGraph.Node
    let graph: TerraformGraph
    let folder: URL
    let root: URL
    let onSelect: (String) -> Void
    let onOpenModule: (TerraformGraph.Node) -> Void

    var body: some View {
        let style = TerraformNodeStyle.of(node)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: style.symbol).font(.system(size: 16, weight: .medium)).frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.tile))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name).font(Typo.panelTitle).lineLimit(2)
                        Text(node.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    row("Kind", node.kind == .data ? "Data source (read only)" : style.label)
                    row("File", "\(node.file), line \(node.line)")
                    if let repeated = node.repeated { row("Instances", "Several, with \(repeated)") }
                    if let source = node.moduleSource { row("Source", source) }
                }
                HStack(spacing: 8) {
                    if node.kind == .module, let source = node.moduleSource, TerraformDocs.localModule(source, from: folder, root: root) != nil {
                        Button("Open Module") { onOpenModule(node) }.buttonStyle(.borderedProminent)
                    }
                    if let url = node.moduleSource.flatMap(TerraformDocs.url(moduleSource:)) ?? TerraformDocs.url(type: node.type, kind: node.kind) {
                        Link(destination: url) { Label("Terraform Docs", systemImage: "book") }
                            .help(url.absoluteString)
                    }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(node.file)]) } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal \(node.file) in Finder")
                }
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
                            if let n = graph.node(id) { Image(systemName: TerraformNodeStyle.of(n).symbol).frame(width: 16) }
                            Text(id).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
            }
        }
    }
}
