import SwiftUI
import AppKit

// MARK: - Model

/// Projects, the running terraform command and its live output.
@MainActor
final class IaCModel: ObservableObject {
    enum Command: String {
        case initialize = "init", validate, plan, apply, output, generate = "generate config"
    }

    enum Status: Equatable {
        case idle, running(Command), succeeded(Command), changes, noChanges, failed(Command, String)
    }

    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    nonisolated static let planFile = "atlas.tfplan"
    nonisolated static let generatedFile = "generated_resources.tf"
    static let maxLines = 5000

    @Published private(set) var contents: TerraformProjectStore.Contents
    @Published private(set) var lines: [Line] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var version: String?
    @Published private(set) var cliMissing = false
    /// A saved plan with changes that Apply can run, keyed by project.
    @Published private(set) var reviewedPlan: UUID?

    private let store: TerraformProjectStore
    private var cli = TerraformCLI()
    private var task: Task<Void, Never>?
    private var nextLine = 0

    init(store: TerraformProjectStore = TerraformProjectStore()) {
        self.store = store
        contents = store.load()
    }

    var projects: [TerraformProject] { contents.projects }
    var active: TerraformProject? { contents.projects.first { $0.id == contents.activeId } }
    var isRunning: Bool { if case .running = status { true } else { false } }

    func loadVersion() async {
        cli = TerraformCLI()
        cliMissing = cli.binary == nil
        version = cliMissing ? nil : await cli.version()
    }

    // MARK: Projects

    func select(_ id: UUID?) {
        guard contents.activeId != id else { return }
        contents.activeId = id
        store.save(contents)
        lines = []
        status = .idle
    }

    func add(folder: URL) {
        if let existing = contents.projects.first(where: { $0.path == folder.path }) { select(existing.id); return }
        Self.scaffoldIfEmpty(folder)
        let p = TerraformProject(name: folder.lastPathComponent, path: folder.path)
        contents.projects.append(p)
        contents.activeId = p.id
        store.save(contents)
        lines = []
        status = .idle
    }

