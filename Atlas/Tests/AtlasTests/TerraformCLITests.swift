import Foundation
import Testing
@testable import Atlas

/// A stand-in `terraform` executable: behavior depends on the first argument.
private func fakeTerraform() throws -> (cli: TerraformCLI, dir: URL) {
    let dir = TestTemp.root.appendingPathComponent("tf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bin = dir.appendingPathComponent("terraform")
    try Data("""
    #!/bin/bash
    echo "args: $*"
    echo "key=$AWS_ACCESS_KEY_ID region=$AWS_REGION auto=$TF_IN_AUTOMATION input=$TF_INPUT var=$TF_VAR_db_password"
    case "$1" in
      plan) for a in "$@"; do [ "$a" = "-detailed-exitcode" ] && exit 2; done; exit 0 ;;
      version) echo '{"terraform_version": "1.9.8", "platform": "darwin_arm64"}' ;;
      fail)
        echo "╷" >&2
        echo "│ Error: No valid credential sources found" >&2
        echo "│" >&2
        echo "│ NoCredentialProviders: no valid providers in chain" >&2
        echo "╵" >&2
        exit 1 ;;
      sleep) sleep 30 ;;
      partial) printf 'no newline at end' ;;
    esac
    """.utf8).write(to: bin)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
    return (TerraformCLI(binary: bin.path), dir)
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

struct TerraformCLITests {
    @Test func streamsLinesAndPassesCredentialsOnlyToTheChild() async throws {
        let (cli, dir) = try fakeTerraform()
        let lines = Lines()
        let creds = TerraformCredentials(accessKeyId: "AKIACHILD", secretAccessKey: "s", region: "eu-west-1")
        let r = await cli.run(["init"], in: dir, credentials: creds, tfVars: ["db_password": "pw"], onLine: lines.add)
        #expect(r.status == .success)
        #expect(lines.all.first == "args: init")
        #expect(r.stdout.contains("key=AKIACHILD region=eu-west-1 auto=1 input=0 var=pw"))
        #expect(ProcessInfo.processInfo.environment["AWS_ACCESS_KEY_ID"] != "AKIACHILD")
    }

    @Test func planExitCodeTwoMeansChanges() async throws {
        let (cli, dir) = try fakeTerraform()
        let r = await cli.plan(dir, refreshOnly: true)
        #expect(r.status == .planHasChanges && r.isSuccess)
        #expect(r.stdout.contains("-refresh-only"))
        let generated = await cli.planGeneratingConfig(dir, outFile: "generated.tf")
        #expect(generated.status == .noChanges, "without -detailed-exitcode the fake exits 0")
    }

    @Test func failureIsParsedIntoAFriendlyMessage() async throws {
        let (cli, dir) = try fakeTerraform()
        let r = await cli.run(["fail"], in: dir)
        #expect(r.status == .failed && r.exitCode == 1)
        #expect(r.errors.count == 1 && r.errors[0].hasPrefix("Error: No valid credential sources found"))
        #expect(r.diagnostic.contains("credentials are invalid"))
        #expect(r.fullOutput.contains("─── stderr ───"))
    }

    @Test func versionIsReadFromJson() async throws {
        let (cli, _) = try fakeTerraform()
        #expect(await cli.version() == "v1.9.8")
    }

    @Test func lastLineWithoutNewlineIsKept() async throws {
        let (cli, dir) = try fakeTerraform()
        let r = await cli.run(["partial"], in: dir)
        #expect(r.stdout.hasSuffix("no newline at end\n"))
    }

    @Test func timeoutStopsTheProcess() async throws {
        let (cli, dir) = try fakeTerraform()
        let started = Date()
        let r = await cli.run(["sleep"], in: dir, timeout: 1)
        #expect(r.status == .timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func cancellationStopsTheProcess() async throws {
        let (cli, dir) = try fakeTerraform()
        let task = Task { await cli.run(["sleep"], in: dir) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        #expect(await task.value.status == .cancelled)
    }

    @Test func missingBinaryIsReported() async {
        let r = await TerraformCLI(binary: nil).run(["init"], in: TestTemp.root)
        #expect(r.status == .notFound)
    }

    @Test func legacyErrorLinesAreParsed() {
        let errors = TerraformDiagnostics.errors(stdout: "Error: state lock\nsomething", stderr: "")
        #expect(errors == ["Error: state lock"])
        #expect(TerraformDiagnostics.message(exitCode: 1, stdout: "Error acquiring the state lock", stderr: "", errors: [])
            .contains("locked"))
    }
}
