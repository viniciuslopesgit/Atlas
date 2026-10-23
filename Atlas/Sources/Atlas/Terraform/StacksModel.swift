import Foundation
@preconcurrency import UserNotifications

/// Stacks, their runs and the drift scheduler. Owned by the app so scheduled checks run while
/// Atlas is open, whichever page is visible (same as 1.0.1).
@MainActor
final class StacksModel: ObservableObject {
    nonisolated static let planFile = "atlas.tfplan"
    nonisolated static let driftPlanFile = "atlas-drift.tfplan"
    nonisolated static let generatedFile = "generated_resources.tf"

    @Published private(set) var stacks: [StackEntry] = []
    /// Stacks with a terraform process running: one at a time per stack, or they fight over the state lock.
    @Published private(set) var busy: Set<UUID> = []

    private let store: StackStore
    private let clientFor: @MainActor (StackEntry) -> AWSClient?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var timer: Timer?
    /// Runs on this Mac when there is no container runtime.
    private let makeCLI: (TerraformEngine) -> TerraformCLI
    private let locateRuntime: () -> ContainerRuntime?

    init(store: StackStore, clientFor: @escaping @MainActor (StackEntry) -> AWSClient?,
         makeCLI: @escaping (TerraformEngine) -> TerraformCLI = { TerraformCLI(binary: TerraformCLI.locate(command: $0.command), timeout: 900) },
         runtime: @escaping () -> ContainerRuntime? = { nil }) {
        self.store = store
        self.clientFor = clientFor
        self.makeCLI = makeCLI
        self.locateRuntime = runtime
        stacks = store.load()
        // A run that was in progress when Atlas quit didn't finish.
        for i in stacks.indices {
            if stacks[i].status == .running || stacks[i].status == .queued { stacks[i].status = .failed }
            if stacks[i].driftStatus == .checking { stacks[i].driftStatus = .unknown }
            for j in stacks[i].runs.indices where stacks[i].runs[j].status == .running {
                stacks[i].runs[j].status = .cancelled
                stacks[i].runs[j].completedAt = stacks[i].runs[j].completedAt ?? stacks[i].runs[j].startedAt
            }
        }
    }

    func stack(_ id: UUID) -> StackEntry? { stacks.first { $0.id == id } }

    /// The container runtime found on this Mac, if any: each stack then runs in its own container.
    var runtime: ContainerRuntime? { locateRuntime() }

    func container(for s: StackEntry) -> StackContainer? {
        runtime.map { StackContainer(runtime: $0, stack: s.id, engine: s.engine) }
    }

    // MARK: Scheduler

