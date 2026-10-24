import Foundation

/// The IaC command a stack runs: HashiCorp Terraform or OpenTofu (same CLI, same files).
enum TerraformEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    case terraform, tofu

    var id: String { rawValue }
    var label: String { self == .terraform ? "Terraform" : "OpenTofu" }
    /// The executable, on this Mac and inside the image.
    var command: String { rawValue }
    /// Official images, pinned so a stack does not change version under the user.
    var image: String {
        switch self {
        case .terraform: "docker.io/hashicorp/terraform:1.9.8"
        case .tofu: "ghcr.io/opentofu/opentofu:1.8"
        }
    }
    var installCommand: String { self == .terraform ? "brew install terraform" : "brew install opentofu" }
}

/// A container runtime already on this Mac. Docker Desktop, OrbStack and Colima share the `docker` CLI;
/// Apple's `container` (macOS 26) has its own, with the same verbs used here.
struct ContainerRuntime: Sendable, Equatable {
    enum Kind: String, Sendable { case dockerDesktop = "Docker Desktop", orbStack = "OrbStack", colima = "Colima",
                                       docker = "Docker", appleContainer = "Apple container" }

    var kind: Kind
    var binary: String

    var isApple: Bool { kind == .appleContainer }

    /// Finds a runtime: the `docker` CLI first (PATH, Homebrew, inside Docker.app or OrbStack), then Apple's `container`.
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: String = NSHomeDirectory(),
                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> ContainerRuntime? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let folders = path + TerraformCLI.searchPaths + [
            "/Applications/Docker.app/Contents/Resources/bin",
            "\(home)/.orbstack/bin",
            "/Applications/OrbStack.app/Contents/MacOS/xbin",
        ]
        if let docker = folders.map({ "\($0)/docker" }).first(where: isExecutable) {
            let real = URL(fileURLWithPath: docker).resolvingSymlinksInPath().path
            let colima = folders.contains { isExecutable("\($0)/colima") }
            let kind: Kind = real.contains("OrbStack") || real.contains(".orbstack") ? .orbStack
                : real.contains("Docker.app") ? .dockerDesktop
                : colima ? .colima : .docker
            return ContainerRuntime(kind: kind, binary: docker)
        }
        if let apple = (["/usr/local/bin"] + path).map({ "\($0)/container" }).first(where: isExecutable) {
            return ContainerRuntime(kind: .appleContainer, binary: apple)
        }
        return nil
    }

    /// What to do when the runtime does not answer.
    var startHint: String {
        switch kind {
        case .dockerDesktop: "Open Docker Desktop and try again."
        case .orbStack: "Open OrbStack and try again."
        case .colima: "Start it with: colima start"
        case .docker: "Start the Docker daemon and try again."
        case .appleContainer: "Start it with: container system start"
        }
    }

    // MARK: Arguments (no secrets ever go here)

    var readyArguments: [String] { isApple ? ["system", "status"] : ["info", "--format", "{{.ServerVersion}}"] }
    func existsArguments(_ name: String) -> [String] { ["inspect", name] }
    func startArguments(_ name: String) -> [String] { ["start", name] }
    func removeArguments(_ name: String) -> [String] { isApple ? ["delete", "--force", name] : ["rm", "--force", name] }

    /// A long-lived, locked-down container: the stack folder at /workspace is the only writable place
    /// besides a tmpfs, no capabilities, the user's uid, idle until `exec`.
    func createArguments(name: String, stack: UUID, folder: URL, engine: TerraformEngine,
                         uid: UInt32 = getuid(), gid: UInt32 = getgid()) -> [String] {
        var args = ["create", "--name", name,
                    "--label", "io.cloud-atlas.stack=\(stack.uuidString)",
                    "--label", "io.cloud-atlas.engine=\(engine.rawValue)",
                    "--user", "\(uid):\(gid)",
                    "--workdir", StackContainer.workspace,
                    "--mount", "type=bind,source=\(folder.path),target=\(StackContainer.workspace)",
                    "--read-only", "--tmpfs", "/tmp",
                    "--cap-drop", "ALL",
                    "--env", "HOME=/tmp"]
        if !isApple { args += ["--security-opt", "no-new-privileges", "--pids-limit", "512"] }
        return args + ["--entrypoint", "tail", engine.image, "-f", "/dev/null"]
    }

    /// Signals every process of the container but its init, so a cancelled terraform releases the state lock.
    func killArguments(_ name: String) -> [String] {
        ["exec", name, "/bin/sh", "-c", "kill -TERM -1 2>/dev/null; exit 0"]
    }
}

