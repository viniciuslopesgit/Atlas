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
            do {
                try await state.cached("cloudwatch.alarms", show: { alarms = $0 }) { try await CloudWatchService(client: client).alarms() }
                error = nil
            }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

// MARK: - GuardDuty

/// What the GuardDuty page loads, cached together.
private struct GuardDutyPageData {
    var detector: GuardDutyService.Detector?
    var findings: [GuardDutyFinding]
}

struct GuardDutyView: View {
    @EnvironmentObject private var state: AppState
    @State private var detector: GuardDutyService.Detector?
    @State private var findings: [GuardDutyFinding] = []
    @State private var showArchived = false
    @State private var search = ""
    @State private var severity: GuardDutySeverity?
    @State private var type: String?
    @State private var resourceType: String?
    @State private var selection = Set<String>()
    @State private var pendingChange: [GuardDutyFinding]?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var error: String?

    static func color(_ level: GuardDutySeverity) -> Color {
        switch level {
        case .critical, .high: Palette.danger
        case .medium: Palette.warning
        case .low: Palette.neutral
        }
    }

    private var visible: [GuardDutyFinding] {
        GuardDutyFilter(search: search, severity: severity, type: type, resourceType: resourceType).apply(findings)
    }

    private var selected: [GuardDutyFinding] { findings.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "GuardDuty", subtitle: subtitle) {
                Picker("Findings", selection: $showArchived) {
                    Text("Active").tag(false)
                    Text("Archived").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .disabled(detector == nil)
            }
            if let error { ErrorBanner(message: error) { self.error = nil } }
            if hasLoaded && detector == nil && error == nil {
                EmptyStateView(icon: "shield.slash", title: "GuardDuty is not enabled in \(state.region)",
                               message: "GuardDuty works per region: enable it in this region in the AWS console "
                                   + "(GuardDuty › Get started) to see and be notified of its findings here.")
            } else {
                if detector?.enabled == false {
                    Label("GuardDuty is suspended in \(state.region): it keeps its findings but generates no new ones.",
                          systemImage: "pause.circle").font(.callout).foregroundStyle(Palette.warning)
                }
                HStack(spacing: 14) {
                    ForEach(GuardDutySeverity.allCases.reversed()) { level in
                        StatCard(title: level.label, value: "\(findings.filter { $0.level == level }.count)",
                                 icon: "shield.lefthalf.filled", tint: Self.color(level), subtitle: level.range)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                filters
                table
            }
        }
        .padding(24)
        .inspector(isPresented: .constant(selected.count == 1)) {
            if selected.count == 1, let f = selected.first { inspector(f).inspectorColumnWidth(min: 320, ideal: 380) }
        }
        .confirmationDialog(showArchived ? "Unarchive \(pendingChange?.count ?? 0) finding(s)?" : "Archive \(pendingChange?.count ?? 0) finding(s)?",
                            isPresented: Binding(present: $pendingChange), presenting: pendingChange) { items in
            Button(showArchived ? "Unarchive" : "Archive") { Task { await change(items) } }
            Button("Cancel", role: .cancel) {}
        } message: { items in
            Text(items.prefix(8).map(\.title).joined(separator: "\n")
                 + (showArchived ? "\n\nThey become active findings again."
                                 : "\n\nArchived findings leave the active list; GuardDuty still updates them if the activity recurs."))
        }
        .task(id: "\(state.sessionKey)|\(showArchived)") { await load() }
    }

    private var subtitle: String {
        let what = showArchived ? "Archived findings" : "Active findings"
        return detector == nil ? state.region : "\(what) · \(state.region)"
    }

    private var filters: some View {
        HStack {
            TextField("Search title, type or resource", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            Picker("Severity", selection: $severity) {
                Text("All").tag(GuardDutySeverity?.none)
                ForEach(GuardDutySeverity.allCases.reversed()) { Text($0.label).tag(Optional($0)) }
            }
            .frame(width: 160)
            Picker("Type", selection: $type) {
                Text("All").tag(String?.none)
                ForEach(Array(Set(findings.map(\.type))).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            .frame(maxWidth: 280)
            Picker("Resource", selection: $resourceType) {
                Text("All").tag(String?.none)
                ForEach(Array(Set(findings.map(\.resourceType))).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
            }
            .frame(width: 200)
            Spacer()
            Button { pendingChange = selected } label: {
                Label(showArchived ? "Unarchive" : "Archive", systemImage: showArchived ? "tray.and.arrow.up" : "archivebox")
            }
            .disabled(selection.isEmpty)
        }
    }

    private var table: some View {
        Table(visible, selection: $selection) {
            TableColumn("Severity") { f in Badge(text: "\(f.level.label) \(String(format: "%.1f", f.severity))", color: Self.color(f.level)) }
                .width(min: 100, ideal: 120)
            TableColumn("Title", value: \.title).width(min: 200, ideal: 320)
            TableColumn("Type", value: \.type).width(min: 160, ideal: 240)
            TableColumn("Resource") { f in Text(f.resourceLabel).lineLimit(1) }.width(min: 120, ideal: 200)
            TableColumn("Count") { f in Text("\(f.count)").monospacedDigit() }.width(min: 44, ideal: 56)
            TableColumn("Last seen") { f in Text(Fmt.dt(f.lastSeen ?? f.updatedAt)) }.width(min: 130, ideal: 160)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let items = findings.filter { ids.contains($0.id) }
            Button("Copy Finding ID") { copy(items.map(\.id).joined(separator: "\n")) }
            Divider()
            Button(showArchived ? "Unarchive…" : "Archive…") { pendingChange = items }
        }
        .overlay {
            if isLoading && findings.isEmpty { ProgressView() }
            else if hasLoaded && !isLoading && visible.isEmpty && error == nil {
                EmptyStateView(icon: "checkmark.shield",
                               title: findings.isEmpty ? (showArchived ? "No archived findings" : "No active findings") : "No matching findings",
                               message: findings.isEmpty ? "GuardDuty has nothing to report in \(state.region)." : "Change or clear the filters.")
            }
        }
    }

    private func inspector(_ f: GuardDutyFinding) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Badge(text: "\(f.level.label) · \(String(format: "%.1f", f.severity))", color: Self.color(f.level))
                Text(f.title).font(Typo.panelTitle)
                Text(f.description).font(.callout).textSelection(.enabled)
                Text(f.level.meaning).font(.caption).foregroundStyle(.secondary)

                SectionHeader("Overview")
                DetailRow("Type", f.type, copyable: true)
                DetailRow("Threat purpose", f.threatPurpose)
                DetailRow("Count", "\(f.count)")
                DetailRow("First seen", Fmt.dt(f.firstSeen))
                DetailRow("Last seen", Fmt.dt(f.lastSeen))
                DetailRow("Created", Fmt.dt(f.createdAt))
                DetailRow("Updated", Fmt.dt(f.updatedAt))
                DetailRow("Account", f.accountId)
                DetailRow("Region", f.region)
                DetailRow("Finding ID", f.id, copyable: true)

                details("Resource · \(f.resourceType)", f.resource)
                details(f.actionType.isEmpty ? "Action" : "Action · \(f.actionType.replacingOccurrences(of: "_", with: " ").capitalized)", f.action)
                details("Actor", f.actor)

                Button(f.archived ? "Unarchive…" : "Archive…") { pendingChange = [f] }.padding(.top, 6)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func details(_ title: String, _ rows: [GuardDutyDetail]) -> some View {
        if !rows.isEmpty {
            SectionHeader(title)
            ForEach(rows, id: \.self) { DetailRow($0.label, $0.value, copyable: true) }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func load(force: Bool = false) async {
        guard let client = state.client else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        let service = GuardDutyService(client: client)
        let archived = showArchived
        do {
            try await state.cached("guardduty|\(archived)", force: force, show: { (loaded: GuardDutyPageData) in
                detector = loaded.detector
                findings = loaded.findings
                hasLoaded = true
            }) {
                guard let detector = try await service.detector() else { return GuardDutyPageData(detector: nil, findings: []) }
                return GuardDutyPageData(detector: detector,
                                         findings: try await service.findings(detectorId: detector.id, archived: archived))
            }
            selection = selection.filter { id in findings.contains { $0.id == id } }
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func change(_ items: [GuardDutyFinding]) async {
        guard let client = state.client, let detector else { return }
        let service = GuardDutyService(client: client)
        do {
            let ids = items.map(\.id)
            if showArchived { try await service.unarchive(detectorId: detector.id, ids: ids) }
            else { try await service.archive(detectorId: detector.id, ids: ids) }
            selection.subtract(ids)
            state.cache.removeAll(prefix: "\(state.activeAccount?.id ?? "none")|\(state.region)|guardduty|")
            await load(force: true)
        } catch {
            self.error = "\(showArchived ? "Unarchive" : "Archive") failed: \(error.localizedDescription)"
        }
    }
}

/// The GuardDuty page's filters: severity level, finding type, resource type and free text.
struct GuardDutyFilter {
    var search = ""
    var severity: GuardDutySeverity?
    var type: String?
    var resourceType: String?

    func apply(_ findings: [GuardDutyFinding]) -> [GuardDutyFinding] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return findings.filter { f in
            (severity == nil || f.level == severity) && (type == nil || f.type == type)
                && (resourceType == nil || f.resourceType == resourceType)
                && (q.isEmpty || [f.title, f.type, f.resourceId, f.id].contains { $0.localizedCaseInsensitiveContains(q) })
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
                                    Text(f.title).font(.body.weight(.medium))
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
                    ForEach(r.monthLabels, id: \.self) { Text($0).font(.caption.weight(.medium)) }
                    Text("Total").font(.caption.weight(.medium))
                }
                Divider()
                ForEach(r.topServices, id: \.self) { svc in
                    let rows = r.entries.filter { $0.service == svc }
                    GridRow {
                        Text(svc).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
                        ForEach(r.monthLabels, id: \.self) { m in
                            Text(Fmt.money(rows.first { $0.monthLabel == m }?.amount ?? 0, r.currency)).monospacedDigit()
                        }
                        Text(Fmt.money(rows.reduce(0) { $0 + $1.amount }, r.currency)).monospacedDigit().fontWeight(.medium)
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
        let groupBy = groupBy
        do {
            try await state.cached("billing|\(months)|\(groupBy)", show: { report = $0 }) {
                try await CostService(client: client).breakdown(start: start, end: end, groupBy: groupBy)
            }
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
            List {
                if !pageMatches.isEmpty {
                    Section("Pages") {
                        ForEach(pageMatches) { page in
                            Button { state.page = page; dismiss() } label: {
                                Label(page.title, systemImage: page.icon).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section(results.isEmpty ? "" : "Resources") {
                ForEach(results) { r in
                Button {
                    state.page = switch r.kind {
                    case .ec2: .ec2
                    case .s3: .s3
                    case .iamUser, .iamRole: .iam
                    }
                    dismiss()
                } label: {
                    HStack {
                        Text(r.kind.rawValue).font(.caption.weight(.medium)).frame(width: 70, alignment: .leading)
                            .foregroundStyle(Palette.accent)
                        VStack(alignment: .leading) {
                            Text(r.title)
                            Text(r.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                }
                }
            }
            .overlay {
                if results.isEmpty && pageMatches.isEmpty && !isSearching {
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

    /// Pages whose title or keywords match, shown while typing.
    private var pageMatches: [Page] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return Page.allCases.filter { p in
            p.title.localizedCaseInsensitiveContains(q) || p.keywords.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private func search() async {
        guard let client = state.client else { return }
        isSearching = true
        results = await SearchService(client: client).search(query)
        isSearching = false
    }
}
