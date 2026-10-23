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

    /// A long-lived, locked-down container: the stack folder at /workspace, its data folder and the engine's
    /// provider cache are the only writable places besides a tmpfs, no capabilities, the user's uid, idle until `exec`.
    func createArguments(name: String, stack: UUID, folder: URL, data: URL? = nil, plugins: URL? = nil,
                         engine: TerraformEngine, uid: UInt32 = getuid(), gid: UInt32 = getgid()) -> [String] {
        var args = ["create", "--name", name,
                    "--label", "io.cloud-atlas.stack=\(stack.uuidString)",
                    "--label", "io.cloud-atlas.engine=\(engine.rawValue)",
                    "--label", "\(StackContainer.layoutLabel)=\(StackContainer.layout)",
                    "--user", "\(uid):\(gid)",
                    "--workdir", StackContainer.workspace,
                    "--mount", "type=bind,source=\(folder.path),target=\(StackContainer.workspace)",
                    "--read-only", "--tmpfs", "/tmp",
                    "--cap-drop", "ALL",
                    "--env", "HOME=/tmp"]
        if let data {
            args += ["--mount", "type=bind,source=\(data.path),target=\(StackContainer.dataDirectory)",
                     "--env", "TF_DATA_DIR=\(StackContainer.dataDirectory)"]
        }
        // Providers downloaded once per engine, shared by every stack. Terraform checks each cached provider
        // against the stack's lock file before using it.
        if let plugins {
            args += ["--mount", "type=bind,source=\(plugins.path),target=\(StackContainer.pluginCacheDirectory)",
                     "--env", "TF_PLUGIN_CACHE_DIR=\(StackContainer.pluginCacheDirectory)"]
        }
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
    /// The engine's own `.terraform` (TF_DATA_DIR). The one in the stack folder belongs to the engine on the Mac:
    /// macOS providers and a backend cache in another version's format, which init reads as a changed backend.
    static let dataDirectory = "/atlas-data"
    /// The engine's provider cache (TF_PLUGIN_CACHE_DIR), shared by the stacks of that engine.
    static let pluginCacheDirectory = "/atlas-plugins"
    /// Bumped when the container's mounts or environment change: an older container is made again.
    static let layoutLabel = "io.cloud-atlas.layout"
    static let layout = 2

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
    /// The tools Atlas adds (`bin` of the data folder) come last in PATH, after the image's own.
    static let script = """
        export PATH="$PATH:\(dataDirectory)/bin"; \
        while IFS= read -r line && [ -n "$line" ]; do export "${line%%=*}=$(printf %s "${line#*=}" | base64 -d)"; done; exec "$0" "$@"
        """

    /// The images have no AWS CLI, and EKS configurations authenticate the kubernetes and helm providers with
    /// `exec { command = "aws", args = ["eks", "get-token", …] }`. This stand-in makes the same token as the AWS CLI
    /// with busybox alone, from the credentials the engine already gets; every other `aws` command fails clearly.
    static let awsCommand = #"""
#!/bin/sh
# Atlas: `aws eks get-token` for the kubernetes and helm providers' exec blocks, in a container without the AWS CLI.
# Same token as the AWS CLI (a presigned STS GetCallerIdentity URL), signed with the credentials Atlas gives the engine.
set -eu
die() { echo "aws (Atlas): $*" >&2; exit 1; }
[ "${1:-}" = eks ] && [ "${2:-}" = get-token ] || die "only 'aws eks get-token' is available in the stack's container."
shift 2
cluster="" region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
while [ $# -gt 0 ]; do
    case "$1" in
        --cluster-name|--cluster-id) [ $# -ge 2 ] || die "$1 needs a value."; cluster=$2; shift 2 ;;
        --cluster-name=*|--cluster-id=*) cluster=${1#*=}; shift ;;
        --region) [ $# -ge 2 ] || die "--region needs a value."; region=$2; shift 2 ;;
        --region=*) region=${1#*=}; shift ;;
        --output) shift 2 ;;
        --output=*) shift ;;
        *) die "$1 is not supported (only --cluster-name, --region and --output)." ;;
    esac
