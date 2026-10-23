import SwiftUI
import AppKit

struct StacksView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", drifted = "Drifted", failed = "Failed", running = "Running"
        var id: String { rawValue }
    }

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var model: StacksModel
    @State private var selection: UUID?
    @State private var filter: Filter = .all
    @State private var showNew = false

    private var visible: [StackEntry] {
        model.stacks.filter { s in
            switch filter {
            case .all: true
            case .drifted: s.driftStatus == .drifted
            case .failed: s.status == .failed || s.driftStatus == .error
            case .running: model.busy.contains(s.id)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Stacks", subtitle: "Terraform stacks with run history and drift checks") {
                Button { showNew = true } label: { Label("New Stack…", systemImage: "plus") }
                    .disabled(state.activeAccount == nil)
            }
            HStack(spacing: 14) {
                StatCard(title: "Ready", value: "\(model.stacks.filter { [.ready, .finished].contains($0.status) }.count)",
                         icon: "checkmark.circle.fill", tint: Palette.success)
                StatCard(title: "Running", value: "\(model.busy.count)", icon: "play.circle.fill", tint: Palette.accent)
                StatCard(title: "Drifted", value: "\(model.stacks.filter { $0.driftStatus == .drifted && !$0.driftAcknowledged }.count)",
                         icon: "arrow.triangle.branch", tint: Palette.warning)
                StatCard(title: "Failed", value: "\(model.stacks.filter { $0.status == .failed }.count)",
                         icon: "xmark.octagon.fill", tint: Palette.danger)
            }
            .frame(height: 74)
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            if model.stacks.isEmpty {
                EmptyStateView(icon: "square.stack.3d.up", title: "No stacks yet",
                               message: "A stack is a Terraform folder that Atlas plans, applies and checks for drift. Start one from a folder, then import existing resources into it.") {
                    Button("New Stack…") { showNew = true }.buttonStyle(.borderedProminent).disabled(state.activeAccount == nil)
                }
            } else {
                HSplitView {
                    List(visible, selection: $selection) { s in StackRow(stack: s, isBusy: model.busy.contains(s.id)).tag(s.id) }
                        .frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
                    Group {
                        if let id = selection, let s = model.stack(id) {
                            StackDetail(stack: s)
                        } else {
                            EmptyStateView(icon: "sidebar.left", title: "Select a stack", message: "Its runs, drift and variables appear here.")
                        }
                    }
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(24)
        .sheet(isPresented: $showNew) {
            NewStackSheet(runtime: model.runtime) { name, folder, engine in
                guard let account = state.activeAccount else { return }
                selection = model.create(name: name, folder: folder, accountId: account.id, region: state.region, engine: engine).id
            }
        }
        .onAppear { if selection == nil { selection = model.stacks.first?.id } }
    }
}

private struct StackRow: View {
    let stack: StackEntry
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(stack.name).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                if isBusy { ProgressView().controlSize(.mini) }
            }
            HStack(spacing: 6) {
                StackBadges(stack: stack)
                if let run = stack.lastRun { Text(Fmt.dt(run.startedAt)).font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 3)
    }
}

struct StackBadges: View {
    let stack: StackEntry

    var body: some View {
        switch stack.driftStatus {
        case .drifted: Badge(text: stack.driftAcknowledged ? "Drift acknowledged" : "Drifted", color: Palette.warning)
        case .clean: Badge(text: "In sync", color: Palette.success)
        case .checking: Badge(text: "Checking", color: Palette.accent)
        case .error: Badge(text: "Check failed", color: Palette.danger)
        case .unknown:
            if stack.status == .failed { Badge(text: "Failed", color: Palette.danger) }
            else { Badge(text: stack.status == .finished ? "Finished" : "Ready", color: Palette.neutral) }
        }
    }
}

// MARK: - Detail

private struct StackDetail: View {
    enum Tab: String, CaseIterable, Identifiable {
        case drift = "Drift", runs = "Runs", variables = "Variables", settings = "Settings"
        var id: String { rawValue }
    }

    let stack: StackEntry
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var model: StacksModel
    @State private var tab: Tab = .drift
    @State private var confirm: Confirm?
    @State private var showImport = false
    @State private var remoteState = true

    enum Confirm: Identifiable {
        case apply, fixDrift, delete
        var id: Self { self }
    }

    private var busy: Bool { model.busy.contains(stack.id) }
    private var accountName: String { state.accounts.first { $0.id == stack.accountId }?.name ?? "missing account" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stack.name).font(Typo.pageTitle)
                    Text("\(stack.projectPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · \(accountName) · \(stack.region)")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                StackBadges(stack: stack)
                Button { NSWorkspace.shared.activateFileViewerSelecting([stack.url]) } label: { Image(systemName: "folder") }
                    .help("Reveal in Finder")
            }
            HStack(spacing: 8) {
                Group {
                    Button("Init") { model.initialize(stack.id) }
                    Button("Plan") { model.plan(stack.id) }
                    Button("Apply…") { confirm = .apply }.disabled(!model.hasSavedPlan(stack))
                        .help("Applies the plan saved by the last Plan.")
                    Button("Check Drift") { model.checkDrift(stack.id) }
                    Button { showImport = true } label: { Label("Import from AWS…", systemImage: "square.and.arrow.down") }
                        .disabled(state.client(accountId: stack.accountId, region: stack.region) == nil)
                }
                .disabled(busy)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", role: .cancel) { model.cancel(stack.id) }
                }
            }
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            switch tab {
            case .drift: DriftTab(stack: stack, onFix: { confirm = .fixDrift })
            case .runs: RunsTab(stack: stack)
            case .variables: VariablesTab(stack: stack)
            case .settings: settings
            }
        }
        .padding(.leading, 16)
        .confirmationDialog(title, isPresented: Binding(present: $confirm), presenting: confirm) { c in
            switch c {
            case .apply: Button("Apply", role: .destructive) { model.apply(stack.id) }
            case .fixDrift: Button("Fix Drift", role: .destructive) { model.fixDrift(stack.id) }
            case .delete: Button("Remove Stack", role: .destructive) { model.delete(stack.id) }
            }
        } message: { c in
            switch c {
            case .apply, .fixDrift:
                Text("Terraform will change real resources in \(accountName) (\(stack.region)) as the saved plan shows.")
            case .delete:
                Text("Atlas forgets the stack, its runs and its Keychain variables, and removes its container. The folder and the resources in AWS are not touched.")
            }
        }
        .sheet(isPresented: $showImport) {
            if let client = state.client(accountId: stack.accountId, region: stack.region) {
                VStack(spacing: 0) {
                    ImportFromAwsSheet(client: client, region: stack.region, targetName: stack.name, offerGenerate: false) { chosen, _ in
                        model.importResources(stack.id, chosen, remoteState: remoteState)
                        tab = .runs
                    }
                    Toggle("Keep the state in S3 (atlas-tfstate-<account>, versioned and encrypted)", isOn: $remoteState)
                        .padding([.horizontal, .bottom], 20)
                }
            }
        }
    }

    private var title: String {
        switch confirm {
        case .apply: "Apply the saved plan to \(stack.name)?"
        case .fixDrift: "Fix the drift in \(stack.name)?"
        case .delete: "Remove \(stack.name) from Atlas?"
        case nil: ""
        }
    }

    private var settings: some View {
        Form {
            DetailRow("Folder", stack.projectPath, copyable: true)
            DetailRow("Account", accountName)
            DetailRow("Region", stack.region)
            DetailRow("Created", Fmt.dt(stack.createdAt))
            Picker("Engine", selection: Binding(get: { stack.engine }, set: { model.setEngine($0, for: stack.id) })) {
                ForEach(TerraformEngine.allCases) { Text($0.label).tag($0) }
            }
            .disabled(busy)
            if let container = model.container(for: stack) {
                DetailRow("Container", container.name, copyable: true)
                DetailRow("Runtime", container.runtime.kind.rawValue)
                DetailRow("Image", stack.engine.image)
            } else {
                DetailRow("Runs on", "This Mac (no container runtime)")
                RuntimeSetupHint()
            }
            Button("Remove Stack…", role: .destructive) { confirm = .delete }.disabled(busy)
        }
        .formStyle(.grouped)
    }
}