    /// Forgets the project and its saved plan; its folder is left as it is.
    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: store.planFolder(id))
        contents.projects.removeAll { $0.id == id }
        if contents.activeId == id { contents.activeId = contents.projects.first?.id }
        store.save(contents)
    }

    /// An empty folder gets the AWS provider so `init` works straight away.
    static func scaffoldIfEmpty(_ folder: URL) {
        let tf = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".tf") } ?? []
        guard tf.isEmpty else { return }
        let providers = """
        # Created by Atlas. Credentials and region come from the active Atlas account.
        terraform {
          required_version = ">= 1.5"
          required_providers {
            aws = {
              source  = "hashicorp/aws"
              version = "~> 5.0"
            }
          }
        }

        provider "aws" {}

        """
        try? providers.write(to: folder.appendingPathComponent("providers.tf"), atomically: true, encoding: .utf8)
    }

    // MARK: Commands

    func run(_ command: Command, client: AWSClient?) {
        guard let project = active, !isRunning else { return }
        let dir = project.url
        let plans = store.planFolder(project.id)
        let planPath = plans.appendingPathComponent(Self.planFile).path
        do { try PrivateFile.createFolder(plans) } catch {
            status = .failed(command, "Could not prepare the plan folder: \(error.localizedDescription)")
            return
        }
        // Only Atlas's own plan file, which earlier versions saved in plain text in the project's folder.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.planFile))
        let credentials = client.map(TerraformCredentials.init)
        let cli = cli
        lines = []
        status = .running(command)
        echo("$ terraform \(command == .generate ? "plan -generate-config-out=\(Self.generatedFile)" : command == .plan ? "plan -out=\(Self.planFile)" : command.rawValue)")
        if command == .plan || command == .generate { reviewedPlan = nil }

        let onLine: @Sendable (String) -> Void = { [weak self] line in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(line) } }
        }
        task = Task {
            let result: TerraformResult
            switch command {
            case .initialize: result = await cli.initialize(dir, credentials: credentials, onLine: onLine)
            case .validate: result = await cli.validate(dir, onLine: onLine)
            case .plan: result = await cli.plan(dir, outFile: planPath, credentials: credentials, onLine: onLine)
            case .apply:
                result = await cli.apply(dir, planFile: planPath, credentials: credentials, onLine: onLine)
                try? FileManager.default.removeItem(atPath: planPath)
            case .output: result = await cli.output(dir, onLine: onLine)
            case .generate: result = await generateConfig(cli, dir, credentials, onLine)
            }
            // Let the queued output lines land before the status line.
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            finish(command, project.id, result)
        }
    }

    func cancel() { task?.cancel() }

    /// `plan -generate-config-out`, then the 1.0.1 clean-up: fix known provider quirks, split per service, validate.
    private nonisolated func generateConfig(_ cli: TerraformCLI, _ dir: URL, _ credentials: TerraformCredentials?,
                                            _ onLine: @escaping @Sendable (String) -> Void) async -> TerraformResult {
        let plan = await cli.planGeneratingConfig(dir, outFile: Self.generatedFile, credentials: credentials, onLine: onLine)
        let generated = dir.appendingPathComponent(Self.generatedFile)
        guard plan.status != .cancelled, plan.status != .timedOut, FileManager.default.fileExists(atPath: generated.path) else {
            return plan
        }
        do {
            let fixes = try GeneratedHclFixer.fix(file: generated)
            if fixes.total > 0 { onLine("Atlas: fixed \(fixes.total) known issue(s) in the generated configuration.") }
            for (file, count) in try GeneratedHclSplitter.split(file: generated) {
                onLine("Atlas: \(count) resource(s) → \(file)")
            }
        } catch {
            onLine("Atlas: could not post-process \(Self.generatedFile): \(error.localizedDescription)")
        }
        onLine("$ terraform validate")
        return await cli.validate(dir, onLine: onLine)
    }

    private func finish(_ command: Command, _ project: UUID, _ r: TerraformResult) {
        switch r.status {
        case .success: status = .succeeded(command)
        case .planHasChanges:
            status = command == .plan ? .changes : .succeeded(command)
            if command == .plan { reviewedPlan = project }
        case .noChanges: status = command == .plan ? .noChanges : .succeeded(command)
        case .cancelled: status = .failed(command, "Cancelled.")
        case .notFound:
            cliMissing = true
            status = .failed(command, r.diagnostic)
        case .failed, .timedOut: status = .failed(command, r.diagnostic.isEmpty ? "terraform exited with code \(r.exitCode)." : r.diagnostic)
        }
        if command == .apply { reviewedPlan = nil }
        echo(String(format: "Finished in %.1fs", r.duration))
    }

    private func echo(_ text: String) { append(text) }

    private func append(_ text: String) {
        lines.append(Line(id: nextLine, text: text))
        nextLine += 1
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }
}

// MARK: - Page

struct IaCView: View {
    /// Where Import from AWS adds the resources: the open project, or a stack (which imports them in its container).
    enum ImportTarget: Hashable, Identifiable {
        case project, stack(UUID)
        var id: Self { self }
    }

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var stacks: StacksModel
    @StateObject private var model = IaCModel()
    @State private var confirmApply = false
    @State private var importTarget: ImportTarget?
    @State private var remoteState = true
    @State private var notice: String?

