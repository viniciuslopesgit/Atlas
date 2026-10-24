import Foundation
import Testing
@testable import Atlas

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

struct CronTests {
    @Test func parsesTheFiveFieldSyntax() {
        #expect(CronExpression("*/15 * * * *") != nil)
        #expect(CronExpression("0 8-18/2 1,15 * 1-5") != nil)
        #expect(CronExpression("30 2 * * 7")?.weekdays == [0], "7 is Sunday")
        for bad in ["", "* * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "*/0 * * * *", "5-1 * * * *", "a * * * *"] {
            #expect(CronExpression(bad) == nil, "\(bad) should be rejected")
        }
    }

    @Test func nextOccurrence() throws {
        let weekdays = try #require(CronExpression("0 8 * * 1-5"))
        // Friday 2026-10-23 09:00 → Monday 08:00
        #expect(weekdays.next(after: date("2026-10-23T09:00:00Z"), calendar: utc) == date("2026-10-26T08:00:00Z"))
        #expect(weekdays.next(after: date("2026-10-23T07:59:30Z"), calendar: utc) == date("2026-10-23T08:00:00Z"))

        let quarter = try #require(CronExpression("*/15 * * * *"))
        #expect(quarter.next(after: date("2026-10-23T10:15:00Z"), calendar: utc) == date("2026-10-23T10:30:00Z"), "strictly after")

        let monthly = try #require(CronExpression("0 0 1 * *"))
        #expect(monthly.next(after: date("2026-12-15T00:00:00Z"), calendar: utc) == date("2027-01-01T00:00:00Z"))

        // Both day fields restricted: the 13th OR a Friday.
        let either = try #require(CronExpression("0 0 13 * 5"))
        #expect(either.next(after: date("2026-10-23T12:00:00Z"), calendar: utc) == date("2026-10-30T00:00:00Z"))
        #expect(either.next(after: date("2026-11-07T00:00:00Z"), calendar: utc) == date("2026-11-13T00:00:00Z"))

        #expect(CronExpression("0 0 31 2 *")?.next(after: Date(), calendar: utc) == nil, "Feb 31 never happens")
    }

    @Test func driftDueByIntervalOrCron() {
        let now = date("2026-10-23T12:00:00Z")
        var s = StackEntry(name: "s", projectPath: "/tmp", accountId: "a", region: "us-east-1")
        #expect(!s.isDriftDue(now: now), "off by default")

        s.driftInterval = .hourly
        s.lastDriftCheckAt = now.addingTimeInterval(-1800)
        #expect(!s.isDriftDue(now: now))
        s.lastDriftCheckAt = now.addingTimeInterval(-3700)
        #expect(s.isDriftDue(now: now))
        s.driftStatus = .checking
        #expect(!s.isDriftDue(now: now), "never twice at once")

        var c = StackEntry(name: "c", projectPath: "/tmp", accountId: "a", region: "us-east-1")
        c.driftCron = ["*/30 * * * *"]
        c.lastDriftCheckAt = now.addingTimeInterval(-29 * 60 - 30)
        #expect(!c.isDriftDue(now: now.addingTimeInterval(-60)))
        #expect(c.isDriftDue(now: now))
    }
}

struct DriftReportTests {
    static let plan = """
    aws_s3_bucket.logs: Refreshing state... [id=acme-logs]

    Terraform used the selected providers to generate the following execution plan.

    Terraform will perform the following actions:

      # aws_instance.web will be updated in-place
      ~ resource "aws_instance" "web" {
          ~ instance_type = "t3.small" -> "t3.micro"
        }

      # aws_security_group.old will be destroyed
      - resource "aws_security_group" "old" {}

      # aws_db_instance.main must be replaced
    -/+ resource "aws_db_instance" "main" {}

      # aws_s3_bucket.new will be created
      + resource "aws_s3_bucket" "new" {}

    Plan: 2 to add, 1 to change, 2 to destroy.
    """

    @Test func parsesSummaryDiffAndChanges() {
        let r = DriftReport(planOutput: Self.plan)
        #expect(r.summary == "2 to add, 1 to change, 2 to destroy")
        #expect(DriftReport.summary("Plan: 0 to add, 3 to change, 0 to destroy.") == "3 to change")
        #expect(r.diff?.hasPrefix("  # aws_instance.web will be updated in-place") == true)
        #expect(r.diff?.contains("Plan:") == false)
        #expect(r.changes == [
            .init(address: "aws_instance.web", action: .update),
            .init(address: "aws_security_group.old", action: .destroy),
            .init(address: "aws_db_instance.main", action: .replace),
            .init(address: "aws_s3_bucket.new", action: .create),
        ])
        #expect(DriftReport(planOutput: "No changes. Your infrastructure matches the configuration.").diff == nil)
    }
}

