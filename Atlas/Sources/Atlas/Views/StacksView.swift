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
                               message: "A stack is a Terraform folder that Atlas plans, applies and checks for drift. Start one from a folder, then import existing resources into it from Infrastructure as Code.") {
                    Button("New Stack…") { showNew = true }.buttonStyle(.borderedProminent).disabled(state.activeAccount == nil)
                }
            } else {
                HSplitView {
                    List(visible, selection: $selection) { s in StackRow(stack: s, isBusy: model.busy.contains(s.id)).tag(s.id) }
                        .frame(minWidth: 230, idealWidth: 270, maxWidth: 360)
                    Group {
                        if let id = selection, let s = model.stack(id) {
                            StackDetail(stack: s).id(s.id)
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
            NewStackSheet(runtime: model.runtime) { name, folder, engine, remoteState in
                guard let account = state.activeAccount else { return }
                selection = model.create(name: name, folder: folder, accountId: account.id, region: state.region, engine: engine,
                                         remoteState: remoteState).id
            }
        }
        .onAppear {
            if let focus = model.focus { selection = focus; model.focus = nil }
            if selection == nil { selection = model.stacks.first?.id }
        }
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
                if StateBackend.hasLocalState(in: stack.url) && !StateBackend.hasBackend(in: stack.url) {
                    Badge(text: "Local state", color: Palette.warning)
                }
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
        case runs = "Runs", plans = "Plans", applies = "Applies", drift = "Drift", variables = "Variables", settings = "Settings"
        var id: String { rawValue }

        var scope: StackRunScope? {
            switch self {
            case .runs: .all
            case .plans: .plans
            case .applies: .applies
            default: nil
            }
        }
    }

    let stack: StackEntry
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var model: StacksModel
    @State private var tab: Tab = .runs
    /// The run whose timeline is open in the runs tabs.
    @State private var openRun: UUID?
    @State private var confirm: Confirm?

    enum Confirm: Identifiable {
        case apply, fixDrift, delete, moveState
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
                    Button("Init") { start(.runs) { model.initialize(stack.id) } }
                    Button("Plan") { start(.plans) { model.plan(stack.id) } }
                    Button("Apply…") { confirm = .apply }.disabled(!model.hasSavedPlan(stack))
                        .help("Applies the plan saved by the last Plan.")
                    Button("Check Drift") { start(.plans) { model.checkDrift(stack.id) } }
                }
                .disabled(busy)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", role: .cancel) { model.cancel(stack.id) }
                }
            }
            if StateBackend.hasLocalState(in: stack.url) {
                LocalStateWarning(isBusy: busy, hasBackend: StateBackend.hasBackend(in: stack.url)) { confirm = .moveState }
            }
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 560)
            Group {
                if let scope = tab.scope {
                    if let id = openRun, let run = stack.runs.first(where: { $0.id == id }) {
                        StackRunDetail(run: run, stackName: stack.name) { openRun = nil }
                    } else {
                        StackRunList(runs: stack.runs, scope: scope) { openRun = $0 }
                    }
                } else {
                    switch tab {
                    case .drift: DriftTab(stack: stack, onFix: { confirm = .fixDrift })
                    case .variables: VariablesTab(stack: stack)
                    default: settings
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.leading, 16)
        .confirmationDialog(title, isPresented: Binding(present: $confirm), presenting: confirm) { c in
            switch c {
            case .apply: Button("Apply", role: .destructive) { start(.applies) { model.apply(stack.id) } }
            case .fixDrift: Button("Fix Drift", role: .destructive) { start(.applies) { model.fixDrift(stack.id) } }
            case .delete: Button("Remove Stack", role: .destructive) { model.delete(stack.id) }
            case .moveState: Button("Move State to S3") { start(.runs) { model.moveStateToS3(stack.id) } }
            }
        } message: { c in
            switch c {
            case .apply, .fixDrift:
                Text("Terraform will change real resources in \(accountName) (\(stack.region)) as the saved plan shows.")
            case .delete:
                Text("Atlas forgets the stack, its runs and its Keychain variables, and removes its container. The folder and the resources in AWS are not touched.")
            case .moveState:
                Text("Atlas copies the state to the atlas-tfstate bucket of \(accountName) (versioned, encrypted), checks it can be read there, then removes terraform.tfstate and its backup from the stack's folder. Resources in AWS are not changed.")
            }
        }
    }

    /// Runs the action and, when it recorded a new run, opens that run's timeline in `tab`.
    private func start(_ tab: Tab, _ action: () -> Void) {
        let before = model.stack(stack.id)?.lastRun?.id
        action()
        guard let run = model.stack(stack.id)?.lastRun, run.id != before else { return }
        self.tab = tab
        openRun = run.id
    }

    private var title: String {
        switch confirm {
        case .apply: "Apply the saved plan to \(stack.name)?"
        case .fixDrift: "Fix the drift in \(stack.name)?"
        case .delete: "Remove \(stack.name) from Atlas?"
        case .moveState: "Move the state of \(stack.name) to S3?"
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
    let onCreate: (String, URL, TerraformEngine, Bool) -> Void
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder: URL?
    @State private var engine: TerraformEngine = .terraform
    @State private var remoteState = true

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
                Toggle("Keep the state in S3 (atlas-tfstate-<account>, versioned and encrypted)", isOn: $remoteState)
                    .help("The state holds every resource's values in plain text; in S3 it is encrypted and never in the stack's folder.")
            }
            .formStyle(.grouped)
            Text("\(engine.label) runs with this account's credentials in this region, also for scheduled drift checks.")
                .font(.caption).foregroundStyle(.secondary)
            if runtime == nil { RuntimeSetupHint() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    if let folder { onCreate(name.trimmingCharacters(in: .whitespaces), folder, engine, remoteState) }
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

/// The stack's state is a plain-text file in its folder: every resource's values, readable by anything that can read it.
/// With a backend (an S3 bucket of its own, say), the file is a leftover the engine no longer reads: Atlas does not move
/// or delete it, it only says so.
private struct LocalStateWarning: View {
    let isBusy: Bool
    let hasBackend: Bool
    let onMove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Palette.warning)
            Text(hasBackend
                 ? "The configuration's backend keeps the state, but an old terraform.tfstate is still in the folder, in plain text. It is not used; check it and delete it."
                 : "This stack keeps its state in terraform.tfstate, in plain text in its folder. It holds every resource's values, secrets included.")
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if !hasBackend { Button("Move State to S3…", action: onMove).disabled(isBusy) }
        }
        .padding(10)
        .card(radius: Radius.tile)
    }
}