private struct DriftTab: View {
    let stack: StackEntry
    let onFix: () -> Void
    @EnvironmentObject private var model: StacksModel
    @State private var newCron = ""

    private var cronValid: Bool { CronExpression(newCron) != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stack.driftSummary ?? headline).font(Typo.panelTitle)
                        Text(stack.lastDriftCheckAt.map { "Last checked \(Fmt.dt($0))" } ?? "Never checked")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if stack.driftStatus == .drifted {
                        if !stack.driftAcknowledged { Button("Acknowledge") { model.acknowledgeDrift(stack.id) } }
                        Button("Fix Drift…", action: onFix).buttonStyle(.borderedProminent).disabled(model.busy.contains(stack.id))
                    }
                }
                if let diff = stack.driftDiff {
                    TerminalPanel(lines: diff.components(separatedBy: "\n").enumerated().map { IaCModel.Line(id: $0.offset, text: $0.element) })
                } else {
                    EmptyStateView(icon: stack.driftStatus == .clean ? "checkmark.seal" : "arrow.triangle.branch",
                                   title: stack.driftStatus == .clean ? "No drift" : "No drift report",
                                   message: stack.driftStatus == .clean
                                       ? "The infrastructure matched the configuration at the last check."
                                       : "Check Drift runs terraform plan and shows what changed outside Terraform.")
                        .card(radius: Radius.tile)
                }
            }
            schedule.frame(width: 260)
        }
    }

    private var headline: String {
        switch stack.driftStatus {
        case .clean: "In sync"
        case .drifted: "Drifted"
        case .checking: "Checking…"
        case .error: "The last check failed"
        case .unknown: "Drift not checked yet"
        }
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Schedule")
            Picker("Every", selection: Binding(get: { stack.driftInterval },
                                               set: { v in model.update(stack.id) { $0.driftInterval = v } })) {
                ForEach(DriftInterval.allCases) { Text($0.label).tag($0) }
            }
            ForEach(stack.driftCron, id: \.self) { expr in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(expr).font(.callout.monospaced())
                        if let next = CronExpression(expr)?.next(after: Date()) {
                            Text("Next \(Fmt.dt(next))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { model.update(stack.id) { $0.driftCron.removeAll { $0 == expr } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Cron", text: $newCron, prompt: Text("0 8 * * 1-5"))
                    .font(.callout.monospaced())
                    .onSubmit(addCron)
                Button("Add", action: addCron).disabled(!cronValid)
            }
            Text("Five fields in local time: minute hour day month weekday.")
                .font(.caption).foregroundStyle(.secondary)
            if let next = stack.nextDriftCheck(), stack.driftEnabled {
                Text("Next check \(Fmt.dt(next)) while Atlas is open.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Fix drift automatically", isOn: Binding(get: { stack.autoFixOnDrift },
                                                            set: { v in model.update(stack.id) { $0.autoFixOnDrift = v } }))
            Text("Applies the drift plan without asking. Leave it off unless the configuration is the source of truth.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .card(radius: Radius.tile)
    }

    private func addCron() {
        let expr = newCron.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard CronExpression(expr) != nil, !stack.driftCron.contains(expr) else { return }
        model.update(stack.id) { $0.driftCron.append(expr) }
        newCron = ""
    }
}

private struct RunsTab: View {
    let stack: StackEntry
    @State private var selected: UUID?

    private var run: StackRun? { stack.runs.first { $0.id == selected } ?? stack.runs.first }

    var body: some View {
        if stack.runs.isEmpty {
            EmptyStateView(icon: "clock", title: "No runs yet", message: "Init, Plan, Apply, drift checks and imports are recorded here.")
        } else {
            VSplitView {
                Table(stack.runs, selection: $selected) {
                    TableColumn("Status") { r in Badge(text: r.status.rawValue.capitalized, color: color(r.status)) }.width(90)
                    TableColumn("Run") { r in Text(label(r.type)) }.width(min: 80, ideal: 100)
                    TableColumn("Trigger", value: \.trigger)
                    TableColumn("Started") { r in Text(Fmt.dt(r.startedAt)) }.width(min: 130, ideal: 150)
                    TableColumn("Duration") { r in Text(r.durationText) }.width(70)
                }
                .frame(minHeight: 120, idealHeight: 170)
                TerminalPanel(lines: (run?.output ?? "").components(separatedBy: "\n").enumerated()
                    .map { IaCModel.Line(id: $0.offset, text: $0.element) })
                    .frame(minHeight: 160)
            }
        }
    }

    private func label(_ t: StackRunType) -> String {
        switch t {
        case .importResources: "Import"
        case .initialize: "Init"
        case .fix: "Fix"
        case .plan: "Plan"
        case .apply: "Apply"
        case .fixDrift: "Fix drift"
        case .setup: "Container"
        }
    }

    private func color(_ s: StackRunStatus) -> Color {
        switch s {
        case .running: Palette.accent
        case .success: Palette.success
        case .failed: Palette.danger
        case .cancelled: Palette.neutral
        }
    }
}

private struct VariablesTab: View {
    let stack: StackEntry
    @EnvironmentObject private var model: StacksModel
    @State private var drafts: [String: String] = [:]

    var body: some View {
        if stack.envVars.isEmpty {
            EmptyStateView(icon: "key", title: "No variables",
                           message: "Values hardcoded in imported resources (Lambda environment, for example) are moved here, kept in the Keychain and passed to terraform as TF_VAR_….")
        } else {
            Form {
                ForEach(stack.envVars) { v in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(v.tfVarName).font(.callout.monospaced())
                            Text("\(v.envKey) · \(v.resourceType).\(v.resourceName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        SecureField("Value", text: Binding(get: { drafts[v.id] ?? v.value }, set: { drafts[v.id] = $0 }))
                            .frame(width: 220)
                        Button("Save") {
                            let value = drafts[v.id] ?? v.value
                            model.update(stack.id) { s in
                                if let i = s.envVars.firstIndex(where: { $0.id == v.id }) { s.envVars[i].value = value }
                            }
                            drafts[v.id] = nil
                        }
                        .disabled(drafts[v.id] == nil)
                        Button { model.removeEnvVar(v, from: stack.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// How to get a container runtime, shown while stacks run on this Mac.
private struct RuntimeSetupHint: View {
    @State private var showSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To run each stack in its own isolated container, install Docker Desktop (OrbStack, Colima and Apple's container work too). Atlas finds it on its own and downloads the Terraform or OpenTofu image.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Install Docker Desktop…") { showSetup = true }
        }
        .sheet(isPresented: $showSetup) { DockerSetupSheet() }
    }
}

private struct NewStackSheet: View {
    let runtime: ContainerRuntime?
    let onCreate: (String, URL, TerraformEngine) -> Void
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder: URL?
    @State private var engine: TerraformEngine = .terraform

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Stack").font(Typo.pageTitle)
            Form {
                TextField("Name", text: $name, prompt: Text("production-network"))
                LabeledContent("Folder") {
                    HStack {
                        Text(folder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "None").foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: choose)
                    }
                }
                LabeledContent("Account", value: state.activeAccount?.name ?? "—")
                LabeledContent("Region", value: state.region)
                Picker("Engine", selection: $engine) { ForEach(TerraformEngine.allCases) { Text($0.label).tag($0) } }
                LabeledContent("Runs in", value: runtime.map { "Its own container (\($0.kind.rawValue))" } ?? "This Mac")
            }
            .formStyle(.grouped)
            Text("\(engine.label) runs with this account's credentials in this region, also for scheduled drift checks.")
                .font(.caption).foregroundStyle(.secondary)
            if runtime == nil { RuntimeSetupHint() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    if let folder { onCreate(name.trimmingCharacters(in: .whitespaces), folder, engine) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || folder == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the stack's folder: existing Terraform configuration, or an empty folder."
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            if name.isEmpty { name = url.lastPathComponent }
        }
    }
}