struct StackStoreTests {
    @Test func outputIsEncryptedAndSecretsStayInTheStore() throws {
        let folder = TestTemp.root.appendingPathComponent("stacks-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let store = StackStore(folder: folder, secrets: secrets)

        var s = StackEntry(name: "prod", projectPath: "/tmp/prod", accountId: "acct", region: "eu-west-1")
        var run = StackRun(type: .plan, trigger: "manual")
        run.output = (1...400).map { "line \($0) TOPSECRET-OUTPUT" }.joined(separator: "\n")
        run.status = .success
        s.runs = [run]
        s.envVars = [StackEnvVar(tfVarName: "lambda_api_DB_PASSWORD", envKey: "DB_PASSWORD", value: "hunter2",
                                 resourceType: "aws_lambda_function", resourceName: "api", sourceFile: "lambda.tf")]
        store.save([s])

        let raw = try String(contentsOf: folder.appendingPathComponent("stacks.json"), encoding: .utf8)
        #expect(!raw.contains("TOPSECRET-OUTPUT"), "run output is encrypted on disk")
        #expect(!raw.contains("hunter2"), "variable values never reach stacks.json")
        #expect(raw.contains("lambda_api_DB_PASSWORD"))
        #expect(secrets.get(StackStore.outputKeyName) != nil)

        let loaded = try #require(store.load().first)
        #expect(loaded.envVars.first?.value == "hunter2")
        let lines = try #require(loaded.runs.first?.output.components(separatedBy: "\n"))
        #expect(lines.count == StackStore.maxOutputLines)
        #expect(lines.last == "line 400 TOPSECRET-OUTPUT")

        store.forget(loaded)
        #expect(secrets.get(StackStore.envKey(loaded.id, loaded.envVars[0].id)) == nil)
    }

    @Test func providersFileHasTheBackendButNoCredentials() throws {
        let dir = TestTemp.root.appendingPathComponent("prov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try StateBucket.writeProviders(in: dir, region: "eu-west-1", bucket: "atlas-tfstate-123", key: "stacks/prod/terraform.tfstate")
        let tf = try String(contentsOf: dir.appendingPathComponent("providers.tf"), encoding: .utf8)
        #expect(tf.contains("backend \"s3\" {"))
        #expect(tf.contains("bucket  = \"atlas-tfstate-123\""))
        #expect(tf.contains("key     = \"stacks/prod/terraform.tfstate\""))
        #expect(!tf.contains("access_key") && !tf.contains("secret_key"))
        #expect(StateBucket.name(account: "123") == "atlas-tfstate-123")
    }
}

// MARK: - Drift check against a fake terraform

private func fakeTerraform(planExit: Int) throws -> (bin: String, dir: URL) {
    let dir = TestTemp.root.appendingPathComponent("stack-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bin = dir.appendingPathComponent("fake-terraform")
    let planOutput = DriftReportTests.plan.replacingOccurrences(of: "'", with: "'\\''")
    try Data("""
    #!/bin/bash
    echo "$*" >> "$PWD/calls.log"
    case "$1" in
      plan)
        for a in "$@"; do case "$a" in -out=*) touch "${a#-out=}" ;; esac; done
        if [ \(planExit) = 2 ]; then printf '%s\\n' '\(planOutput)'; else echo "No changes."; fi
        exit \(planExit) ;;
      apply) echo "Apply complete! Resources: 0 added, 1 changed, 0 destroyed." ;;
    esac
    """.utf8).write(to: bin)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    return (bin.path, dir)
}

@MainActor
private func waitIdle(_ model: StacksModel, _ id: UUID) async {
    for _ in 0..<200 where model.busy.contains(id) { try? await Task.sleep(nanoseconds: 20_000_000) }
    try? await Task.sleep(nanoseconds: 50_000_000)
}

struct StacksModelTests {
    @Test @MainActor func driftCheckRecordsTheDriftAndFixAppliesTheSavedPlan() async throws {
        let (bin, dir) = try fakeTerraform(planExit: 2)
        let store = StackStore(folder: dir.appendingPathComponent("support"), secrets: InMemorySecretStore())
        let model = StacksModel(store: store, clientFor: { _ in nil }, makeCLI: { _ in TerraformCLI(binary: bin) })
        let s = model.create(name: "prod", folder: dir, accountId: "acct", region: "eu-west-1")

        model.checkDrift(s.id)
        #expect(model.busy.contains(s.id))
        model.checkDrift(s.id) // ignored while busy
        await waitIdle(model, s.id)

        var after = try #require(model.stack(s.id))
        #expect(after.driftStatus == .drifted)
        #expect(after.driftSummary == "2 to add, 1 to change, 2 to destroy")
        #expect(after.runs.count == 1)
        #expect(after.runs[0].status == .success)
        #expect(after.runs[0].output.contains("aws_instance.web will be updated"))
        let plans = model.planFiles(for: s)
        #expect(FileManager.default.fileExists(atPath: plans.url(StacksModel.driftPlanFile).path), "saved in Atlas's folder")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(StacksModel.driftPlanFile).path),
                "never in the stack's folder")

        model.acknowledgeDrift(s.id)
        #expect(model.stack(s.id)?.driftAcknowledged == true)

        model.fixDrift(s.id)
        await waitIdle(model, s.id)
        after = try #require(model.stack(s.id))
        let calls = try String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)
        #expect(calls.contains("apply -no-color \(plans.arg(StacksModel.driftPlanFile))"), "applies the saved drift plan, never -auto-approve")
        #expect(!calls.contains("-auto-approve"))
        #expect(after.runs.first?.type == .fixDrift)
        #expect(after.runs.first?.status == .failed, "the fake still reports drift on verify")
        #expect(after.driftStatus == .drifted && after.driftAcknowledged, "same diff stays acknowledged")

        // Persisted across a reload.
        let reloaded = StacksModel(store: store, clientFor: { _ in nil })
        #expect(reloaded.stack(s.id)?.runs.count == 2)
    }

    @Test @MainActor func cleanPlanMarksTheStackInSync() async throws {
        let (bin, dir) = try fakeTerraform(planExit: 0)
        let model = StacksModel(store: StackStore(folder: dir.appendingPathComponent("support"), secrets: InMemorySecretStore()),
                                clientFor: { _ in nil }, makeCLI: { _ in TerraformCLI(binary: bin) })
        let s = model.create(name: "dev", folder: dir, accountId: "acct", region: "us-east-1")
        model.update(s.id) { $0.driftInterval = .hourly }
        model.runDueDriftChecks()
        await waitIdle(model, s.id)
        let after = try #require(model.stack(s.id))
        #expect(after.driftStatus == .clean)
        #expect(after.runs.first?.trigger == "drift check (scheduled)")
        #expect(!after.isDriftDue(), "next check is an hour away")
    }
}

struct FeedbackTests {
    @Test func mailLinkCarriesSubjectBodyAndVersions() throws {
        var f = Feedback()
        #expect(!f.isReady)
        f.kind = .suggestion
        f.subject = "Dark mode & more"
        f.description = "Line one\nLine two"
        #expect(f.isReady)

        let url = try #require(f.mailURL(systemInfo: "Atlas 2.0.0 · macOS 26.0.0"))
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.scheme == "mailto" && c.path == Feedback.recipient)
        let items = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["subject"]?.hasSuffix("[Suggestion] Dark mode & more") == true)
        #expect(items["body"] == "Type: Suggestion\n\nDescription:\nLine one\nLine two\n\n---\nAtlas 2.0.0 · macOS 26.0.0")
        #expect(!url.absoluteString.contains("&more"), "the subject's & is escaped")

