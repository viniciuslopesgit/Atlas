import Foundation
import Testing
@testable import Atlas

/// A stand-in `docker`: keeps containers as files next to it, and `exec` runs the real entry script with a fake
/// terraform/tofu in the mounted folder. Every call is appended to docker.log.
struct FakeDocker {
    let dir: URL
    let workspace: URL
    var runtime: ContainerRuntime { ContainerRuntime(kind: .docker, binary: dir.appendingPathComponent("docker").path) }
    var log: String { (try? String(contentsOf: dir.appendingPathComponent("docker.log"), encoding: .utf8)) ?? "" }
    var engineCalls: String { (try? String(contentsOf: workspace.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "" }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("c-\(name)").path) }
    func setDown(_ down: Bool) throws {
        let f = dir.appendingPathComponent("down")
        if down { try Data().write(to: f) } else { try? FileManager.default.removeItem(at: f) }
    }

    init(planExit: Int = 0) throws {
        let root = TestTemp.root.appendingPathComponent("docker-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("bin", isDirectory: true)
        workspace = root.appendingPathComponent("stack", isDirectory: true)
        let engines = dir.appendingPathComponent("engine", isDirectory: true)
        for d in [dir, workspace, engines] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Self.write(dir.appendingPathComponent("docker"), """
        #!/bin/bash
        D="$(cd "$(dirname "$0")" && pwd)"
        echo "$*" >> "$D/docker.log"
        case "$1" in
          info) [ ! -f "$D/down" ] ;;
          inspect) [ -f "$D/c-$2" ] ;;
          create)
            # Like Docker Desktop: pulling needs the credential helper that sits next to the CLI.
            command -v docker-credential-desktop >/dev/null || {
              echo 'error getting credentials - err: exec: "docker-credential-desktop": executable file not found in $PATH' >&2; exit 1; }
            shift; name=""; src=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --name) name="$2"; shift ;;
                --mount) [ -z "$src" ] && { src="${2#type=bind,source=}"; src="${src%%,target=*}"; }; shift ;;
              esac
              shift
            done
            echo "Pulling image… done"
            echo "$src" > "$D/c-$name" ;;
          start) [ -f "$D/c-$2" ] ;;
          rm) rm -f "$D/c-$3" ;;
          exec)
            shift; [ "$1" = "--interactive" ] && shift; [ "$1" = "--workdir" ] && shift 2
            name="$1"; shift
            [ -f "$D/c-$name" ] || { echo "No such container: $name" >&2; exit 1; }
            case "$3" in *kill*) exit 0 ;; esac
            cd "$(cat "$D/c-$name")" || exit 125
            PATH="$D/engine:$PATH" exec "$@" ;;
        esac
        """)
        try Self.write(dir.appendingPathComponent("docker-credential-desktop"), "#!/bin/bash\nexit 0\n")
        let planOutput = DriftReportTests.plan.replacingOccurrences(of: "'", with: "'\\''")
        for engine in TerraformEngine.allCases {
            try Self.write(engines.appendingPathComponent(engine.command), """
            #!/bin/bash
            echo "\(engine.command) $*" >> "$PWD/calls.log"
            echo "key=$AWS_ACCESS_KEY_ID secret=$AWS_SECRET_ACCESS_KEY region=$AWS_REGION auto=$TF_IN_AUTOMATION var=$TF_VAR_db_password"
            case "$1" in
              plan)
                for a in "$@"; do case "$a" in -out=*) touch "${a#-out=}" ;; esac; done
                if [ \(planExit) = 2 ]; then printf '%s\\n' '\(planOutput)'; else echo "No changes."; fi
                exit \(planExit) ;;
              sleep) sleep 30 ;;
            esac
            """)
        }
    }

    private static func write(_ url: URL, _ script: String) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

@MainActor
private func waitIdle(_ model: StacksModel, _ id: UUID) async {
    for _ in 0..<300 where model.busy.contains(id) { try? await Task.sleep(nanoseconds: 20_000_000) }
    try? await Task.sleep(nanoseconds: 50_000_000)
}

struct ContainerRuntimeTests {
    @Test func findsTheRuntimeAndNamesIt() {
        func locate(_ present: Set<String>, path: String = "") -> ContainerRuntime? {
            ContainerRuntime.locate(environment: ["PATH": path], home: "/Users/u", isExecutable: { present.contains($0) })
        }
        #expect(locate([]) == nil)
        #expect(locate(["/Users/u/.orbstack/bin/docker"])?.kind == .orbStack)
        #expect(locate(["/Applications/Docker.app/Contents/Resources/bin/docker"])?.kind == .dockerDesktop)
        #expect(locate(["/opt/homebrew/bin/docker", "/opt/homebrew/bin/colima"])?.kind == .colima)
        #expect(locate(["/x/docker"], path: "/x") == ContainerRuntime(kind: .docker, binary: "/x/docker"))
        #expect(locate(["/usr/local/bin/container"])?.kind == .appleContainer)
        #expect(locate(["/usr/local/bin/container", "/opt/homebrew/bin/docker"])?.kind == .docker, "the docker CLI wins")
    }

    @Test func containersAreLockedDownAndPerEngine() {
        let id = UUID()
        let docker = ContainerRuntime(kind: .orbStack, binary: "/d")
        let args = docker.createArguments(name: "n", stack: id, folder: URL(fileURLWithPath: "/p/stack"), engine: .tofu, uid: 501, gid: 20)
        let joined = args.joined(separator: " ")
        for flag in ["--read-only", "--cap-drop ALL", "--user 501:20", "--security-opt no-new-privileges",
                     "type=bind,source=/p/stack,target=/workspace", "--entrypoint tail \(TerraformEngine.tofu.image) -f /dev/null"] {
            #expect(joined.contains(flag), "missing \(flag)")
        }
        let apple = ContainerRuntime(kind: .appleContainer, binary: "/c")
        #expect(!apple.createArguments(name: "n", stack: id, folder: URL(fileURLWithPath: "/p"), engine: .terraform).contains("--security-opt"))
        #expect(apple.removeArguments("n") == ["delete", "--force", "n"])
        #expect(apple.readyArguments == ["system", "status"])
        #expect(docker.removeArguments("n") == ["rm", "--force", "n"])

        let a = StackContainer(runtime: docker, stack: id, engine: .terraform), b = StackContainer(runtime: docker, stack: id, engine: .tofu)
        #expect(a.name != b.name && a.name.hasPrefix("atlas-stack-\(id.uuidString.lowercased())"))
        #expect(b.execArguments(["plan"]).suffix(2) == ["tofu", "plan"])
        #expect(TerraformEngine.terraform.image.contains("hashicorp/terraform") && TerraformEngine.tofu.image.contains("opentofu"))
    }

    @Test func stdinBlockEncodesValuesAndDropsBadNames() {
        let text = String(decoding: StackContainer.stdinBlock(["B": "two\nlines", "A": "1", "bad name": "x", "9x": "y", "": "z"]), as: UTF8.self)
        #expect(text == "A=\(Data("1".utf8).base64EncodedString())\nB=\(Data("two\nlines".utf8).base64EncodedString())\n\n")
        #expect(StackContainer.isValidName("TF_VAR_db_1") && !StackContainer.isValidName("A;B") && !StackContainer.isValidName("É"))
    }

    @Test func runsTheEngineInsideTheContainerWithTheValuesFromStdin() async throws {
        let fake = try FakeDocker()
        let c = StackContainer(runtime: fake.runtime, stack: UUID(), engine: .terraform)
        let ready = await c.ensure(folder: fake.workspace, log: { _ in })
        #expect(ready.isSuccess && fake.exists(c.name))
        let cli = TerraformCLI(container: c, timeout: 30)
        let creds = TerraformCredentials(accessKeyId: "AKIABOX", secretAccessKey: "s3cr3t", region: "eu-west-1")
        let r = await cli.run(["init", "-no-color"], in: fake.workspace, credentials: creds, tfVars: ["db_password": "p w"])
        #expect(r.status == .success)
        #expect(r.stdout.contains("key=AKIABOX secret=s3cr3t region=eu-west-1 auto=1 var=p w"))
        #expect(fake.engineCalls.contains("terraform init -no-color"))
        #expect(fake.log.contains("exec --interactive --workdir /workspace \(c.name) /bin/sh -c"))

        // Already there: ensure only starts it.
        _ = await c.ensure(folder: fake.workspace, log: { _ in })
        #expect(fake.log.components(separatedBy: "create ").count == 2)
        await c.remove()
        #expect(!fake.exists(c.name))
    }

    @Test func cancellingAlsoSignalsTheEngineInsideTheContainer() async throws {
        let fake = try FakeDocker()
        let c = StackContainer(runtime: fake.runtime, stack: UUID(), engine: .terraform)
        #expect(await c.ensure(folder: fake.workspace, log: { _ in }).isSuccess)
        let task = Task { await TerraformCLI(container: c, timeout: 60).run(["sleep"], in: fake.workspace) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        #expect(await task.value.status == .cancelled)
        for _ in 0..<100 where !fake.log.contains("kill -TERM -1") { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(fake.log.contains("exec \(c.name) /bin/sh -c kill -TERM -1"))
    }

    @Test func aStoppedRuntimeOrAnUnmountableFolderIsAClearFailure() async throws {
        let fake = try FakeDocker()
        let c = StackContainer(runtime: fake.runtime, stack: UUID(), engine: .terraform)
        try fake.setDown(true)
        let down = await c.ensure(folder: fake.workspace, log: { _ in })
        #expect(!down.isSuccess && down.diagnostic.contains("not running"))
        try fake.setDown(false)
        let odd = await c.ensure(folder: URL(fileURLWithPath: "/tmp/a,b"), log: { _ in })
        #expect(!odd.isSuccess && odd.diagnostic.contains("cannot be mounted"))
        #expect(!fake.log.contains("create"))
    }
}

struct StacksContainerModelTests {
    @Test @MainActor func aNewStackGetsItsContainerAndRunsDriftInIt() async throws {
        let fake = try FakeDocker(planExit: 2)
        let store = StackStore(folder: fake.dir.appendingPathComponent("support"), secrets: InMemorySecretStore())
        let model = StacksModel(store: store, clientFor: { _ in nil }, makeCLI: { _ in TerraformCLI(binary: nil) },
                                runtime: { fake.runtime })
        let s = model.create(name: "prod", folder: fake.workspace, accountId: "acct", region: "eu-west-1", engine: .tofu)
        await waitIdle(model, s.id)
        let container = try #require(model.container(for: s))
        #expect(fake.exists(container.name), "created with the stack")
        #expect(model.stack(s.id)?.runs.first?.type == .setup)
        #expect(model.stack(s.id)?.runs.first?.status == .success)
        #expect(fake.log.contains(TerraformEngine.tofu.image))

        model.checkDrift(s.id)
        await waitIdle(model, s.id)
        let after = try #require(model.stack(s.id))
        #expect(after.driftStatus == .drifted)
        #expect(after.runs[0].output.contains("▶ tofu plan"))
        #expect(fake.engineCalls.contains("tofu plan -no-color -detailed-exitcode -out=\(StacksModel.driftPlanFile)"))

        // Switching engine drops the old container; the next run creates the Terraform one.
        model.setEngine(.terraform, for: s.id)
        model.initialize(s.id)
        await waitIdle(model, s.id)
        let switched = try #require(model.stack(s.id))
        let tf = try #require(model.container(for: switched))
        #expect(fake.exists(tf.name))
        #expect(fake.engineCalls.contains("terraform init -no-color"))
        #expect(fake.log.contains("rm --force \(container.name)"))

        // Persisted, and deleting the stack removes its containers.
        #expect(StacksModel(store: store, clientFor: { _ in nil }).stack(s.id)?.engine == .terraform)
        await model.delete(s.id)?.value
        #expect(!fake.exists(tf.name) && !fake.exists(container.name))
        #expect(model.stack(s.id) == nil)
    }

    /// The folder's own `.terraform` came from the engine on the Mac (another version, macOS providers, a backend
    /// cache that `tofu init` reads as "Backend configuration changed"): the container keeps its own data folder.
    @Test @MainActor func theContainerKeepsItsOwnDataFolderOutsideTheStack() async throws {
        let fake = try FakeDocker()
        let support = fake.dir.appendingPathComponent("support")
        let store = StackStore(folder: support, secrets: InMemorySecretStore())
        let model = StacksModel(store: store, clientFor: { _ in nil }, makeCLI: { _ in TerraformCLI(binary: nil) },
                                runtime: { fake.runtime })
        let s = model.create(name: "omnium", folder: fake.workspace, accountId: "acct", region: "eu-west-1", engine: .tofu)
        await waitIdle(model, s.id)
        model.initialize(s.id)
        await waitIdle(model, s.id)
        let run = try #require(model.stack(s.id)?.runs.first)
        #expect(run.type == .initialize && run.status == .success, "\(run.output)")
        #expect(fake.engineCalls.contains("tofu init -no-color"))

        let data = store.dataFolder(s.id, .tofu)
        #expect(data.path.hasPrefix(support.path) && data.path.contains(s.id.uuidString))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: data.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(fake.log.contains("type=bind,source=\(data.path),target=\(StackContainer.dataDirectory)"))
        #expect(fake.log.contains("--env TF_DATA_DIR=\(StackContainer.dataDirectory)"))
        #expect(store.dataFolder(s.id, .terraform) != data, "one per engine")

        await model.delete(s.id)?.value
        #expect(!FileManager.default.fileExists(atPath: data.path), "deleting the stack removes its data folder")
        #expect(FileManager.default.fileExists(atPath: fake.workspace.path), "and leaves the stack's folder as it is")
    }

    /// Docker Desktop's CLI runs `docker-credential-desktop` from PATH to pull an image; Atlas opened from Finder
    /// does not have Docker.app's folder in PATH, so creating the container failed before init ever ran.
    @Test func theRuntimeFindsTheHelpersNextToItsCLI() {
        let env = TerraformCLI.environment(base: ["PATH": "/usr/bin:/bin"], credentials: nil, tfVars: [:],
                                           binary: "/Applications/Docker.app/Contents/Resources/bin/docker")
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(path.first == "/Applications/Docker.app/Contents/Resources/bin")
        #expect(path.contains("/usr/bin") && path.contains("/opt/homebrew/bin"))
    }

    @Test @MainActor func withoutRuntimeOrBinaryTheRunExplainsTheSetup() async throws {
        let fake = try FakeDocker()
        let model = StacksModel(store: StackStore(folder: fake.dir.appendingPathComponent("support"), secrets: InMemorySecretStore()),
                                clientFor: { _ in nil }, makeCLI: { _ in TerraformCLI(binary: nil) })
        let s = model.create(name: "dev", folder: fake.workspace, accountId: "acct", region: "us-east-1")
        #expect(model.stack(s.id)?.runs.isEmpty == true, "no container to set up")
        #expect(model.delete(UUID()) == nil)
        model.plan(s.id)
        let run = try #require(model.stack(s.id)?.runs.first)
        #expect(run.status == .failed && run.output.contains("Install Docker Desktop"))
        #expect(model.delete(s.id) == nil, "nothing to remove without a runtime")
    }

    @Test @MainActor func stacksSavedBeforeEnginesStillLoad() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"old","projectPath":"/p","accountId":"a","region":"r","status":"ready","createdAt":0,"runs":[],"envVars":[],"driftInterval":"off","driftCron":[],"driftStatus":"unknown","driftAcknowledged":false,"autoFixOnDrift":false}"#
        let s = try JSONDecoder().decode(StackEntry.self, from: Data(json.utf8))
        #expect(s.engine == .terraform)
    }
}
