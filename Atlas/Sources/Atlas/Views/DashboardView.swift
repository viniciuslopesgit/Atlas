import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if state.activeAccount == nil {
            EmptyStateView(icon: "person.crop.circle.badge.plus", title: "No AWS account",
                           message: "Add an account in Settings to see its costs and resources here.") {
                Button("Open Settings") { state.page = .settings }
            }
        } else {
            DashboardPage(store: state.dashboardLayout)
        }
    }
}

private struct DashboardPage: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: DashboardLayoutStore
    @State private var resources: DashboardSummary?
    @State private var costs: CostService.MonthCosts?
    @State private var costError: String?
    @State private var pending: Set<DashboardSource> = []
    @State private var month = CostMonth.containing(Date())
    @State private var customizing = false
    @State private var width: CGFloat = 0
    /// The account and region the shown resources belong to; another one never shows them.
    @State private var resourcesContext = ""
    @State private var costsContext = ""

    private var layout: DashboardLayout { store.layout }
    private var account: String { state.activeAccount?.id ?? "none" }
    private var resourceSources: Set<DashboardSource> { layout.sources.subtracting([.costs]) }
    private var showsCosts: Bool { layout.sources.contains(.costs) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Dashboard", subtitle: subtitle) {
                    if showsCosts {
                        Picker("Month", selection: $month) {
                            ForEach(CostMonth.recent(12)) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    Button { customizing.toggle() } label: { Label("Customize", systemImage: "slider.horizontal.3") }
                        .help("Choose and order the cards")
                        .popover(isPresented: $customizing, arrowEdge: .bottom) { DashboardCustomizer(store: store) }
                }

                if layout.visible.isEmpty {
                    EmptyStateView(icon: "square.grid.2x2", title: "No cards shown",
                                   message: "Choose the cards the dashboard shows.") {
                        Button("Customize…") { customizing = true }
                    }
                } else {
                    DashboardBody(summary: summary, layout: layout, width: width, pending: pending,
                                  open: { state.page = $0 },
                                  hide: { store.layout.setVisible($0, false) },
                                  move: { store.layout.move($0, by: $1) })
                }
            }
            .padding(24)
            .background(GeometryReader { g in Color.clear.preference(key: DashboardWidthKey.self, value: g.size.width - 48) })
        }
        .onPreferenceChange(DashboardWidthKey.self) { width = $0 }
        .task(id: "\(state.sessionKey)|\(resourceSources.sorted().map(\.rawValue))") { await loadResources() }
        .task(id: "\(account)|\(state.refreshToken)|\(month.id)|\(showsCosts)") { await loadCosts() }
    }

    private var summary: DashboardSummary {
        var s = resources ?? DashboardSummary()
        s.costs = costs
        s.errors[.costs] = costError
        s.month = month
        if s.region.isEmpty { s.region = state.region }
        return s
    }

    private var subtitle: String {
        var parts = [state.activeAccount?.name ?? ""]
        if let id = resources?.identity?.account, !id.isEmpty { parts.append(id) }
        parts.append(RegionItem.label(state.region))
        if let r = resources { parts.append("updated at \(r.lastRefreshed.formatted(date: .omitted, time: .shortened))") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func loadResources() async {
        guard let client = state.client else { return }
        let context = "\(account)|\(state.region)"
        if context != resourcesContext { resources = nil; resourcesContext = context }
        let sources = resourceSources
        guard !sources.isEmpty else { return }
        pending.formUnion(sources)
        defer { pending.subtract(sources) }
        try? await state.cached("dashboard|\(sources.sorted().map(\.rawValue).joined(separator: ","))",
                                show: { resources = $0 }) {
            await DashboardService(client: client).resources(sources)
        }
    }

    private func loadCosts() async {
        guard showsCosts, let client = state.client else { return }
        let context = "\(account)|\(month.id)"
        if context != costsContext { costs = nil; costError = nil; costsContext = context }
        pending.insert(.costs)
        defer { pending.remove(.costs) }
        do {
            // Cost Explorer is global and billed per request: one entry per account and month, whatever the region.
            try await state.cached("dashboard|costs|\(month.id)", regional: false,
                                   show: { costs = $0; costError = nil }) {
                try await DashboardService(client: client).costs(month)
            }
        } catch {
            if !Task.isCancelled { costError = error.localizedDescription }
        }
    }
}

private struct DashboardWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension DashboardLayout {
    static let spacing: CGFloat = 16

    /// Columns for a row of `count` cards of `size` in `width` points: never more than the cards, at least one.
    static func columns(_ size: DashboardCard.Size, count: Int, width: CGFloat) -> Int {
        let minimum: CGFloat = switch size {
        case .wide: .infinity
        case .half: 340
        case .tile: 170
        }
        guard minimum.isFinite, width > 0 else { return 1 }
        let fit = Int((width + spacing) / (minimum + spacing))
        return max(1, min(count, fit))
    }
}

/// Everything below the header; takes plain data so it can also be rendered by the snapshot mode.
struct DashboardBody: View {
    let summary: DashboardSummary
    let layout: DashboardLayout
    let width: CGFloat
    var pending: Set<DashboardSource> = []
    var open: ((Page) -> Void)?
    var hide: ((DashboardCard) -> Void)?
    var move: ((DashboardCard, Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardLayout.spacing) {
            ForEach(layout.rows) { row in
                let n = DashboardLayout.columns(row.size, count: row.cards.count, width: width)
                // Rows of n cards of the same height; a short last row keeps the columns' width.
                ForEach(Array(stride(from: 0, to: row.cards.count, by: n)), id: \.self) { start in
                    let cards = Array(row.cards[start..<min(start + n, row.cards.count)])
                    HStack(alignment: .top, spacing: DashboardLayout.spacing) {
                        ForEach(cards) { cardView($0) }
                        ForEach(cards.count..<n, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func cardView(_ card: DashboardCard) -> some View {
        let visible = layout.visible
        DashboardPanel(card: card,
                       error: summary.errors[card.source],
                       isLoading: pending.contains(card.source),
                       open: card.page.flatMap { page in open.map { f in { f(page) } } },
                       hide: hide.map { f in { f(card) } },
                       moveEarlier: visible.first == card ? nil : move.map { f in { f(card, -1) } },
                       moveLater: visible.last == card ? nil : move.map { f in { f(card, 1) } }) {
            content(card)
        }
    }

    @ViewBuilder private func content(_ card: DashboardCard) -> some View {
        let s = summary
        switch card {
        case .spend:
            if let c = s.costs { SpendStrip(costs: c, month: s.month, compact: width > 0 && width < 620) } else { placeholder(height: 92) }
        case .dailyCost:
            if let c = s.costs { DailyCostChart(costs: c, month: s.month) } else { placeholder(height: 200) }
        case .topServices:
            if let c = s.costs { TopServices(costs: c) } else { placeholder(height: 200) }
        case .instances:
            if let i = s.instances {
                DashboardFigure(value: "\(i.running)", label: "running", detail: Self.instanceDetail(i, region: s.region))
            } else { placeholder() }
        case .buckets:
            if let n = s.bucketCount { DashboardFigure(value: "\(n)", label: n == 1 ? "bucket" : "buckets", detail: "All regions") }
            else { placeholder() }
        case .alarms:
            if let n = s.activeAlarms {
                DashboardFigure(value: "\(n)", label: "in alarm", detail: n == 0 ? "All clear in \(s.region)" : "In \(s.region)",
                                tint: n > 0 ? Palette.danger : nil)
            } else { placeholder() }
        case .account:
            if let id = s.identity { AccountSummary(identity: id, region: s.region) } else { placeholder() }
        }
    }

    static func instanceDetail(_ i: InstanceCounts, region: String) -> String {
        var details = ["\(i.stopped) stopped"]
        if i.changing > 0 { details.append("\(i.changing) starting or stopping") }
        details.append("\(i.total) in \(region)")
        return details.joined(separator: " · ")
    }

    private func placeholder(height: CGFloat = 52) -> some View {
        Text("—").font(Typo.figure(28)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            .accessibilityLabel(pending.isEmpty ? "No data" : "Loading")
    }
}

/// A card's frame: title, a link to its page, loading and error states, and the menu to hide or move it.
private struct DashboardPanel<Content: View>: View {
    let card: DashboardCard
    var error: String?
    var isLoading: Bool
    var open: (() -> Void)?
    var hide: (() -> Void)?
    var moveEarlier: (() -> Void)?
    var moveLater: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(card.title).font(Typo.sectionTitle).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if isLoading { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
                if let open, let page = card.page {
                    Button(action: open) { Image(systemName: "arrow.up.right").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .help("Open \(page.title)")
                }
            }
            if let error, !isLoading {
                Label { Text("Couldn't load: \(error)").lineLimit(4) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                }
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help(error)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .contextMenu {
            if let hide { Button("Hide \(card.title)", action: hide) }
            if let moveEarlier { Button("Move Earlier", action: moveEarlier) }
            if let moveLater { Button("Move Later", action: moveLater) }
        }
    }
}

private struct DashboardFigure: View {
    let value: String
    let label: String
    let detail: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(Typo.figure(28)).foregroundStyle(tint ?? .primary)
                Text(label).font(.callout).foregroundStyle(.secondary)
            }
            Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AccountSummary: View {
    let identity: StsService.Identity
    let region: String

    /// "user/alice" or "assumed-role/Admin/session" from the ARN.
    private var principal: String {
        identity.arn.split(separator: ":", maxSplits: 5).last.map(String.init) ?? identity.arn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(identity.account).font(Typo.figure(20)).textSelection(.enabled)
                CopyButton(value: identity.account)
            }
            Text(principal).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .help(identity.arn)
            Text(region).font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// The month's spend on a bar scaled to the forecast, with a tick at the previous month's total.
struct SpendStrip: View {
    let costs: CostService.MonthCosts
    let month: CostMonth
    var compact = false

    private var scale: Double { max(costs.forecast ?? 0, costs.last, costs.current, 1) }
    private var previous: String { month.adding(-1).title }

    /// The forecast (or, for a month that ended, its total) against the month before.
    private var change: (text: String, color: Color)? {
        guard costs.last > 0 else { return nil }
        let value = costs.forecast ?? costs.current
        let pct = (value - costs.last) / costs.last * 100
        let text = String(format: "%@%@%.0f%% against %@", costs.forecast == nil ? "" : "Forecast ",
                          pct >= 0 ? "+" : "", pct, previous)
        return (text, pct > 5 ? Palette.danger : pct < -5 ? Palette.success : Palette.neutral)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if compact {
                VStack(alignment: .leading, spacing: 10) { figures }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 32) { figures; Spacer(minLength: 0) }
            }
            if let change { Text(change.text).font(.caption).foregroundStyle(change.color) }

            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08))
                    if let forecast = costs.forecast {
                        Rectangle().fill(Palette.accent.opacity(0.3)).frame(width: w * forecast / scale)
                    }
                    Rectangle().fill(Palette.accent).frame(width: max(2, w * costs.current / scale))
                    if costs.last > 0 {
                        Rectangle().fill(Color.primary.opacity(0.6))
                            .frame(width: 1, height: 12)
                            .offset(x: min(w - 2, w * costs.last / scale))
                    }
                }
            }
            .frame(height: 3)
            .accessibilityElement()
            .accessibilityLabel(accessibility)
        }
    }

    @ViewBuilder private var figures: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(costs.isCurrent ? "Spent so far" : "Spent in \(month.title)").font(.callout).foregroundStyle(.secondary)
            Text(Fmt.money(costs.current, costs.currency)).font(Typo.figure(40, weight: .ultraLight))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        if let forecast = costs.forecast { figure("Forecast", forecast, color: .primary) }
        figure(previous, costs.last, color: .secondary)
    }

    private var accessibility: String {
        let spent = "Spent \(Fmt.money(costs.current, costs.currency))"
        return costs.forecast.map { "\(spent) of a forecast of \(Fmt.money($0, costs.currency))" } ?? spent
    }

    private func figure(_ title: String, _ value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(Fmt.money(value, costs.currency)).font(Typo.figure(20, weight: .light)).foregroundStyle(color)
        }
    }
}

private struct DailyCostChart: View {
    let costs: CostService.MonthCosts
    let month: CostMonth

    private var days: [DailyCost] { costs.daily }
    private var peak: DailyCost? { days.max { $0.amount < $1.amount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if days.isEmpty || days.allSatisfy({ $0.amount == 0 }) {
                Text("No cost in \(month.title).").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                chart.frame(height: 200)
                if let peak {
                    let average = costs.current / Double(max(days.count, 1))
                    Text("\(Fmt.money(average, costs.currency)) a day on average · highest \(Fmt.money(peak.amount, costs.currency)) on \(peak.date.formatted(.dateTime.day().month(.abbreviated)))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder private var chart: some View {
        if #available(macOS 13, *) {
            let start = month.start(in: .current)
            let end = month.adding(1).start(in: .current)
            Chart(days) { d in
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Cost", d.amount))
                    .foregroundStyle(Palette.accent.opacity(0.7))
                    .cornerRadius(1)
            }
            .chartXScale(domain: start...end)
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            } }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.money(d, costs.currency)) } }
            } }
        } else {
            // macOS 12 has no Swift Charts: plain bars, one per day of the month.
            let top = max(peak?.amount ?? 1, 0.01)
            GeometryReader { g in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(days) { d in
                        Rectangle().fill(Palette.accent.opacity(0.7))
                            .frame(height: max(1, g.size.height * max(d.amount, 0) / top))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

private struct TopServices: View {
    let costs: CostService.MonthCosts
    static let shown = 6

    var body: some View {
        let services = costs.services
        let total = services.reduce(0) { $0 + $1.amount }
        let top = services.prefix(Self.shown)
        let rest = services.dropFirst(Self.shown)
        let maxAmount = max(services.first?.amount ?? 1, 0.01)
        VStack(alignment: .leading, spacing: 10) {
            if services.isEmpty {
                Text("No service costs.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            }
            ForEach(Array(top)) { svc in
                row(svc.serviceName, svc.amount, share: svc.amount / max(total, 0.01), bar: svc.amount / maxAmount)
            }
            if !rest.isEmpty {
                let amount = rest.reduce(0) { $0 + $1.amount }
                row("\(rest.count) more \(rest.count == 1 ? "service" : "services")", amount,
                    share: amount / max(total, 0.01), bar: amount / maxAmount, muted: true)
            }
        }
    }

    private func row(_ name: String, _ amount: Double, share: Double, bar: Double, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(muted ? .secondary : .primary).help(name)
                Spacer(minLength: 8)
                Text(share.formatted(.percent.precision(.fractionLength(0)))).font(.caption).foregroundStyle(.tertiary)
                Text(Fmt.money(amount, costs.currency)).font(Typo.figure(13, weight: .regular)).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                Rectangle().fill(muted ? Color.primary.opacity(0.18) : Palette.accent.opacity(0.6))
                    .frame(width: max(2, g.size.width * min(bar, 1)))
            }
            .frame(height: 2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Which cards are shown, and in what order.
struct DashboardCustomizer: View {
    @ObservedObject var store: DashboardLayoutStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Customize Dashboard").font(Typo.panelTitle)
            Text("Choose the cards to show and drag them into order.").font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(store.layout.order) { card in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(get: { store.layout.isVisible(card) },
                                             set: { store.layout.setVisible(card, $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(card.title)
                                Text(card.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: 0)
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to reorder")
                    }
                    .padding(.vertical, 2)
                }
                .onMove { store.layout.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(width: 360, height: 320)
            HStack {
                Button("Restore Defaults") { store.reset() }.disabled(store.layout == .standard)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
