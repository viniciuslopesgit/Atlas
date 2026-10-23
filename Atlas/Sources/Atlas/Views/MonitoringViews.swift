import SwiftUI
import Charts

// MARK: - CloudWatch

struct CloudWatchView: View {
    @EnvironmentObject private var state: AppState
    @State private var alarms: [CloudWatchAlarm] = []
    @State private var filter = "ALL"
    @State private var search = ""
    @State private var isLoading = false
    @State private var error: String?

    private var visible: [CloudWatchAlarm] {
        alarms.filter { (filter == "ALL" || $0.state == filter)
            && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.metricName.localizedCaseInsensitiveContains(search)) }
    }

    private func color(_ s: String) -> Color {
        s == "ALARM" ? Palette.danger : s == "OK" ? Palette.success : Palette.warning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "CloudWatch Alarms", subtitle: "\(state.region)")
            HStack(spacing: 14) {
                StatCard(title: "In alarm", value: "\(alarms.filter { $0.state == "ALARM" }.count)",
                         icon: "bell.badge.fill", tint: Palette.danger)
                StatCard(title: "OK", value: "\(alarms.filter { $0.state == "OK" }.count)",
                         icon: "checkmark.circle.fill", tint: Palette.success)
                StatCard(title: "Insufficient data", value: "\(alarms.filter { $0.state == "INSUFFICIENT_DATA" }.count)",
                         icon: "questionmark.circle.fill", tint: Palette.warning)
            }
            HStack {
                TextField("Search alarms", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Picker("State", selection: $filter) {
                    ForEach(["ALL", "ALARM", "OK", "INSUFFICIENT_DATA"], id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                }
                .frame(width: 220)
            }
            if let error { ErrorBanner(message: error) { self.error = nil } }
            Table(visible) {
                TableColumn("State") { a in Badge(text: a.state, color: color(a.state)) }.width(min: 110, ideal: 150)
                TableColumn("Name", value: \.name)
                TableColumn("Metric") { a in Text("\(a.namespace) · \(a.metricName)") }
                TableColumn("Description", value: \.description)
                TableColumn("Updated") { a in Text(Fmt.dt(a.updatedAt)) }.width(min: 130, ideal: 160)
            }
            .overlay {
                if isLoading && alarms.isEmpty { ProgressView() }
                else if !isLoading && alarms.isEmpty && error == nil {
                    EmptyStateView(icon: "bell.slash", title: "No alarms", message: "No metric alarms in \(state.region).")
                }
            }
        }
        .padding(24)
        .task(id: state.sessionKey) {
            guard let client = state.client else { return }
            isLoading = true
            defer { isLoading = false }
            do { alarms = try await CloudWatchService(client: client).alarms(); error = nil }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

// MARK: - GuardDuty

struct GuardDutyView: View {
    @EnvironmentObject private var state: AppState
    @State private var findings: [GuardDutyFinding] = []
    @State private var selection: String?
    @State private var isLoading = false
    @State private var error: String?

    private func color(_ f: GuardDutyFinding) -> Color {
        f.severity >= 7 ? Palette.danger : f.severity >= 4 ? Palette.warning : Palette.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "GuardDuty Findings", subtitle: "Active (non-archived) findings · \(state.region)")
            HStack(spacing: 14) {
                StatCard(title: "High", value: "\(findings.filter { $0.severity >= 7 }.count)",
                         icon: "exclamationmark.octagon.fill", tint: Palette.danger)
                StatCard(title: "Medium", value: "\(findings.filter { $0.severity >= 4 && $0.severity < 7 }.count)",
                         icon: "exclamationmark.triangle.fill", tint: Palette.warning)
                StatCard(title: "Low", value: "\(findings.filter { $0.severity < 4 }.count)", icon: "info.circle.fill")
            }
            if let error { ErrorBanner(message: error) { self.error = nil } }
            Table(findings, selection: $selection) {
                TableColumn("Severity") { f in Badge(text: "\(f.severityLabel) \(String(format: "%.1f", f.severity))", color: color(f)) }
                    .width(min: 100, ideal: 120)
                TableColumn("Title", value: \.title)
                TableColumn("Type", value: \.type)
                TableColumn("Resource", value: \.resourceType).width(min: 90, ideal: 120)
                TableColumn("Updated") { f in Text(Fmt.dt(f.updatedAt)) }.width(min: 130, ideal: 160)
            }
            .overlay {
                if isLoading && findings.isEmpty { ProgressView() }
                else if !isLoading && findings.isEmpty && error == nil {
                    EmptyStateView(icon: "checkmark.shield", title: "No active findings",
                                   message: "GuardDuty has no active findings in \(state.region), or no detector is enabled.")
                }
            }
        }
        .padding(24)
        .inspector(isPresented: .constant(selection != nil)) {
            if let f = findings.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Badge(text: f.severityLabel, color: color(f))
                        Text(f.title).font(.title3.weight(.semibold))
                        Text(f.description).textSelection(.enabled)
                        DetailRow("Type", f.type, copyable: true)
                        DetailRow("Resource", f.resourceType)
                        DetailRow("Account", f.accountId)
                        DetailRow("Region", f.region)
                        DetailRow("Finding ID", f.id, copyable: true)
                        DetailRow("Updated", Fmt.dt(f.updatedAt))
                    }
                    .padding(16)
                }
                .inspectorColumnWidth(min: 300, ideal: 360)
            }
        }
        .task(id: state.sessionKey) {
            guard let client = state.client else { return }
            isLoading = true
            defer { isLoading = false }
            do { findings = try await GuardDutyService(client: client).findings(); error = nil }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

// MARK: - Security audit

struct SecurityAuditView: View {
    @EnvironmentObject private var state: AppState
    @State private var result: SecurityAuditResult?
    @State private var isRunning = false

    private func color(_ s: FindingSeverity) -> Color {
        switch s {
        case .critical: Palette.danger
        case .warning: Palette.warning
        case .ok: Palette.success
        }
    }

    private func icon(_ s: FindingSeverity) -> String {
        switch s {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .ok: "checkmark.circle.fill"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Security Quick Audit",
                           subtitle: result.map { "\($0.summaryText) · \(Fmt.dt($0.auditedAt))" }
                               ?? "IAM, root account, EC2 IMDS and S3 public access checks") {
                    Button {
                        Task { await run() }
                    } label: {
                        if isRunning { ProgressView().controlSize(.small) } else { Label("Run Audit", systemImage: "play.fill") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
                }

                if let r = result {
                    HStack(spacing: 14) {
                        StatCard(title: "Critical", value: "\(r.criticalCount)", icon: icon(.critical), tint: color(.critical))
                        StatCard(title: "Warnings", value: "\(r.warningCount)", icon: icon(.warning), tint: color(.warning))
                        StatCard(title: "Passed", value: "\(r.okCount)", icon: icon(.ok), tint: color(.ok))
                    }
                    ForEach(r.findings) { f in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon(f.severity)).foregroundStyle(color(f.severity)).font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(f.title).font(.body.weight(.semibold))
                                    if let n = f.affectedCount, f.severity != .ok { Badge(text: "\(n)", color: color(f.severity)) }
                                }
                                Text(f.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .card()
                    }
                } else if !isRunning {
                    EmptyStateView(icon: "checkmark.shield", title: "Run a security audit",
                                   message: "Checks root keys and MFA, password policy, inactive users, key rotation, IMDSv1 and S3 Block Public Access.")
                }
            }
            .padding(24)
        }
        .overlay { LoadingOverlay(isLoading: isRunning && result == nil) }
        .onChange(of: state.sessionKey) { result = nil }
    }

    private func run() async {
        guard let client = state.client else { return }
        isRunning = true
        result = await SecurityAuditService(client: client).run()
        isRunning = false
    }
}

