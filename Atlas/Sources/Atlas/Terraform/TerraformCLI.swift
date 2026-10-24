import Foundation

/// AWS credentials handed to terraform through the child process environment only.
struct TerraformCredentials: Sendable {
    var accessKeyId: String
    var secretAccessKey: String
    var region: String
    var sessionToken: String?

    init(accessKeyId: String, secretAccessKey: String, region: String, sessionToken: String? = nil) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.region = region
        self.sessionToken = sessionToken
    }

    init(_ client: AWSClient) {
        self.init(accessKeyId: client.credentials.accessKeyId, secretAccessKey: client.credentials.secretAccessKey,
                  region: client.region)
    }
}

struct TerraformResult: Sendable {
    enum Status: Sendable { case success, planHasChanges, noChanges, failed, cancelled, timedOut, notFound }

    var status: Status
    var exitCode: Int32 = -1
    var stdout = ""
    var stderr = ""
    var diagnostic = ""
    var duration: TimeInterval = 0
    var errors: [String] = []

    var isSuccess: Bool { [.success, .planHasChanges, .noChanges].contains(status) }

    /// stdout and stderr separated by a marker, for display.
    var fullOutput: String {
        if stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return stdout }
        if stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return stderr }
        return "\(stdout)\n─── stderr ───\n\(stderr)"
    }

    static let notFound = TerraformResult(
        status: .notFound,
        diagnostic: "Terraform is not installed. Install it with: brew install hashicorp/tap/terraform")
}

/// Runs the terraform CLI as a child process, streaming each output line as it arrives.
/// Same behavior as Atlas 1.0.1's TerraformCliWrapper: no prompts, credentials only in the child env,
/// exit code 2 of `plan -detailed-exitcode` is "changes", cancellation and timeout kill the process.
struct TerraformCLI: Sendable {
    /// Folders searched in addition to PATH: apps opened from Finder get a minimal PATH.
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    /// Upper bound of captured text per stream; the live line callback still receives everything.
    static let maxCapturedChars = 8 * 1024 * 1024

    var binary: String?
    var timeout: TimeInterval = 300
    /// When set, every command runs inside this stack container and `binary` is the container runtime.
    var container: StackContainer?

    init(binary: String? = TerraformCLI.locate(), timeout: TimeInterval = 300) {
        self.binary = binary
        self.timeout = timeout
    }

    init(container: StackContainer, timeout: TimeInterval = 300) {
        self.init(binary: container.runtime.binary, timeout: timeout)
        self.container = container
    }