    var body: some View {
        HSplitView {
            projectList.frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
            VStack(alignment: .leading, spacing: 12) {
                if model.cliMissing {
                    TerraformMissingView { Task { await model.loadVersion() } }
                } else if let project = model.active {
                    header(project)
                    if let notice { NoticeBanner(message: notice) { self.notice = nil } }
                    actions
                    if case .failed(_, let message) = model.status { ErrorBanner(message: message) }
                    TerminalPanel(lines: model.lines)
                } else {
                    if let notice { NoticeBanner(message: notice) { self.notice = nil } }
                    EmptyStateView(icon: "chevron.left.forwardslash.chevron.right", title: "No Terraform project",
                                   message: "Add a folder with Terraform configuration, or an empty folder to start one.") {
                        HStack {
                            Button("Add Project…", action: chooseFolder).buttonStyle(.borderedProminent)
                            if !stacks.stacks.isEmpty { importMenu }
                        }
                    }
                }
            }
            .padding(24)
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { await model.loadVersion() }
        .confirmationDialog("Apply the reviewed plan?", isPresented: $confirmApply) {
            Button("Apply", role: .destructive) { model.run(.apply, client: state.client) }
        } message: {
            Text("Terraform will change real resources in \(state.activeAccount?.name ?? "the active account") (\(state.region)) exactly as the last plan shows.")
        }
        .sheet(item: $importTarget) { target in importSheet(target) }
    }

    /// Import from AWS, into the open project or into one of the stacks.
    private var importMenu: some View {
        Menu {
            if let project = model.active {
                Button("Into project \(project.name)") { importTarget = .project }
                    .disabled(model.isRunning || state.client == nil)
            }
            if !stacks.stacks.isEmpty {
                Section("Into a stack") {
                    ForEach(stacks.stacks) { s in
                        Button(s.name) { importTarget = .stack(s.id) }
                            .disabled(stacks.busy.contains(s.id) || state.client(accountId: s.accountId, region: s.region) == nil)
                    }
                }
            }
        } label: {
            Label("Import from AWS…", systemImage: "square.and.arrow.down")
        }
        .fixedSize()
        .disabled(model.active == nil && stacks.stacks.isEmpty)
    }

    @ViewBuilder
    private func importSheet(_ target: ImportTarget) -> some View {
        switch target {
        case .project:
            if let client = state.client, let project = model.active {
                ImportFromAwsSheet(client: client, region: state.region, targetName: project.name) { chosen, generate in
                    let files = try TerraformAware.adopt(chosen, into: project.url)
                    let names = files.map(\.lastPathComponent).joined(separator: ", ")
                    notice = "Added \(chosen.count) resource(s) to \(project.name)\(names.isEmpty ? "" : ": \(names)")."
                    if generate { model.run(.generate, client: state.client) }
                }
            }
        case .stack(let id):
            if let stack = stacks.stack(id), let client = state.client(accountId: stack.accountId, region: stack.region) {
                VStack(spacing: 0) {
                    ImportFromAwsSheet(client: client, region: stack.region, targetName: stack.name, offerGenerate: false) { chosen, _ in
                        stacks.importResources(id, chosen, remoteState: remoteState)
                        stacks.focus = id
                        state.page = .stacks
                    }
                    Toggle("Keep the state in S3 (atlas-tfstate-<account>, versioned and encrypted)", isOn: $remoteState)
                        .padding([.horizontal, .bottom], 20)
                }
            }
        }
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.contents.activeId }, set: { model.select($0) })) {
                Section("Projects") {
                    ForEach(model.projects) { p in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).lineLimit(1)
                            Text(p.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        .tag(Optional(p.id))
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
                            Button("Remove from Atlas") { model.remove(p.id) }
                        }
                    }
                }
            }
            .disabled(model.isRunning)
            Divider()
            HStack {
                Button(action: chooseFolder) { Label("Add Project…", systemImage: "plus") }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func header(_ project: TerraformProject) -> some View {
        PageHeader(title: project.name, subtitle: project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
            HStack(spacing: 8) {
                statusBadge
                if let v = model.version { Badge(text: "Terraform \(v)", color: Palette.neutral) }
                Button { NSWorkspace.shared.activateFileViewerSelecting([project.url]) } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
            }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch model.status {
        case .idle: EmptyView()
        case .running(let c): Badge(text: "Running \(c.rawValue)…", color: Palette.accent)
        case .succeeded(let c): Badge(text: "\(c.rawValue.capitalized) succeeded", color: Palette.success)
        case .changes: Badge(text: "Changes to apply", color: Palette.warning)
        case .noChanges: Badge(text: "No changes", color: Palette.success)
        case .failed(let c, _): Badge(text: "\(c.rawValue.capitalized) failed", color: Palette.danger)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Group {
                Button("Init") { model.run(.initialize, client: state.client) }
                Button("Validate") { model.run(.validate, client: state.client) }
                Button("Plan") { model.run(.plan, client: state.client) }
                Button("Apply…") { confirmApply = true }
                    .disabled(model.reviewedPlan != model.active?.id || model.reviewedPlan == nil)
                    .help("Applies the last plan with changes. Run Plan first.")
                Button("Output") { model.run(.output, client: state.client) }
            }
            .disabled(model.isRunning)
            Divider().frame(height: 18)
            importMenu
            Button("Generate Config") { model.run(.generate, client: state.client) }
                .disabled(model.isRunning)
                .help("Runs terraform plan -generate-config-out for the import blocks in imports.tf, then fixes and splits the result")
            Spacer()
            if model.isRunning {
                ProgressView().controlSize(.small)
                Button("Cancel", role: .cancel) { model.cancel() }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Add Project"
        panel.message = "Choose a folder with Terraform configuration, or an empty folder for a new project."
        if panel.runModal() == .OK, let url = panel.url { model.add(folder: url) }
    }
}

// MARK: - Pieces

struct NoticeBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
            Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }
}

/// Monospaced command output that follows the newest line.
struct TerminalPanel: View {
    let lines: [IaCModel.Line]

    static func color(_ line: String) -> Color {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Error") || t.hasPrefix("│ Error") { return Palette.danger }
        if t.hasPrefix("Warning") || t.hasPrefix("│ Warning") { return Palette.warning }
        if t.hasPrefix("$ ") || t.hasPrefix("Atlas:") { return Palette.accent }
        if t.hasPrefix("+ ") || t == "+" { return Palette.success }
        if t.hasPrefix("- ") || t.hasPrefix("-/+") { return Palette.danger }
        if t.hasPrefix("~ ") { return Palette.warning }
        return .primary
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                TerminalLines(lines: lines)
            }
            .onChange(of: lines.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .card(radius: Radius.tile)
        .overlay {
            if lines.isEmpty {
                Text("Command output appears here.").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}

struct TerminalLines: View {
    let lines: [IaCModel.Line]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(lines) { line in
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(TerminalPanel.color(line.text))
                    .id(line.id)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TerraformMissingView: View {
    let onRetry: () -> Void

    var body: some View {
        EmptyStateView(icon: "shippingbox", title: "Terraform isn't installed",
                       message: "Atlas runs the terraform command on this Mac. Install it with Homebrew, then check again.") {
            HStack {
                Text("brew install terraform").font(.callout.monospaced()).textSelection(.enabled)
                CopyButton(value: "brew install terraform")
            }
            .padding(8)
            .card(radius: Radius.tile)
            Button("Check Again", action: onRetry)
        }
    }
}

// MARK: - Import from AWS

struct ImportFromAwsSheet: View {
    let client: AWSClient
    let region: String
    let targetName: String
    var offerGenerate = true
    /// Called with the chosen resources and whether to generate their configuration next.
    let onImport: ([DiscoveredResource], Bool) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var types = Set(AwsResourceType.allCases)
    @State private var tagText = ""
    @State private var includeAwsManaged = false
    @State private var analysis: ImportAnalysis?
    @State private var selected = Set<String>()
    @State private var isWorking = false
    @State private var progress = ""
    @State private var generateNow = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from AWS").font(Typo.pageTitle)
            Text("Find existing resources in \(region) and add them to \(targetName) as import blocks.")
                .foregroundStyle(.secondary)
            if let analysis { results(analysis) } else { options }
            if let error { ErrorBanner(message: error) }
            HStack {
                if isWorking { ProgressView().controlSize(.small); Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if analysis == nil {
                    Button("Discover") { Task { await discover() } }
                        .keyboardShortcut(.defaultAction).disabled(types.isEmpty || isWorking)
                } else {
                    Button("Back") { analysis = nil }
                    Button("Import \(selected.count)") { add() }
                        .keyboardShortcut(.defaultAction).disabled(selected.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 600)
    }

    private var options: some View {
        Form {
            Section("Resource types") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(AwsResourceType.Category.allCases, id: \.self) { category in
                            let members = AwsResourceType.allCases.filter { $0.category == category }
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(category.rawValue, isOn: Binding(
                                    get: { members.allSatisfy(types.contains) },
                                    set: { on in if on { types.formUnion(members) } else { types.subtract(members) } }))
                                    .font(.callout.weight(.medium))
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading) {
                                    ForEach(members) { t in
                                        Toggle(t.title, isOn: Binding(get: { types.contains(t) },
                                                                      set: { if $0 { types.insert(t) } else { types.remove(t) } }))
                                    }
                                }
                                .padding(.leading, 18)
                            }
                        }
                    }
                }
                .frame(height: 280)
            }
            Section("Filters") {
                TextField("Tags", text: $tagText, prompt: Text("env=prod, team"))
                    .help("Comma-separated key=value pairs; a key alone matches any value. Applies to EC2-family resources and S3.")
                Toggle("Include AWS-managed resources (default VPC and subnets, service-linked roles…)", isOn: $includeAwsManaged)
            }
        }
        .formStyle(.grouped)
    }

    private func results(_ a: ImportAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(a.resources.count) resources found in \(String(format: "%.1f", a.duration))s").font(.callout.weight(.medium))
                Spacer()
                Button("Select All") { selected = Set(a.resources.map(\.id)) }
                Button("Select None") { selected = [] }
            }
            .buttonStyle(.borderless)
            if !a.partialErrors.isEmpty {
                ErrorBanner(message: a.partialErrors.sorted { $0.key.title < $1.key.title }
                    .map { "\($0.key.title): \($0.value)" }.joined(separator: "\n"))
            }
            List {
                ForEach(AwsResourceType.allCases.filter { a.countByType[$0] != nil }) { type in
                    Section("\(type.title) (\(a.countByType[type] ?? 0))") {
                        ForEach(a.resources.filter { $0.type == type }) { r in
                            Toggle(isOn: Binding(get: { selected.contains(r.id) },
                                                 set: { if $0 { selected.insert(r.id) } else { selected.remove(r.id) } })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack {
                                        Text(r.name.isEmpty ? r.awsId : r.name).lineLimit(1)
                                        if r.confidence == .low { Badge(text: "Review", color: Palette.warning) }
                                    }
                                    Text(r.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    if !r.notes.isEmpty {
                                        Text(r.notes.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if offerGenerate {
                Toggle("Generate configuration for the imported resources now", isOn: $generateNow)
            }
        }
    }

    private var tagFilters: [TagFilter] {
        tagText.split(separator: ",").compactMap { part in
            let pieces = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let key = pieces.first, !key.isEmpty else { return nil }
            return TagFilter(key: key, value: pieces.count > 1 && !pieces[1].isEmpty ? pieces[1] : nil)
        }
    }

    private func discover() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        var o = ImportOptions()
        o.region = region
        o.types = AwsResourceType.allCases.filter(types.contains)
        o.tagFilters = tagFilters
        o.includeAwsManaged = includeAwsManaged
        let result = await ImportDiscoverer(client: client).discover(o) { line in
            Task { @MainActor in progress = line }
        }
        selected = Set(result.resources.filter { $0.confidence != .low }.map(\.id))
        analysis = result
    }

    private func add() {
        guard let a = analysis else { return }
        let chosen = a.resources.filter { selected.contains($0.id) }
        do {
            try onImport(chosen, generateNow)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