        f.includeSystemInfo = false
        #expect(!f.githubIssue(systemInfo: "X").contains("X"))
        #expect(f.githubIssue().hasPrefix("## Suggestion: Dark mode & more\n\nLine one"))
    }
}

struct StackRunOutputTests {
    @Test func outputIsCappedAndKeepsTheEnd() {
        var run = StackRun(type: .apply, trigger: "manual")
        let line = String(repeating: "x", count: 99)
        for i in 0..<20_000 { run.append(["\(i) \(line)"]) }
        #expect(run.output.utf8.count <= StackRun.maxOutputBytes)
        #expect(run.output.hasPrefix(StackRun.trimmedNotice + "\n"))
        #expect(run.output.hasSuffix("19999 \(line)"), "the newest output is kept")
        let first = run.output.split(separator: "\n")[1]
        #expect(first.hasSuffix(line) && first.first?.isNumber == true, "cut at a line break, never mid-line")
    }

    @Test func multibyteTextSurvivesTheCut() {
        var run = StackRun(type: .plan, trigger: "manual")
        for _ in 0..<40_000 { run.append(["ação ✔ 🚀"]) }
        #expect(!run.output.contains("\u{FFFD}"))
        #expect(run.output.hasSuffix("ação ✔ 🚀"))
    }