    static func locate(command: String = "terraform",
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (path + searchPaths).map { "\($0)/\(command)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Commands

    func version() async -> String? {
        let r = await run(["version", "-json"], in: FileManager.default.temporaryDirectory, timeout: 10)
        guard r.isSuccess else { return nil }
        if let m = r.stdout.firstMatch(of: #/"terraform_version"\s*:\s*"([^"]+)"/#) { return "v\(m.1)" }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func initialize(_ dir: URL, upgrade: Bool = false, credentials: TerraformCredentials? = nil,
                    onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> TerraformResult {
        await run(["init", "-no-color"] + (upgrade ? ["-upgrade"] : []), in: dir, credentials: credentials, onLine: onLine)
    }

    func validate(_ dir: URL, onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> TerraformResult {
        await run(["validate", "-no-color"], in: dir, onLine: onLine)
    }

    func plan(_ dir: URL, outFile: String? = nil, refreshOnly: Bool = false, credentials: TerraformCredentials? = nil,
              tfVars: [String: String] = [:], onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> TerraformResult {
        var args = ["plan", "-no-color", "-detailed-exitcode"]
        if refreshOnly { args.append("-refresh-only") }
        if let outFile { args.append("-out=\(outFile)") }
        return Self.planStatus(await run(args, in: dir, credentials: credentials, tfVars: tfVars, onLine: onLine))
    }

    /// `plan -generate-config-out`: writes HCL for the resources referenced by import blocks.
    func planGeneratingConfig(_ dir: URL, outFile: String, credentials: TerraformCredentials? = nil,
                              tfVars: [String: String] = [:],
                              onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> TerraformResult {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(outFile))
        return Self.planStatus(await run(["plan", "-no-color", "-generate-config-out=\(outFile)"], in: dir,
                                         credentials: credentials, tfVars: tfVars, onLine: onLine))
    }

    func apply(_ dir: URL, planFile: String? = nil, credentials: TerraformCredentials? = nil,
               tfVars: [String: String] = [:], onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> TerraformResult {
        let args = ["apply", "-no-color"] + (planFile.map { [$0] } ?? ["-auto-approve"])
        return await run(args, in: dir, credentials: credentials, tfVars: tfVars, onLine: onLine)
    }

    func importResource(_ dir: URL, address: String, id: String, credentials: TerraformCredentials? = nil,
                        onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> TerraformResult {
        await run(["import", "-no-color", address, id], in: dir, credentials: credentials, onLine: onLine)
    }

    func output(_ dir: URL, json: Bool = false, onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> TerraformResult {
        await run(["output", "-no-color"] + (json ? ["-json"] : []), in: dir, onLine: onLine)
    }

    static func planStatus(_ r: TerraformResult) -> TerraformResult {
        var r = r
        if r.exitCode == 2 {
            r.status = .planHasChanges
            r.diagnostic = "Plan finished with pending changes."
        } else if r.exitCode == 0 && r.status == .success {
            r.status = .noChanges
        }
        return r
    }

    // MARK: Process

    /// Environment of the child: the app's own, plus automation flags, credentials and TF_VAR_*.
    /// The binary's own folder goes first in PATH: Docker Desktop's CLI pulls images through
    /// `docker-credential-desktop`, which sits next to it inside Docker.app and is in no PATH of an app opened from Finder.
    static func environment(base: [String: String], credentials: TerraformCredentials?,
                            tfVars: [String: String], binary: String? = nil) -> [String: String] {
        // Debug logs would write requests and values to a file or the output.
        var env = base.filter { !logVariables.contains($0.key) }
        let own = binary.map { b in
            [URL(fileURLWithPath: b), URL(fileURLWithPath: b).resolvingSymlinksInPath()].map { $0.deletingLastPathComponent().path }
        } ?? []
        var seen = Set<String>()
        env["PATH"] = (own + (env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []) + searchPaths)
            .filter { seen.insert($0).inserted }.joined(separator: ":")
        env["TF_IN_AUTOMATION"] = "1"
        env["TF_INPUT"] = "0"
        if let c = credentials {
            env["AWS_ACCESS_KEY_ID"] = c.accessKeyId
            env["AWS_SECRET_ACCESS_KEY"] = c.secretAccessKey
            env["AWS_REGION"] = c.region
            env["AWS_DEFAULT_REGION"] = c.region
            if let t = c.sessionToken { env["AWS_SESSION_TOKEN"] = t } else { env.removeValue(forKey: "AWS_SESSION_TOKEN") }
            env.removeValue(forKey: "AWS_PROFILE")
        }
        for (k, v) in tfVars { env["TF_VAR_\(k)"] = v }
        return env
    }

    /// Variables that turn on Terraform's debug logs; never passed to the engine.
    static let logVariables: Set<String> = ["TF_LOG", "TF_LOG_PATH", "TF_LOG_CORE", "TF_LOG_PROVIDER"]

    func run(_ args: [String], in dir: URL, credentials: TerraformCredentials? = nil, tfVars: [String: String] = [:],
             timeout: TimeInterval? = nil, onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> TerraformResult {
        guard let binary, FileManager.default.isExecutableFile(atPath: binary) else { return .notFound }
        // The secrets the engine gets never reach a log, the screen or a saved run, even if it prints them.
        let redactor = Redactor(secrets: [credentials?.secretAccessKey, credentials?.sessionToken].compactMap { $0 } + Array(tfVars.values))
        let onLine: @Sendable (String) -> Void = { line in onLine(redactor.redact(line)) }
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.currentDirectoryURL = dir
        let base = ProcessInfo.processInfo.environment
        // In a container the runtime CLI gets the app's environment only; the values for terraform
        // travel through its stdin, so they are in no file, image or command line.
        var input: Data?
        if let container {
            process.arguments = container.execArguments(args)
            process.environment = Self.environment(base: base, credentials: nil, tfVars: [:], binary: binary)
            let forwarded = Self.environment(base: [:], credentials: credentials, tfVars: tfVars)
            input = StackContainer.stdinBlock(forwarded.filter { $0.key != "PATH" })
        } else {
            process.arguments = args
            process.environment = Self.environment(base: base, credentials: credentials, tfVars: tfVars, binary: binary)
        }
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        let stdout = LineCollector(onLine: onLine), stderr = LineCollector(onLine: onLine)
        out.fileHandleForReading.readabilityHandler = { stdout.feed($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { stderr.feed($0.availableData) }

        let outcome = Outcome()
        let exited: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    outcome.set(.failed(error.localizedDescription))
                    process.terminationHandler = nil
                    done.resume(returning: -1)
                    return
                }
                if let input {
                    DispatchQueue.global().async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: input)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                let limit = timeout ?? self.timeout
                DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                    guard process.isRunning else { return }
                    outcome.set(.timedOut)
                    self.stop(process)
                }
            }
        } onCancel: {
            outcome.set(.cancelled)
            self.stop(process)
        }

        // Drain whatever is left in the pipes after the process ended.
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        stdout.feed(out.fileHandleForReading.readDataToEndOfFile())
        stderr.feed(err.fileHandleForReading.readDataToEndOfFile())
        stdout.finish(); stderr.finish()

        let elapsed = Date().timeIntervalSince(started)
        switch outcome.value {
        case .cancelled: return TerraformResult(status: .cancelled, diagnostic: "Cancelled.", duration: elapsed)
        case .timedOut: return TerraformResult(status: .timedOut, diagnostic: "Timed out after \(Int(elapsed))s.", duration: elapsed)
        case .failed(let message): return TerraformResult(status: .failed, diagnostic: message, duration: elapsed)
        case nil: break
        }
        return Self.result(exitCode: exited, stdout: redactor.redact(stdout.text), stderr: redactor.redact(stderr.text), duration: elapsed)
    }

    static func result(exitCode: Int32, stdout: String, stderr: String, duration: TimeInterval) -> TerraformResult {
        let errors = TerraformDiagnostics.errors(stdout: stdout, stderr: stderr)
        var r = TerraformResult(status: exitCode == 0 ? .success : .failed, exitCode: exitCode, stdout: stdout,
                                stderr: stderr, duration: duration, errors: errors)
        if exitCode != 0 { r.diagnostic = TerraformDiagnostics.message(exitCode: exitCode, stdout: stdout, stderr: stderr, errors: errors) }
        return r
    }

    /// SIGTERM first so terraform can release state locks, SIGKILL if it is still running after 5s.
    /// The runtime CLI does not forward signals to `exec`, so in a container terraform is signalled there too.
    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        if let container, let binary {
            Task.detached {
                _ = await TerraformCLI(binary: binary, timeout: 15)
                    .run(container.runtime.killArguments(container.name), in: FileManager.default.temporaryDirectory)
            }
        }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { kill(pid, SIGKILL) } }
    }
}

/// Replaces known secret values in text with a mask.
struct Redactor: Sendable {
    static let mask = "••••••"
    /// Shorter values (a "1", "true") would mask ordinary output and are not secrets worth hiding.
    static let minimumLength = 6
    let secrets: [String]

    init(secrets: [String]) {
        // Longest first, so a secret that contains another is masked whole.
        self.secrets = Array(Set(secrets.filter { $0.count >= Self.minimumLength })).sorted { $0.count > $1.count }
    }

    func redact(_ text: String) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: Self.mask) }
    }
}

/// How a run ended when it did not end on its own.
private final class Outcome: @unchecked Sendable {
    enum Kind { case cancelled, timedOut, failed(String) }
    private let lock = NSLock()
    private var kind: Kind?
    var value: Kind? { lock.withLock { kind } }
    func set(_ k: Kind) { lock.withLock { if kind == nil { kind = k } } }
}

/// Splits a byte stream into lines, forwards each one and keeps a bounded copy.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void
    private var pending = Data()
    private var captured = ""
    private var capped = false

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    var text: String { lock.withLock { captured } }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            pending.append(data)
            var out: [String] = []
            while let nl = pending.firstIndex(of: 0x0A) {
                out.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
            out.forEach(capture)
            return out
        }
        lines.forEach(onLine)
    }

    func finish() {
        let rest: String? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            let s = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            capture(s)
            return s
        }
        if let rest { onLine(rest) }
    }