done
case "$cluster" in ""|*[!A-Za-z0-9_-]*) die "invalid or missing --cluster-name." ;; esac
case "$region" in ""|*[!a-z0-9-]*) die "invalid or missing region." ;; esac
key=${AWS_ACCESS_KEY_ID:-} secret=${AWS_SECRET_ACCESS_KEY:-} token=${AWS_SESSION_TOKEN:-}
case "$key" in ""|*[!A-Z0-9]*) die "no AWS credentials: the stack's Atlas account is missing." ;; esac
[ -n "$secret" ] || die "no AWS credentials: the stack's Atlas account is missing."
case "$token" in *[!A-Za-z0-9+/=]*) die "invalid session token." ;; esac

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -d ' ' -f 1; }
hex() { printf %s "$1" | od -An -v -tx1 | tr -d ' \n'; }
# HMAC-SHA256 of a text message with a key in hex; prints hex.
hmac() {
    k=$1
    [ ${#k} -le 128 ] || k=$(printf %s "$k" | xxd -r -p | sha256)
    while [ ${#k} -lt 128 ]; do k="${k}00"; done
    ia="" oa=""
    for b in $(printf %s "$k" | xxd -r -p | od -An -v -tu1); do ia="$ia $((b ^ 54))" oa="$oa $((b ^ 92))"; done
    inner=$({ printf '%02x' $ia | xxd -r -p; printf %s "$2"; } | sha256)
    { printf '%02x' $oa | xxd -r -p; printf %s "$inner" | xxd -r -p; } | sha256
}
utc() { date -u -d "@$1" "+$2" 2>/dev/null || date -u -r "$1" "+$2"; }

now=${ATLAS_TOKEN_EPOCH:-$(date -u +%s)}
amz=$(utc "$now" %Y%m%dT%H%M%SZ) day=$(utc "$now" %Y%m%d)
case "$region" in cn-*) domain=amazonaws.com.cn ;; *) domain=amazonaws.com ;; esac
host="sts.$region.$domain"
query="Action=GetCallerIdentity&Version=2011-06-15&X-Amz-Algorithm=AWS4-HMAC-SHA256"
query="$query&X-Amz-Credential=$key%2F$day%2F$region%2Fsts%2Faws4_request&X-Amz-Date=$amz&X-Amz-Expires=60"
signed="X-Amz-SignedHeaders=host%3Bx-k8s-aws-id" session=""
[ -z "$token" ] || session="&X-Amz-Security-Token=$(printf %s "$token" | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g')"
# Signed in sorted order (Security-Token before SignedHeaders); the URL keeps the AWS CLI's order.
canonical="$query$session&$signed" query="$query&$signed$session"
request=$(printf 'GET\n/\n%s\nhost:%s\nx-k8s-aws-id:%s\n\nhost;x-k8s-aws-id\n%s' "$canonical" "$host" "$cluster" \
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855)
signing=$(printf 'AWS4-HMAC-SHA256\n%s\n%s/%s/sts/aws4_request\n%s' "$amz" "$day" "$region" "$(printf %s "$request" | sha256)")
k=$(hmac "$(hex "AWS4$secret")" "$day"); k=$(hmac "$k" "$region"); k=$(hmac "$k" sts); k=$(hmac "$k" aws4_request)
url="https://$host/?$query&X-Amz-Signature=$(hmac "$k" "$signing")"
api=$(printf %s "${KUBERNETES_EXEC_INFO:-}" | sed -n 's/.*"apiVersion" *: *"\([a-z0-9./]*\)".*/\1/p')
printf '{"kind":"ExecCredential","apiVersion":"%s","spec":{},"status":{"expirationTimestamp":"%s","token":"k8s-aws-v1.%s"}}\n' \
    "${api:-client.authentication.k8s.io/v1beta1}" "$(utc $((now + 840)) %Y-%m-%dT%H:%M:%SZ)" \
    "$(printf %s "$url" | base64 | tr -d '\n=' | tr '+/' '-_')"
"""#

    /// Writes the tools into the data folder's `bin`, checked on every run so they follow the app's version.
    static func installTools(in data: URL) throws {
        let bin = data.appendingPathComponent("bin", isDirectory: true)
        let aws = bin.appendingPathComponent("aws")
        let content = Data(awsCommand.utf8)
        if FileManager.default.isExecutableFile(atPath: aws.path), (try? Data(contentsOf: aws)) == content { return }
        try PrivateFile.createFolder(bin)
        try PrivateFile.write(content, to: aws, permissions: 0o700)
    }

    /// What `inspect` says about an existing container.
    struct State: Equatable {
        var isCurrent: Bool
        var isRunning: Bool

        init(isCurrent: Bool, isRunning: Bool) {
            self.isCurrent = isCurrent
            self.isRunning = isRunning
        }

        /// Reads Docker's and Apple container's JSON, and plain label lists.
        init(inspect output: String) {
            isCurrent = output.firstMatch(of: #/io\.cloud-atlas\.layout"?\s*[:=]\s*"?(\d+)/#).map { Int($0.1) == StackContainer.layout } ?? false
            isRunning = output.firstMatch(of: #/"Running"\s*:\s*true|"status"\s*:\s*"running"/#) != nil
        }
    }

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

    /// Creates the container if it is missing or from an older layout (pulling the image) and starts it if it is
    /// stopped. A running, current container costs one `inspect`. `data` is the host folder kept as the engine's
    /// data folder, `plugins` the engine's shared provider cache.
    func ensure(folder: URL, data: URL? = nil, plugins: URL? = nil,
                log: @escaping @Sendable (String) -> Void) async -> TerraformResult {
        let cli = TerraformCLI(binary: runtime.binary, timeout: 20)
        let tmp = FileManager.default.temporaryDirectory
        do {
            if let data {
                try PrivateFile.createFolder(data)
                try Self.installTools(in: data)
            }
            if let plugins { try PrivateFile.createFolder(plugins) }
        } catch {
            return TerraformResult(status: .failed, diagnostic: "Could not prepare the stack's data folder: \(error.localizedDescription)")
        }
        let inspected = await cli.run(runtime.existsArguments(name), in: tmp)
        var state = inspected.isSuccess ? State(inspect: inspected.stdout) : nil
        if let current = state, !current.isCurrent {
            log("▶ Updating container \(name) (shared provider cache)…")
            await remove()
            state = nil
        }
        if state == nil {
            // Missing: tell a stopped runtime from a missing container before creating it.
            guard await cli.run(runtime.readyArguments, in: tmp).isSuccess else {
                return TerraformResult(status: .failed, diagnostic: "\(runtime.kind.rawValue) is not running. \(runtime.startHint)")
            }
            guard Self.canMount(folder), data.map(Self.canMount) ?? true, plugins.map(Self.canMount) ?? true else {
                return TerraformResult(status: .failed,
                                       diagnostic: "The stack folder's path has a comma, colon or equals sign; it cannot be mounted in a container.")
            }
            log("▶ Creating container \(name) from \(engine.image) (the first time downloads the image)…")
            let created = await TerraformCLI(binary: runtime.binary, timeout: 900)
                .run(runtime.createArguments(name: name, stack: stack, folder: folder, data: data, plugins: plugins, engine: engine),
                     in: tmp, onLine: log)
            guard created.isSuccess else {
                var r = created
                r.diagnostic = "Could not create the container: \(created.errors.first ?? created.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
                return r
            }
        } else if state?.isRunning == true {
            return TerraformResult(status: .success, exitCode: 0)
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
