import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @State private var summary: DashboardSummary?
    @State private var isLoading = false
    @State private var month = Date()
    @State private var showWarnings = false

    private var monthOptions: [Date] {
        let cal = Calendar.current
        let first = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        return (0..<12).compactMap { cal.date(byAdding: .month, value: -$0, to: first) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Dashboard", subtitle: subtitle) {
                    Picker("Month", selection: $month) {
                        ForEach(monthOptions, id: \.self) { Text($0.formatted(.dateTime.month(.wide).year())).tag($0) }
                    }
                    .frame(width: 200)
                }

                if let s = summary, !s.warnings.isEmpty {
                    DisclosureGroup(isExpanded: $showWarnings) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(s.warnings, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("\(s.warnings.count) data source(s) could not be loaded — check IAM permissions",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.warning)
                    }
                    .padding(10)
                    .card()
                }

                DashboardBody(summary: summary ?? DashboardSummary())
            }
            .padding(24)
        }
        .overlay { LoadingOverlay(isLoading: isLoading && summary == nil) }
        .task(id: "\(state.sessionKey)|\(month)") { await load() }
    }

    private var subtitle: String {
        guard let s = summary else { return "Loading…" }
        let account = s.accountId.isEmpty ? "unknown account" : "Account \(s.accountId)"
        return "\(account) in \(RegionItem.displayName(s.region)), updated at \(s.lastRefreshed.formatted(date: .omitted, time: .shortened))"
    }

    private func load() async {
        guard let client = state.client else { return }
        isLoading = true
        let result = await DashboardService(client: client).summary(month: month)
        if !Task.isCancelled { summary = result }
        isLoading = false
    }
}

/// Everything below the header; takes plain data so it can also be rendered by the snapshot mode.
struct DashboardBody: View {
    let summary: DashboardSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            let s = summary
            SpendStrip(summary: s)

            HStack(spacing: 24) {
                StatCard(title: "Instances running", value: "\(s.runningInstances)", icon: "play.fill",
                         tint: Palette.neutral, subtitle: "of \(s.totalInstances) in this region")
                StatCard(title: "Instances stopped", value: "\(s.stoppedInstances)", icon: "stop.fill", tint: Palette.neutral)
                StatCard(title: "S3 buckets", value: "\(s.s3BucketCount)", icon: "archivebox.fill")
                StatCard(title: "Alarms firing", value: "\(s.activeAlarms)", icon: "bell.fill",
                         tint: s.activeAlarms > 0 ? Palette.danger : Palette.neutral)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 40) {
                dailyChart(s).frame(maxWidth: .infinity)
                serviceList(s).frame(width: 320)
            }
        }
    }

    private func dailyChart(_ s: DashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Daily cost")
            if s.dailyCosts.isEmpty {
                Text("No cost data for this period.").foregroundStyle(.secondary).frame(height: 220)
            } else {
                Chart(s.dailyCosts) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Cost", d.amount))
                        .foregroundStyle(Color.primary.opacity(0.22))
                        .cornerRadius(1)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                } }
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.money(d, s.currency)) } }
                } }
                .frame(height: 240)
            }
        }
    }

    private func serviceList(_ s: DashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Top services")
            if s.serviceCosts.isEmpty {
                Text("No service costs.").foregroundStyle(.secondary)
            }
            let maxAmount = s.serviceCosts.first?.amount ?? 1
            ForEach(s.serviceCosts.prefix(8)) { svc in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(svc.serviceName).font(.callout).lineLimit(1)
                        Spacer()
                        Text(Fmt.money(svc.amount, s.currency)).font(Typo.figure(13, weight: .regular)).foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        Rectangle().fill(Color.primary.opacity(0.22))
                            .frame(width: max(2, g.size.width * svc.amount / maxAmount))
                    }
                    .frame(height: 2)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

}

/// The dashboard's lead: month-to-date spend on a bar scaled to the forecast, with a tick at last month's total.
struct SpendStrip: View {
    let summary: DashboardSummary

    private var scale: Double { max(summary.forecastedMonthCost, summary.lastMonthCost, summary.currentMonthCost, 1) }

    private var change: (text: String, color: Color)? {
        guard summary.lastMonthCost > 0 else { return nil }
        let pct = (summary.forecastedMonthCost - summary.lastMonthCost) / summary.lastMonthCost * 100
        let text = String(format: "%@%.0f%% against last month", pct >= 0 ? "+" : "", pct)
        return (text, pct > 5 ? Palette.danger : pct < -5 ? Palette.success : Palette.neutral)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spent this month").font(.callout).foregroundStyle(.secondary)
                    Text(Fmt.money(summary.currentMonthCost, summary.currency)).font(Typo.figure(52, weight: .ultraLight))
                }
                figure("Forecast", summary.forecastedMonthCost, color: .primary)
                figure("Last month", summary.lastMonthCost, color: .secondary)
                Spacer()
                if let change {
                    Text(change.text).font(.callout).foregroundStyle(change.color)
                }
            }

            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08))
                    Rectangle().fill(Palette.accent.opacity(0.3))
                        .frame(width: w * summary.forecastedMonthCost / scale)
                    Rectangle().fill(Palette.accent)
                        .frame(width: max(2, w * summary.currentMonthCost / scale))
                    if summary.lastMonthCost > 0 {
                        Rectangle().fill(Color.primary.opacity(0.6))
                            .frame(width: 1, height: 12)
                            .offset(x: min(w - 2, w * summary.lastMonthCost / scale))
                    }
                }
            }
            .frame(height: 3)
            .accessibilityElement()
            .accessibilityLabel("Spent \(Fmt.money(summary.currentMonthCost, summary.currency)) of a forecast of \(Fmt.money(summary.forecastedMonthCost, summary.currency))")
        }
    }

    private func figure(_ title: String, _ value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(Fmt.money(value, summary.currency)).font(Typo.figure(20, weight: .light)).foregroundStyle(color)
        }
    }
}