/// The container of one stack. Its name has the engine, so switching engine gets a fresh image.
struct StackContainer: Sendable, Equatable {
    static let workspace = "/workspace"

    var runtime: ContainerRuntime
    var stack: UUID
    var engine: TerraformEngine

    var name: String { Self.name(stack, engine) }
    static func name(_ stack: UUID, _ engine: TerraformEngine) -> String {
        "atlas-stack-\(stack.uuidString.lowercased())-\(engine.rawValue)"
    }

    /// A folder the mount syntax cannot carry safely is refused rather than escaped.
    static func canMount(_ folder: URL) -> Bool {
        !folder.path.contains { $0 == "," || $0 == ":" || $0 == "=" || $0.isNewline }
    }

    /// Reads `NAME=base64` lines from stdin up to an empty line, exports them, then runs the engine.
    /// Values are decoded, never evaluated; names are checked before they are sent.
    static let script = """
        while IFS= read -r line && [ -n "$line" ]; do export "${line%%=*}=$(printf %s "${line#*=}" | base64 -d)"; done; exec "$0" "$@"
        """

    func execArguments(_ args: [String]) -> [String] {
        ["exec", "--interactive", "--workdir", Self.workspace, name, "/bin/sh", "-c", Self.script, engine.command] + args
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }

    static func stdinBlock(_ env: [String: String]) -> Data {
        let lines = env.filter { isValidName($0.key) }.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Data($0.value.utf8).base64EncodedString())" }
        return Data((lines.joined(separator: "\n") + "\n\n").utf8)
    }

    // MARK: Lifecycle

    /// Creates the container if it is missing (pulling the image) and starts it.
    func ensure(folder: URL, log: @escaping @Sendable (String) -> Void) async -> TerraformResult {
        let cli = TerraformCLI(binary: runtime.binary, timeout: 20)
        let tmp = FileManager.default.temporaryDirectory
        guard await cli.run(runtime.readyArguments, in: tmp).isSuccess else {
            return TerraformResult(status: .failed, diagnostic: "\(runtime.kind.rawValue) is not running. \(runtime.startHint)")
        }
        if !(await cli.run(runtime.existsArguments(name), in: tmp)).isSuccess {
            guard Self.canMount(folder) else {
                return TerraformResult(status: .failed,
                                       diagnostic: "The stack folder's path has a comma, colon or equals sign; it cannot be mounted in a container.")
            }
            log("▶ Creating container \(name) from \(engine.image) (the first time downloads the image)…")
            let created = await TerraformCLI(binary: runtime.binary, timeout: 900)
                .run(runtime.createArguments(name: name, stack: stack, folder: folder, engine: engine), in: tmp, onLine: log)
            guard created.isSuccess else {
                var r = created
                r.diagnostic = "Could not create the container: \(created.errors.first ?? created.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                return r
            }
        }
        var started = await cli.run(runtime.startArguments(name), in: tmp)
        if !started.isSuccess { started.diagnostic = "Could not start the container \(name)." }
        return started
    }

    /// Removes the container; a missing one is not an error.
    func remove() async {
        _ = await TerraformCLI(binary: runtime.binary, timeout: 60)
            .run(runtime.removeArguments(name), in: FileManager.default.temporaryDirectory)
    }
}
