import Foundation

// MARK: - Dashboard

struct DailyCost: Identifiable, Hashable {
    let date: Date
    let amount: Double
    var id: Date { date }
}

struct ServiceCost: Identifiable, Hashable {
    let serviceName: String
    let amount: Double
    var id: String { serviceName }
}

/// A calendar month as Cost Explorer counts it. Kept as year and month, not a `Date`: the first of a month at
/// local midnight is the previous month in UTC east of Greenwich, which asked Cost Explorer for the wrong month.
struct CostMonth: Hashable, Identifiable, Comparable {
    let year: Int
    let month: Int

    var id: String { String(format: "%04d-%02d", year, month) }

    init(year: Int, month: Int) {
        let index = year * 12 + (month - 1)
        self.year = Int((Double(index) / 12).rounded(.down))
        self.month = index - self.year * 12 + 1
    }

    static func containing(_ date: Date, calendar: Calendar = .current) -> CostMonth {
        let c = calendar.dateComponents([.year, .month], from: date)
        return CostMonth(year: c.year!, month: c.month!)
    }

    func adding(_ months: Int) -> CostMonth { CostMonth(year: year, month: month + months) }

    /// This month and the ones before it, newest first.
    static func recent(_ count: Int, now: Date = Date(), calendar: Calendar = .current) -> [CostMonth] {
        let current = containing(now, calendar: calendar)
        return (0..<count).map { current.adding(-$0) }
    }

    /// Midnight of the first day in `calendar`'s time zone.
    func start(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    /// "October 2026", in the Mac's language.
    var title: String { start(in: .current).formatted(.dateTime.month(.wide).year()) }

    static func < (a: CostMonth, b: CostMonth) -> Bool { (a.year, a.month) < (b.year, b.month) }
}

/// The page's cards, in their default order.
enum DashboardCard: String, CaseIterable, Identifiable {
    case spend, instances, buckets, alarms, account, dailyCost, topServices

    var id: String { rawValue }

    /// How much room a card takes: the whole row, half of it, or a tile among several.
    enum Size { case wide, half, tile }

    var title: String {
        switch self {
        case .spend: "Month spend"
        case .instances: "EC2 instances"
        case .buckets: "S3 buckets"
        case .alarms: "CloudWatch alarms"
        case .account: "Account"
        case .dailyCost: "Daily cost"
        case .topServices: "Top services"
        }
    }

    var detail: String {
        switch self {
        case .spend: "Spent so far, forecast and last month"
        case .instances: "Running and stopped in the selected region"
        case .buckets: "Buckets in the account, all regions"
        case .alarms: "Alarms in the ALARM state in the selected region"
        case .account: "Account ID and the identity Atlas signs in as"
        case .dailyCost: "Cost per day of the selected month"
        case .topServices: "Where the month's money went"
        }
    }

    var icon: String {
        switch self {
        case .spend: "dollarsign.circle"
        case .instances: "server.rack"
        case .buckets: "archivebox"
        case .alarms: "bell"
        case .account: "person.crop.circle"
        case .dailyCost: "chart.bar"
        case .topServices: "list.number"
        }
    }

    var size: Size {
        switch self {
        case .spend: .wide
        case .dailyCost, .topServices: .half
        case .instances, .buckets, .alarms, .account: .tile
        }
    }

    var source: DashboardSource {
        switch self {
        case .spend, .dailyCost, .topServices: .costs
        case .instances: .ec2
        case .buckets: .s3
        case .alarms: .alarms
        case .account: .identity
        }
    }

    /// The page the card opens.
    var page: Page? {
        switch self {
        case .spend, .dailyCost, .topServices: .billing
        case .instances: .ec2
        case .buckets: .s3
        case .alarms: .cloudWatch
        case .account: nil
        }
    }
}

/// What the dashboard asks AWS for; only the sources of the cards shown are loaded.
enum DashboardSource: String, CaseIterable, Comparable {
    case costs, ec2, s3, alarms, identity

    var name: String {
        switch self {
        case .costs: "Cost Explorer"
        case .ec2: "EC2 instances"
        case .s3: "S3 buckets"
        case .alarms: "CloudWatch alarms"
        case .identity: "STS identity"
        }
    }

    static func < (a: DashboardSource, b: DashboardSource) -> Bool { a.rawValue < b.rawValue }
}

/// Which cards the dashboard shows, and in what order.
struct DashboardLayout: Equatable, Codable {
    private(set) var order: [DashboardCard]
    private(set) var hidden: Set<DashboardCard>

