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

                let s = summary ?? DashboardSummary()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                    StatCard(title: "EC2 Running", value: "\(s.runningInstances)", icon: "play.circle.fill",
                             tint: Palette.success, subtitle: "\(s.totalInstances) total")
                    StatCard(title: "EC2 Stopped", value: "\(s.stoppedInstances)", icon: "stop.circle.fill", tint: Palette.danger)
                    StatCard(title: "S3 Buckets", value: "\(s.s3BucketCount)", icon: "archivebox.fill")
                    StatCard(title: "Active Alarms", value: "\(s.activeAlarms)", icon: "bell.badge.fill",
                             tint: s.activeAlarms > 0 ? Palette.danger : .secondary)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                    StatCard(title: "Month to date", value: Fmt.money(s.currentMonthCost, s.currency), icon: "dollarsign.circle")
                    StatCard(title: "Forecast", value: Fmt.money(s.forecastedMonthCost, s.currency),
                             icon: "chart.line.uptrend.xyaxis", tint: Palette.warning)
                    StatCard(title: "Previous month", value: Fmt.money(s.lastMonthCost, s.currency),
                             icon: "calendar", tint: .secondary, subtitle: delta(s))
                }

                HStack(alignment: .top, spacing: 14) {
                    dailyChart(s).frame(maxWidth: .infinity)
                    serviceList(s).frame(width: 340)
                }
            }
            .padding(24)
        }
        .overlay { LoadingOverlay(isLoading: isLoading && summary == nil) }
        .task(id: "\(state.sessionKey)|\(month)") { await load() }
    }

    private var subtitle: String {
        guard let s = summary else { return "Loading…" }
        let account = s.accountId.isEmpty ? "unknown account" : "Account \(s.accountId)"
        return "\(account) · \(RegionItem.displayName(s.region)) · updated \(s.lastRefreshed.formatted(date: .omitted, time: .standard))"
    }

    private func delta(_ s: DashboardSummary) -> String? {
        guard s.lastMonthCost > 0 else { return nil }
        let pct = (s.forecastedMonthCost - s.lastMonthCost) / s.lastMonthCost * 100
        return String(format: "Forecast %@%.0f%% vs previous", pct >= 0 ? "+" : "", pct)
    }

    private func dailyChart(_ s: DashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Daily cost")
            if s.dailyCosts.isEmpty {
                Text("No cost data for this period.").foregroundStyle(.secondary).frame(height: 220)
            } else {
                Chart(s.dailyCosts) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Cost", d.amount))
                        .foregroundStyle(Color.accentColor.gradient)
                        .cornerRadius(3)
                }
                .chartYAxis { AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.money(d, s.currency)) } }
                } }
                .frame(height: 240)
            }
        }
        .padding(16)
        .card()
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
                        Text(Fmt.money(svc.amount, s.currency)).font(.callout.monospacedDigit())
                    }
                    GeometryReader { g in
                        Capsule().fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(4, g.size.width * svc.amount / maxAmount))
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private func load() async {
        guard let client = state.client else { return }
        isLoading = true
        let result = await DashboardService(client: client).summary(month: month)
        if !Task.isCancelled { summary = result }
        isLoading = false
    }
}