    @Test func linesAreJoinedInOrder() {
        var run = StackRun(type: .plan, trigger: "manual")
        run.append(["a", "b"])
        run.append([])
        run.append(["c"])
        #expect(run.output == "a\nb\nc")
    }
}

/// New stacks keep their state in S3 instead of a plain-text terraform.tfstate in their folder.
struct StackStateTests {
    static func folder() throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A terraform that records its calls; `state list` fails when `failList` is there.
    static func engine(in dir: URL) throws -> String {
        let bin = dir.appendingPathComponent("fake-terraform")
        try Data("""
        #!/bin/bash
        echo "$*" >> "\(dir.path)/calls.log"
        [ "$1 $2" = "state list" ] && [ -f "\(dir.path)/failList" ] && { echo "Error: no state" >&2; exit 1; }
        exit 0
        """.utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return bin.path
    }

    /// STS says the account is 123456789012 and the state bucket already exists.
    static func client() -> AWSClient {
        MockURLProtocol.client(region: "eu-west-1") { request, _ in
            if request.url?.host?.hasPrefix("sts.") == true {
                return .init(body: "<GetCallerIdentityResponse><GetCallerIdentityResult><Account>123456789012</Account><Arn>arn:aws:iam::123456789012:user/a</Arn><UserId>A</UserId></GetCallerIdentityResult></GetCallerIdentityResponse>")
            }
            return .init(status: 200)
        }
    }

    @Test func findsBackendsAndLocalState() throws {
        let dir = try Self.folder()
        #expect(!StateBackend.hasBackend(in: dir) && !StateBackend.hasLocalState(in: dir))
        try Data("# backend \"s3\" {}\nterraform {\n  # cloud {\n}\n".utf8).write(to: dir.appendingPathComponent("main.tf"))
        #expect(!StateBackend.hasBackend(in: dir), "comments are not a backend")
        try Data("terraform {\n  backend \"s3\" {\n  }\n}\n".utf8).write(to: dir.appendingPathComponent("providers.tf"))
        #expect(StateBackend.hasBackend(in: dir))
        #expect(!StateBackend.hasBackend(in: dir, except: ["providers.tf"]))
        try Data("terraform {\n  cloud {\n    organization = \"o\"\n  }\n}\n".utf8).write(to: dir.appendingPathComponent("hcp.tf"))
        #expect(StateBackend.hasBackend(in: dir, except: ["providers.tf"]), "HCP Terraform keeps the state too")

        try Data().write(to: dir.appendingPathComponent("terraform.tfstate"))
        #expect(!StateBackend.hasLocalState(in: dir), "an empty file left after a migration is no state")
        try Data("{\"version\": 4}".utf8).write(to: dir.appendingPathComponent("terraform.tfstate.backup"))
        #expect(StateBackend.hasLocalState(in: dir))
    }

    @Test @MainActor func aNewStackGetsAnEncryptedS3Backend() async throws {
        let dir = try Self.folder()
        let bin = try Self.engine(in: dir)
        let client = Self.client()
        let model = StacksModel(store: StackStore(folder: dir.appendingPathComponent("support"), secrets: InMemorySecretStore()),
                                clientFor: { _ in client }, makeCLI: { _ in TerraformCLI(binary: bin) })
        let project = dir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let s = model.create(name: "Prod Net", folder: project, accountId: "a", region: "eu-west-1", remoteState: true)
        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(model.stack(s.id)?.lastRun?.status == .success, "\(model.stack(s.id)?.lastRun?.output ?? "")")
        let backend = try String(contentsOf: project.appendingPathComponent(StateBackend.file), encoding: .utf8)
        #expect(backend.contains("bucket  = \"atlas-tfstate-123456789012\""))
        #expect(backend.contains("key     = \"\(StateBucket.key(for: s))\"") && backend.contains("encrypt = true"))
        #expect(StateBucket.key(for: s).contains(s.id.uuidString.prefix(8).lowercased()), "two stacks named alike get their own object")
        #expect(!StateBackend.hasLocalState(in: project))

        // A folder with its own backend, or state already on this Mac, is left alone.
        let own = dir.appendingPathComponent("own", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("{\"version\": 4}".utf8).write(to: own.appendingPathComponent("terraform.tfstate"))
        let local = model.create(name: "own", folder: own, accountId: "a", region: "eu-west-1", remoteState: true)
        for _ in 0..<300 where model.busy.contains(local.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!FileManager.default.fileExists(atPath: own.appendingPathComponent(StateBackend.file).path))
        #expect(model.stack(local.id)?.lastRun?.output.contains("Move State to S3") == true)
    }
}

/// Stacks whose state is already in an S3 bucket of their own (backend "s3" in 01-providers.tf, say).
struct ExistingBackendTests {
    @Test func aStackWithItsOwnProvidersAndBackendKeepsItsFiles() throws {
        let dir = try StackStateTests.folder()
        #expect(StateBucket.canWriteProviders(in: dir), "an empty folder gets Atlas's providers.tf")
        try StateBucket.writeProviders(in: dir, region: "eu-west-1", bucket: nil, key: "k")
        #expect(StateBucket.canWriteProviders(in: dir), "Atlas's own providers.tf can be rewritten")

        let user = """
        terraform {
          required_providers {
            aws = { source = "hashicorp/aws" }
          }
          backend "s3" {
            bucket = "company-tfstate"
            key    = "omnium/terraform.tfstate"
          }
        }
        provider "aws" { region = "eu-west-1" }
        """
        try FileManager.default.removeItem(at: dir.appendingPathComponent("providers.tf"))
        try Data(user.utf8).write(to: dir.appendingPathComponent("01-providers.tf"))
        #expect(!StateBucket.canWriteProviders(in: dir), "would declare the provider twice")
        #expect(StateBackend.hasBackend(in: dir) && StateBackend.hasBackend(in: dir, except: ["providers.tf"]))

        let json = try StackStateTests.folder()
        try Data(#"{"terraform": {"backend": {"s3": {"bucket": "b"}}}}"#.utf8).write(to: json.appendingPathComponent("main.tf.json"))
        #expect(StateBackend.hasBackend(in: json) && !StateBucket.canWriteProviders(in: json))

        let hand = try StackStateTests.folder()
        try Data("provider \"aws\" {}\n".utf8).write(to: hand.appendingPathComponent("providers.tf"))
        #expect(!StateBucket.canWriteProviders(in: hand), "a providers.tf the user wrote is never replaced")
    }

    /// Import into a stack whose state is in its own S3 bucket: no providers.tf is written, no Atlas bucket is made.
    @Test @MainActor func importIntoAStackWithItsOwnBackendLeavesItsConfiguration() async throws {
        let dir = try StackStateTests.folder()
        let bin = try StackStateTests.engine(in: dir)
        let client = StackStateTests.client()
        let project = dir.appendingPathComponent("omnium", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let user = "terraform {\n  backend \"s3\" {\n    bucket = \"company-tfstate\"\n  }\n}\nprovider \"aws\" {}\n"
        try Data(user.utf8).write(to: project.appendingPathComponent("01-providers.tf"))
        let model = StacksModel(store: StackStore(folder: dir.appendingPathComponent("support"), secrets: InMemorySecretStore()),
                                clientFor: { _ in client }, makeCLI: { _ in TerraformCLI(binary: bin) })
        let s = model.create(name: "omnium", folder: project, accountId: "a", region: "eu-west-1", remoteState: true)
        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(StateBackend.file).path))

        model.importResources(s.id, [], remoteState: true)
        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        let output = model.stack(s.id)?.lastRun?.output ?? ""
        #expect(output.contains("own provider and backend configuration is kept"), "\(output)")
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("providers.tf").path))
        #expect(try String(contentsOf: project.appendingPathComponent("01-providers.tf"), encoding: .utf8) == user)
        #expect(!MockURLProtocol.requests.contains { $0.request.url?.host?.contains("s3") == true }, "no Atlas state bucket")
    }
}