    /// Everything but the account card, which repeats what the header says.
    static let standard = DashboardLayout(order: DashboardCard.allCases, hidden: [.account])

    init(order: [DashboardCard], hidden: Set<DashboardCard>) {
        self.order = order
        self.hidden = hidden
        normalize()
    }

    var visible: [DashboardCard] { order.filter { !hidden.contains($0) } }
    var sources: Set<DashboardSource> { Set(visible.map(\.source)) }
    func isVisible(_ card: DashboardCard) -> Bool { !hidden.contains(card) }

    mutating func setVisible(_ card: DashboardCard, _ visible: Bool) {
        if visible { hidden.remove(card) } else { hidden.insert(card) }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { order[$0] }
        let before = source.filter { $0 < destination }.count
        order.removeAll { moving.contains($0) }
        order.insert(contentsOf: moving, at: min(destination - before, order.count))
    }

    /// Moves `card` one step among the visible cards (`offset` -1 or +1), past any hidden ones in between.
    mutating func move(_ card: DashboardCard, by offset: Int) {
        let shown = visible
        guard let i = shown.firstIndex(of: card), shown.indices.contains(i + offset),
              let from = order.firstIndex(of: card), let to = order.firstIndex(of: shown[i + offset]) else { return }
        order.remove(at: from)
        order.insert(card, at: to)
    }

    /// Cards Atlas no longer has are dropped; ones added since the layout was saved go at the end, shown.
    private mutating func normalize() {
        var seen = Set<DashboardCard>()
        order = order.filter { seen.insert($0).inserted }
        order += DashboardCard.allCases.filter { !seen.contains($0) }
    }

    /// Runs of cards laid out together: tiles share a row, half cards go two by two, wide ones alone.
    struct Row: Equatable, Identifiable {
        let size: DashboardCard.Size
        let cards: [DashboardCard]
        var id: String { cards.map(\.rawValue).joined(separator: ",") }
    }

    var rows: [Row] {
        var rows: [Row] = []
        for card in visible {
            if card.size != .wide, let last = rows.last, last.size == card.size {
                rows[rows.count - 1] = Row(size: card.size, cards: last.cards + [card])
            } else {
                rows.append(Row(size: card.size, cards: [card]))
            }
        }
        return rows
    }

    // Saved as names, so a file from another version still opens.
    private enum Keys: String, CodingKey { case order, hidden }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let order = try c.decode([String].self, forKey: .order).compactMap(DashboardCard.init(rawValue:))
        let hidden = try c.decode([String].self, forKey: .hidden).compactMap(DashboardCard.init(rawValue:))
        self.init(order: order, hidden: Set(hidden))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(order.map(\.rawValue), forKey: .order)
        try c.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
    }
}

/// The dashboard layout of this Mac user, in Atlas's folder; the default when there is none or it can't be read.
@MainActor
final class DashboardLayoutStore: ObservableObject {
    @Published var layout: DashboardLayout {
        didSet { if layout != oldValue { save() } }
    }
    private let file: URL

    init(folder: URL) {
        file = folder.appendingPathComponent("dashboard.json")
        layout = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(DashboardLayout.self, from: $0) }
            ?? .standard
    }

    func reset() { layout = .standard }

    private func save() {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        try? PrivateFile.createFolder(file.deletingLastPathComponent())
        try? PrivateFile.write(data, to: file)
    }
}

struct InstanceCounts: Equatable {
    var running = 0
    var stopped = 0
    /// Starting, stopping or shutting down.
    var changing = 0
    /// Every instance but the terminated ones, which EC2 still lists for about an hour.
    var total: Int { running + stopped + changing }

    init(running: Int = 0, stopped: Int = 0, changing: Int = 0) {
        self.running = running
        self.stopped = stopped
        self.changing = changing
    }

    init(_ instances: [Ec2Instance]) {
        for i in instances {
            switch i.state {
            case "running": running += 1
            case "stopped": stopped += 1
            case "terminated": break
            default: changing += 1
            }
        }
    }
}

/// What the dashboard loaded. A source that was not asked for, or failed, has no value: the card says so
/// instead of showing a zero that looks real.
struct DashboardSummary {
    var instances: InstanceCounts?
    var bucketCount: Int?
    var activeAlarms: Int?
    var identity: StsService.Identity?
    var costs: CostService.MonthCosts?
    var month = CostMonth.containing(Date())
    var region = ""
    var lastRefreshed = Date()
    /// Why each failed source could not be loaded.
    var errors: [DashboardSource: String] = [:]
}