    func startScheduler() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runDueDriftChecks() }
        }
    }

    func runDueDriftChecks(now: Date = Date()) {
        for s in stacks where s.isDriftDue(now: now) && !busy.contains(s.id) { checkDrift(s.id, trigger: "scheduled") }
    }

    // MARK: Editing

    /// Adds the stack and, with a container runtime, creates its container right away.
    @discardableResult
    func create(name: String, folder: URL, accountId: String, region: String, engine: TerraformEngine = .terraform) -> StackEntry {
        IaCModel.scaffoldIfEmpty(folder)
        var s = StackEntry(name: name, projectPath: folder.path, accountId: accountId, region: region)
        s.engine = engine
        stacks.append(s)
        save()
        if runtime != nil { run(s.id, .setup, trigger: "stack created") { _ in true } }
        return s
    }

    /// Switches Terraform ⇄ OpenTofu; the old engine's container goes away, the next run creates the new one.
    func setEngine(_ engine: TerraformEngine, for id: UUID) {
        guard let s = stack(id), s.engine != engine, !busy.contains(id) else { return }
        let old = container(for: s)
        update(id) { $0.engine = engine }
        if let old { Task { await old.remove() } }
    }

    func update(_ id: UUID, _ change: (inout StackEntry) -> Void) {
        guard let i = stacks.firstIndex(where: { $0.id == id }) else { return }
        change(&stacks[i])
        save()
    }

    /// Forgets the stack and its secrets and removes its containers; the folder is left as it is.
    @discardableResult
    func delete(_ id: UUID) -> Task<Void, Never>? {
        guard let s = stack(id), !busy.contains(id) else { return nil }
        store.forget(s)
        stacks.removeAll { $0.id == id }
        save()
        guard let runtime else { return nil }
        // Both engines: a container may be left from before an engine switch.
        let containers = TerraformEngine.allCases.map { StackContainer(runtime: runtime, stack: id, engine: $0) }
        return Task { for c in containers { await c.remove() } }
    }

    func removeEnvVar(_ variable: StackEnvVar, from id: UUID) {
        guard let s = stack(id) else { return }
        store.forget(envVar: variable, of: s)
        update(id) { $0.envVars.removeAll { $0.id == variable.id } }
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    private func save() { store.save(stacks) }

    // MARK: Runs

    private struct Context: Sendable {
        let dir: URL
        let cli: TerraformCLI
        /// `terraform` or `tofu`, for the log.
        let tool: String
        let credentials: TerraformCredentials?
        let tfVars: [String: String]
        let log: @Sendable (String) -> Void
    }

    /// Runs `body` as a recorded run of the stack. The body returns whether the run succeeded.
    private func run(_ id: UUID, _ type: StackRunType, trigger: String,
                     _ body: @escaping @Sendable (Context) async -> Bool) {
        guard let s = stack(id), !busy.contains(id) else { return }
        let container = container(for: s)
        let cli = container.map { TerraformCLI(container: $0, timeout: 900) } ?? makeCLI(s.engine)
        guard cli.binary != nil else {
            record(id, StackRun(type: type, status: .failed, trigger: trigger, completedAt: Date(),
                                output: "\(s.engine.label) isn't installed and there is no container runtime.\n"
                                    + "Install Docker Desktop (Stacks › Settings › Install Docker Desktop…) so each stack runs in its own "
                                    + "container, or install it on this Mac: \(s.engine.installCommand)"))
            return
        }
        let client = clientFor(s)
        let context = Context(
            dir: s.url, cli: cli, tool: s.engine.command, credentials: client.map(TerraformCredentials.init),
            tfVars: Dictionary(s.envVars.map { ($0.tfVarName, $0.value) }, uniquingKeysWith: { a, _ in a }),
            log: { [weak self] line in DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(line, to: id) } } })

        busy.insert(id)
        record(id, StackRun(type: type, trigger: trigger))
        update(id) { $0.status = .running }
        if client == nil { context.log("⚠ The stack's Atlas account is missing; \(s.engine.command) runs without AWS credentials.") }

        tasks[id] = Task {
            var ok = true
            if let container {
                context.log("▶ \(s.engine.label) in container \(container.name) (\(container.runtime.kind.rawValue))")
                let ready = await container.ensure(folder: s.url, log: context.log)
                ok = Self.report(ready, context.log)
            } else if type == .setup {
                ok = false
            }
            if ok, !Task.isCancelled { ok = await body(context) }
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            finish(id, ok: ok, cancelled: Task.isCancelled)
        }
    }

    private func record(_ id: UUID, _ run: StackRun) {
        update(id) { s in
            s.runs.insert(run, at: 0)
            if s.runs.count > 50 { s.runs.removeLast(s.runs.count - 50) }
        }
    }

    private func append(_ line: String, to id: UUID) {
        guard let i = stacks.firstIndex(where: { $0.id == id }), !stacks[i].runs.isEmpty else { return }
        stacks[i].runs[0].output += (stacks[i].runs[0].output.isEmpty ? "" : "\n") + line
    }

    private func finish(_ id: UUID, ok: Bool, cancelled: Bool) {
        busy.remove(id)
        tasks[id] = nil
        update(id) { s in
            guard !s.runs.isEmpty else { return }
            s.runs[0].completedAt = Date()
            s.runs[0].status = cancelled ? .cancelled : ok ? .success : .failed
            s.status = ok && !cancelled ? .finished : .failed
            if s.driftStatus == .checking { s.driftStatus = cancelled ? .unknown : .error }
        }
    }

    nonisolated private static func report(_ r: TerraformResult, _ log: @Sendable (String) -> Void) -> Bool {
        if !r.isSuccess { log("✗ \(r.diagnostic.isEmpty ? "the command exited with code \(r.exitCode)" : r.diagnostic)") }
        return r.isSuccess
    }

    // MARK: Commands

    func initialize(_ id: UUID) {
        run(id, .initialize, trigger: "manual") { c in
            c.log("▶ \(c.tool) init")
            return Self.report(await c.cli.initialize(c.dir, credentials: c.credentials, onLine: c.log), c.log)
        }
    }

    /// Saves the plan so Apply runs exactly what was reviewed.
    func plan(_ id: UUID) {
        run(id, .plan, trigger: "manual") { c in
            c.log("▶ \(c.tool) plan -out=\(Self.planFile)")
            let r = await c.cli.plan(c.dir, outFile: Self.planFile, credentials: c.credentials, tfVars: c.tfVars, onLine: c.log)
            if r.status == .noChanges { try? FileManager.default.removeItem(at: c.dir.appendingPathComponent(Self.planFile)) }
            return Self.report(r, c.log)
        }
    }

    nonisolated func hasSavedPlan(_ s: StackEntry) -> Bool {
        FileManager.default.fileExists(atPath: s.url.appendingPathComponent(Self.planFile).path)
    }

    func apply(_ id: UUID) {
        run(id, .apply, trigger: "manual") { c in
            c.log("▶ \(c.tool) apply \(Self.planFile)")
            let r = await c.cli.apply(c.dir, planFile: Self.planFile, credentials: c.credentials, tfVars: c.tfVars, onLine: c.log)
            try? FileManager.default.removeItem(at: c.dir.appendingPathComponent(Self.planFile))
            return Self.report(r, c.log)
        }
    }

    /// `plan -detailed-exitcode`: exit 2 means the infrastructure no longer matches the configuration.
    func checkDrift(_ id: UUID, trigger: String = "manual") {
        guard !busy.contains(id) else { return }
        update(id) { $0.driftStatus = .checking }
        run(id, .plan, trigger: "drift check (\(trigger))") { [weak self] c in
            c.log("▶ \(c.tool) plan -detailed-exitcode -out=\(Self.driftPlanFile)")
            let r = await c.cli.plan(c.dir, outFile: Self.driftPlanFile, credentials: c.credentials, tfVars: c.tfVars, onLine: c.log)
            let ok = r.isSuccess
            await self?.recordDrift(id, r)
            return ok
        }
    }

    private func recordDrift(_ id: UUID, _ r: TerraformResult) {
        let before = stack(id)
        update(id) { s in
            s.lastDriftCheckAt = Date()
            switch r.status {
            case .noChanges:
                s.driftStatus = .clean; s.driftSummary = nil; s.driftDiff = nil; s.driftAcknowledged = false
            case .planHasChanges:
                let report = DriftReport(planOutput: r.stdout)
                // A new drift needs attention again; the same diff stays acknowledged.
                if report.diff != s.driftDiff { s.driftAcknowledged = false }
                s.driftStatus = .drifted; s.driftSummary = report.summary; s.driftDiff = report.diff
            default:
                s.driftStatus = .error; s.driftSummary = r.diagnostic
            }
        }
        guard let s = stack(id) else { return }
        if r.status == .planHasChanges {
            if before?.driftStatus != .drifted || before?.driftDiff != s.driftDiff {
                Self.notify("Drift in \(s.name)", s.driftSummary ?? "Infrastructure no longer matches the configuration.")
            }
            if s.autoFixOnDrift {
                // Runs after this run finishes and releases the stack.
                Task { @MainActor [weak self] in
                    while self?.busy.contains(id) == true { try? await Task.sleep(nanoseconds: 200_000_000) }
                    self?.fixDrift(id, trigger: "auto-fix")
                }
            }
        }
    }

    /// Applies the plan saved by the last drift check, then verifies with a fresh plan.
    func fixDrift(_ id: UUID, trigger: String = "manual") {
        guard let s = stack(id), FileManager.default.fileExists(atPath: s.url.appendingPathComponent(Self.driftPlanFile).path) else {
            checkDrift(id, trigger: trigger)
            return
        }
        update(id) { $0.driftStatus = .checking }
        run(id, .fixDrift, trigger: trigger) { [weak self] c in
            c.log("━━━ Fix drift ━━━")
            c.log("▶ \(c.tool) apply \(Self.driftPlanFile)")
            let applied = await c.cli.apply(c.dir, planFile: Self.driftPlanFile, credentials: c.credentials, tfVars: c.tfVars, onLine: c.log)
            try? FileManager.default.removeItem(at: c.dir.appendingPathComponent(Self.driftPlanFile))
            guard Self.report(applied, c.log) else {
                await self?.recordDrift(id, applied)
                return false
            }
            c.log("\n━━━ Verify ━━━")
            c.log("▶ \(c.tool) plan -detailed-exitcode")
            let verify = await c.cli.plan(c.dir, outFile: Self.driftPlanFile, credentials: c.credentials, tfVars: c.tfVars, onLine: c.log)
            c.log(verify.status == .noChanges ? "✔ No drift: the infrastructure matches the configuration."
                  : verify.status == .planHasChanges ? "⚠ Drift is still present." : "✗ Verification failed.")
            await self?.recordDrift(id, verify)
            return verify.status == .noChanges
        }
    }

    func acknowledgeDrift(_ id: UUID) { update(id) { $0.driftAcknowledged = true } }

    // MARK: Import from AWS (pipeline of StacksViewModel.cs)

    /// Remote state bucket, init, import blocks, generated config, fixes, split per service,
    /// env var extraction into the Keychain, validate.
    func importResources(_ id: UUID, _ resources: [DiscoveredResource], remoteState: Bool) {
        guard let s = stack(id) else { return }
        let client = clientFor(s)
        let stateKey = "stacks/\(ImportDiscovery.tfName(s.name, fallback: "stack"))/terraform.tfstate"
        run(id, .importResources, trigger: "import of \(resources.count) resource(s)") { [weak self] c in
            c.log("━━━ State ━━━")
            var bucket: String?
            if remoteState, let client {
                do {
                    bucket = try await StateBucket.ensure(client: client, log: c.log)
                    c.log("  ✔ state bucket: \(bucket!) (key \(stateKey))")
                } catch {
                    c.log("  ⚠ Could not prepare the state bucket: \(error.localizedDescription)")
                    c.log("    Falling back to local state.")
                }
            }
            do {
                try StateBucket.writeProviders(in: c.dir, region: c.credentials?.region ?? "us-east-1", bucket: bucket, key: stateKey)
                c.log("  ✔ providers.tf written")
            } catch {
                c.log("✗ Could not write providers.tf: \(error.localizedDescription)")
                return false
            }

            c.log("\n━━━ Init ━━━\n▶ \(c.tool) init")
            guard Self.report(await c.cli.initialize(c.dir, credentials: c.credentials, onLine: c.log), c.log) else { return false }

            c.log("\n━━━ Import ━━━")
            do {
                let files = try TerraformAware.adopt(resources, into: c.dir)
                c.log("  ✔ \(resources.count) import block(s); wrote " + files.map(\.lastPathComponent).joined(separator: ", "))
            } catch {
                c.log("✗ Could not write the import blocks: \(error.localizedDescription)")
                return false
            }

            c.log("\n▶ \(c.tool) plan -generate-config-out=\(Self.generatedFile)")
            let generate = await c.cli.planGeneratingConfig(c.dir, outFile: Self.generatedFile, credentials: c.credentials,
                                                           tfVars: c.tfVars, onLine: c.log)
            if generate.status == .cancelled || generate.status == .timedOut { return Self.report(generate, c.log) }
            let generated = c.dir.appendingPathComponent(Self.generatedFile)
            var vars: [StackEnvVar] = []
            if FileManager.default.fileExists(atPath: generated.path) {
                do {
                    let fixes = try GeneratedHclFixer.fix(file: generated)
                    if fixes.total > 0 { c.log("  ✔ corrected \(fixes.total) known schema issue(s)") }
                    for (file, count) in try GeneratedHclSplitter.split(file: generated) { c.log("  ✔ \(count) resource(s) → \(file)") }
                    vars = try EnvVarExtractor.extractAndReplace(in: c.dir)
                    if !vars.isEmpty {
                        try EnvVarExtractor.writeVariables(vars, in: c.dir)
                        c.log("  ✔ \(vars.count) environment value(s) moved to the Keychain → \(EnvVarExtractor.variablesFile)")
                    }
                } catch {
                    c.log("✗ Post-processing failed: \(error.localizedDescription)")
                    return false
                }
            } else if !generate.isSuccess {
                return Self.report(generate, c.log)
            }
            let extracted = vars
            await self?.merge(extracted, into: id)

            c.log("\n━━━ Validate ━━━\n▶ \(c.tool) validate")
            return Self.report(await c.cli.validate(c.dir, onLine: c.log), c.log)
        }
    }

    private func merge(_ vars: [StackEnvVar], into id: UUID) {
        guard !vars.isEmpty else { return }
        update(id) { s in
            for v in vars {
                if let i = s.envVars.firstIndex(where: { $0.tfVarName == v.tfVarName }) { s.envVars[i].value = v.value }
                else { s.envVars.append(v) }
            }
        }
    }

    // MARK: Notifications

    private static var canNotify: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil && !SmokeTest.isEnabled
    }

    static func notify(_ title: String, _ body: String) {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// The S3 bucket that keeps imported stacks' state: `atlas-tfstate-<account>` (as in 1.0.1),
/// versioned, encrypted and private.
enum StateBucket {
    static func name(account: String) -> String { "atlas-tfstate-\(account)" }

    static func ensure(client: AWSClient, log: @Sendable (String) -> Void) async throws -> String {
        let account = try await StsService(client: client).callerIdentity().account
        let bucket = name(account: account)
        log("▶ Checking state bucket \(bucket)…")
        do {
            _ = try await client.s3(method: "HEAD", bucket: bucket)
            return bucket
        } catch let e as AWSError where e.status == 404 {
            log("▶ Creating state bucket \(bucket)…")
        }
        var o = CreateBucketOptions()
        o.bucketName = bucket
        o.region = client.region
        o.blockAllPublicAccess = true
        o.versioningEnabled = true
        o.encryption = .sseS3
        o.tags = [("ManagedBy", "Atlas")]
        try await S3Service(client: client).createBucket(o)
        return bucket
    }

    /// providers.tf with the AWS provider and, when there is a bucket, the S3 backend. No credentials:
    /// terraform gets them from the environment.
    static func writeProviders(in dir: URL, region: String, bucket: String?, key: String) throws {
        let backend = bucket.map { """

            backend "s3" {
              bucket  = \(HclGenerator.quote($0))
              key     = \(HclGenerator.quote(key))
              region  = \(HclGenerator.quote(region))
              encrypt = true
            }
        """ } ?? ""
        let content = """
        # Generated by Atlas — credentials and region come from the Atlas account.
        terraform {
          required_version = ">= 1.5"
          required_providers {
            aws = {
              source  = "hashicorp/aws"
              version = "~> 5.0"
            }
          }\(backend)
        }

        provider "aws" {
          region = \(HclGenerator.quote(region))
        }

        """
        try content.write(to: dir.appendingPathComponent("providers.tf"), atomically: true, encoding: .utf8)
    }
}