    private func capture(_ line: String) {
        if captured.utf8.count < TerraformCLI.maxCapturedChars {
            captured += line + "\n"
        } else if !capped {
            capped = true
            captured += "… [output truncated by Atlas to limit memory] …\n"
        }
    }
}

/// Error extraction and friendly messages for terraform output (ported from Atlas 1.0.1).
enum TerraformDiagnostics {
    /// Terraform 1.x `╷ … ╵` diagnostic blocks that contain an error, or legacy `Error:` lines.
    static func errors(stdout: String, stderr: String) -> [String] {
        let combined = stdout + "\n" + stderr
        let blocks = combined.matches(of: #/(?s)╷(.*?)╵/#).map { String($0.1) }
        if !blocks.isEmpty {
            return blocks
                .map { $0.replacingOccurrences(of: "│ ", with: "").replacingOccurrences(of: "│", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.localizedCaseInsensitiveContains("Error:") }
        }
        return combined.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("error:") }
    }

    static func message(exitCode: Int32, stdout: String, stderr: String, errors: [String]) -> String {
        let text = (stdout + " " + stderr).lowercased()
        func any(_ keys: String...) -> Bool { keys.contains { text.contains($0) } }
        if any("nocredentialproviders", "invalidclienttokenid", "authfailure", "aws_access_key_id", "no credential",
               "token has expired", "expiredtokenexception", "invaliduserexception") {
            return "The AWS credentials are invalid or expired. Check the account's access key in Accounts."
        }
        if any("error acquiring the state lock", "state lock", "lockid") {
            return "The Terraform state is locked by another process. Use 'terraform force-unlock' if that process is gone."
        }
        if any("has not been initialized", "backend initialization") {
            return "The backend is not initialized. Run init first."
        }
        if any("no terraform files", "no configuration files") {
            return "There are no .tf files in this folder. Check the project path."
        }
        if any("could not find plugin", "provider registry", "failed to query available provider packages") {
            return "A provider could not be found. Run init to download the providers."
        }
        if any("accessdenied", "unauthorized", "forbidden") {
            return "Access denied: the AWS user lacks the permissions this operation needs."
        }
        if any("inconsistent result after apply") {
            return "The state became inconsistent after apply. Check the affected resources manually."
        }
        if any("argument or block definition required", "invalid expression", "syntax error") {
            return "The Terraform code has a syntax error. Run validate for details."
        }
        if let first = errors.first { return first.count > 200 ? String(first.prefix(200)) + "…" : first }
        return "terraform exited with code \(exitCode). See the output for details."
    }
}