// MARK: - Billing

struct BillingView: View {
    @EnvironmentObject private var state: AppState
    @State private var report: BillingReport?
    @State private var months = 6
    @State private var groupBy = "SERVICE"
    @State private var isLoading = false
    @State private var error: String?

    private let groupOptions = [("SERVICE", "Service"), ("LINKED_ACCOUNT", "Account"), ("REGION", "Region"),
                                ("USAGE_TYPE", "Usage type"), ("INSTANCE_TYPE", "Instance type")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Billing", subtitle: "Blended cost from Cost Explorer") {
                    Picker("Group by", selection: $groupBy) {
                        ForEach(groupOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .frame(width: 200)
                    Picker("Period", selection: $months) {
                        Text("3 months").tag(3)
                        Text("6 months").tag(6)
                        Text("12 months").tag(12)
                    }
                    .frame(width: 140)
                }
                if let error { ErrorBanner(message: error) { self.error = nil } }

                if let r = report {
                    StatCard(title: "Total for period", value: Fmt.money(r.grandTotal, r.currency), icon: "dollarsign.circle")
                        .frame(maxWidth: 320)
                    VStack(alignment: .leading) {
                        SectionHeader("Monthly cost")
                        Chart(r.entries) { e in
                            BarMark(x: .value("Month", e.month, unit: .month), y: .value("Cost", e.amount))
                                .foregroundStyle(by: .value("Group", e.service))
                        }
                        .chartForegroundStyleScale(domain: r.topServices)
                        .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in
                            AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                        } }
                        .frame(height: 300)
                    }
                    .padding(16)
                    .card()

                    breakdownTable(r)
                }
            }
            .padding(24)
        }
        .overlay { LoadingOverlay(isLoading: isLoading && report == nil) }
        .task(id: "\(state.sessionKey)|\(months)|\(groupBy)") { await load() }
    }

    private func breakdownTable(_ r: BillingReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Breakdown")
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    ForEach(r.monthLabels, id: \.self) { Text($0).font(.caption.weight(.semibold)) }
                    Text("Total").font(.caption.weight(.semibold))
                }
                Divider()
                ForEach(r.topServices, id: \.self) { svc in
                    let rows = r.entries.filter { $0.service == svc }
                    GridRow {
                        Text(svc).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
                        ForEach(r.monthLabels, id: \.self) { m in
                            Text(Fmt.money(rows.first { $0.monthLabel == m }?.amount ?? 0, r.currency)).monospacedDigit()
                        }
                        Text(Fmt.money(rows.reduce(0) { $0 + $1.amount }, r.currency)).monospacedDigit().fontWeight(.semibold)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(16)
        .card()
    }

    private func load() async {
        guard let client = state.client else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let firstThis = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        let start = cal.date(byAdding: .month, value: -(months - 1), to: firstThis)!
        let end = cal.startOfDay(for: Date())
        isLoading = true
        defer { isLoading = false }
        do {
            report = try await CostService(client: client).breakdown(start: start, end: end, groupBy: groupBy)
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Search (⌘K)

struct SearchSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search instances, buckets, IAM users and roles…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { Task { await search() } }
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(14)
            Divider()
            List(results) { r in
                Button {
                    state.page = switch r.kind {
                    case .ec2: .ec2
                    case .s3: .s3
                    case .iamUser, .iamRole: .iam
                    }
                    dismiss()
                } label: {
                    HStack {
                        Text(r.kind.rawValue).font(.caption.weight(.semibold)).frame(width: 70, alignment: .leading)
                            .foregroundStyle(Palette.accent)
                        VStack(alignment: .leading) {
                            Text(r.title)
                            Text(r.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if results.isEmpty && !isSearching {
                    Text(query.isEmpty ? "Type and press Return to search the active account." : "No results")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("Account: \(state.activeAccount?.name ?? "—") · \(state.region)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 620, height: 440)
    }

    private func search() async {
        guard let client = state.client else { return }
        isSearching = true
        results = await SearchService(client: client).search(query)
        isSearching = false
    }
}
