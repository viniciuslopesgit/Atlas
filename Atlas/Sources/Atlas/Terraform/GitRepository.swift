import Foundation

/// The git repository a stack was cloned from: an https address on GitHub, Bitbucket, GitLab or a server of the user's
/// own (by name, not IP address), an optional branch and the folder inside it that holds the .tf files. Every part is checked strictly, since it
/// ends up in git's arguments and in a path.
struct GitSource: Codable, Sendable, Equatable {
    /// The server, with its port when it has one; nil is github.com (stacks saved by 2.8.0 have no host).
    var host: String?
    /// Everything before the repository's name: `owner` on GitHub, `workspace` on Bitbucket, `group/subgroup` on GitLab.
    var owner: String
    /// The last part of the address, as typed (`repo` or `repo.git`); on GitHub always without `.git`.
    var repo: String
    var branch: String?
    /// Relative to the repository's root, without leading or trailing slashes.
    var subfolder: String?

    enum Invalid: LocalizedError, Equatable {
        case url, credentialsInURL, branch, subfolder

        var errorDescription: String? {
            switch self {
            case .url: "Enter the repository's https address, like https://bitbucket.org/workspace/repository or https://github.com/owner/repository."
            case .credentialsInURL: "Remove the user name or password from the address: Atlas uses the credentials git already has and never saves them in a stack."
            case .branch: "The branch name is not valid (letters, digits, . _ - and /, not starting with - or .)."
            case .subfolder: "The folder must be a path inside the repository, like infra/production (no .. or ~)."
            }
        }
    }

    init(host: String? = nil, owner: String, repo: String, branch: String? = nil, subfolder: String? = nil) {
        self.host = host == Self.github ? nil : host
        self.owner = owner; self.repo = repo; self.branch = branch; self.subfolder = subfolder
    }

    static let github = "github.com"

    static let bitbucket = "bitbucket.org"

    /// Only `https://host[:port]/path/to/repo` (`https://` may be left out): no other scheme or transport (`http`,
    /// `file://`, `ssh://`, `git@…:`, `ext::`), no user or password, query or fragment. The host is a DNS name with a dot;
    /// each part of the path is letters, digits and `. _ ~ -`, never `.`, `..` or starting with `-`. On github.com and
    /// bitbucket.org the path is exactly owner/repository. A page address copied from the browser (a branch or folder
    /// on GitHub, Bitbucket or GitLab) gives the repository, and its branch and folder when those fields are empty.
    init(url: String, branch: String = "", subfolder: String = "") throws {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://"), text.wholeMatch(#"[a-z0-9.-]+\.[a-z]{2,}(:[0-9]{1,5})?/\S+"#) != nil { text = "https://" + text }
        if text.firstMatch(#"^https://[^/?#]*@"#) != nil { throw Invalid.credentialsInURL }
        var urlBranch: String?, urlFolder: String?
        if let page = text.wholeMatch(#"(https://[^/?#\s]+)(/[^?#\s]*)(\?[^#\s]*)?(#\S*)?"#) {
            let host = String(page[1].dropFirst("https://".count))
            let path = page[2].split(separator: "/").map(String.init)
            if let parts = Self.browserPage(path, host: host, query: String(page[3]), branchHint: branch.trimmingCharacters(in: .whitespaces)) {
                text = "https://\(host)/" + parts.repo.joined(separator: "/")
                urlBranch = parts.branch
                urlFolder = parts.folder
            }
        }
        while text.hasSuffix("/") { text.removeLast() }
        let label = #"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"#
        guard let m = text.wholeMatch("https://(\(label)(?:\\.\(label))+(?::[0-9]{1,5})?)((?:/[A-Za-z0-9._~-]{1,100}){2,10})")
        else { throw Invalid.url }
        let host = String(m[1])
        // A name, not an IP address: the last label (the top-level domain) starts with a letter.
        guard host.split(separator: ":")[0].split(separator: ".").last?.first?.isLetter == true else { throw Invalid.url }
        var parts = m[2].split(separator: "/").map(String.init)
        guard parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.hasPrefix("-") }) else { throw Invalid.url }
        if host == Self.bitbucket { guard parts.count == 2 else { throw Invalid.url } }
        if host == Self.github {
            guard parts.count == 2 else { throw Invalid.url }
            if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
            guard !parts[1].isEmpty, parts[1] != ".", parts[1] != ".." else { throw Invalid.url }
        }
        self.host = host == Self.github ? nil : host
        repo = parts.removeLast()
        owner = parts.joined(separator: "/")

        var b = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty, let urlBranch { b = urlBranch }
        if b.isEmpty {
            self.branch = nil
        } else {
            guard Self.isValidBranch(b) else { throw Invalid.branch }
            self.branch = b
        }
        let folder = subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subfolder = try Self.normalized(subfolder: folder.isEmpty ? urlFolder ?? "" : folder)
    }

    /// The repository, branch and folder of a page address: GitHub `owner/repo/tree/<branch>/<folder>`, Bitbucket
    /// `workspace/repo/src/<branch or commit>/<folder>` (with `?at=<branch>`), GitLab `group/repo/-/tree/<branch>/<folder>`.
    /// A branch with slashes is only recognised when it is typed in the Branch field. nil when it is not such a page.
    static func browserPage(_ path: [String], host: String, query: String, branchHint: String)
        -> (repo: [String], branch: String?, folder: String?)? {
        var repo: [String], rest: [String], isFile: Bool
        if let i = path.firstIndex(of: "-"), i >= 2, i + 1 < path.count, ["tree", "blob"].contains(path[i + 1]) {
            repo = Array(path[..<i]); rest = Array(path[(i + 2)...]); isFile = path[i + 1] == "blob"
        } else if host == github, path.count > 2, ["tree", "blob"].contains(path[2]) {
            repo = Array(path[..<2]); rest = Array(path[3...]); isFile = path[2] == "blob"
        } else if host == bitbucket, path.count > 2, path[2] == "src" {
            repo = Array(path[..<2]); rest = Array(path[3...]); isFile = false
        } else if query.isEmpty {
            return nil
        } else {
            return (path, nil, nil)
        }
        var folder = rest.map { $0.removingPercentEncoding ?? $0 }
        if isFile, !folder.isEmpty { folder.removeLast() }
        var branch: String?
        let joined = folder.joined(separator: "/")
        if !branchHint.isEmpty, joined == branchHint || joined.hasPrefix(branchHint + "/") {
            branch = branchHint
            folder = Array(folder.dropFirst(branchHint.split(separator: "/").count))
        } else if !folder.isEmpty {
            let ref = folder.removeFirst()
            // A commit (Bitbucket links to one) is not a branch: the default branch, unless ?at= names one.
            branch = ref.wholeMatch("[0-9a-f]{7,40}") == nil ? ref : nil
        }
        if host == bitbucket, let at = query.firstMatch(#"[?&]at=([^&]+)"#) {
            let name = String(at[1]).removingPercentEncoding ?? String(at[1])
            branch = name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
        }
        return (repo, branch, folder.isEmpty ? nil : folder.joined(separator: "/"))
    }

    /// A conservative subset of git's ref names: it can never read as an option, a revision range or a path outside.
    static func isValidBranch(_ b: String) -> Bool {
        guard b.count <= 200, b.wholeMatch(#"[A-Za-z0-9._/-]+"#) != nil, !b.hasPrefix("-"), !b.hasSuffix("/"),
              !b.hasSuffix(".lock"), !b.hasSuffix("."), !b.contains(".."), !b.contains("//")
        else { return false }
        return !b.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// "", "/" → nil; "infra/prod/" → "infra/prod". `..`, `.`, `~`, backslashes and control characters are refused.
    static func normalized(subfolder: String) throws -> String? {
        let trimmed = subfolder.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard trimmed.count <= 500, !trimmed.hasPrefix("~"), !trimmed.contains("\\"),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw Invalid.subfolder }
        return trimmed
    }

    var hostName: String { host ?? Self.github }
    /// The repository's name without `.git`.
    var name: String { repo.hasSuffix(".git") && repo.count > 4 ? String(repo.dropLast(4)) : repo }
    var webURL: String { "https://\(hostName)/\(owner)/\(name)" }
    /// The address git clones: as typed, and with `.git` on GitHub.
    var cloneURL: String { host == nil ? webURL + ".git" : "https://\(hostName)/\(owner)/\(repo)" }
    /// "owner/repo" (with the server when it is not GitHub), and the branch when there is one.
    var label: String { (host.map { "\($0)/" } ?? "") + "\(owner)/\(name)" + (branch.map { " @ \($0)" } ?? "") }
    /// A folder name for a clone: owner-repo, the path's slashes as dashes.
    var folderName: String { "\(owner)-\(name)".replacingOccurrences(of: "/", with: "-") }

    /// The stack's folder inside a clone: the subfolder, which must exist and, symbolic links resolved, stay inside it.
    func stackFolder(in clone: URL) throws -> URL {
        guard let subfolder else { return clone }
        let root = clone.resolvingSymlinksInPath().standardizedFileURL.path
        let folder = clone.appendingPathComponent(subfolder, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard folder.path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue
        else { throw GitError.noSubfolder(subfolder) }
        return folder
    }
}

/// A user name and token (an API token, app password or personal access token) for a private repository on one
/// server. Kept in the Keychain only; git gets it through its environment as an Authorization header for that server's
/// https address, never on a command line, in a file or in the clone's configuration.
struct GitCredentials: Codable, Sendable, Equatable {
    var username: String
    var token: String

    static func keychainName(_ host: String) -> String { "atlas-git:\(host)" }

    /// Both filled, no control characters (a line break would add a header) and no ":" in the user name.
    var isValid: Bool {
        let ok: (String) -> Bool = { s in
            !s.isEmpty && s.count <= 1000 && s.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        return ok(username) && ok(token) && !username.contains(":")
    }

    var header: String { "Authorization: Basic " + Data("\(username):\(token)".utf8).base64EncodedString() }
}

enum GitError: LocalizedError, Equatable {
    case notInstalled, authRequired, notFound, branchNotFound(String), network, folderNotEmpty(String), noSubfolder(String),
         timedOut, cancelled, failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Git isn't installed. Install Apple's Command Line Tools with: xcode-select --install"
        case .authRequired:
            "The server asked for credentials: the repository is private, doesn't exist, or the token was refused. Turn on Private repository and enter your user name and a token with read access to it (on Bitbucket an API token or app password, on GitHub or GitLab a personal access token); Atlas keeps it in the Keychain. Credentials git already has (gh auth setup-git, the Keychain) work too."
        case .notFound:
            "The repository was not found, or your git credentials can't see it."
        case .branchNotFound(let b):
            "The repository has no branch named \(b)."
        case .network:
            "Could not reach the repository's server. Check the address and the internet connection."
        case .folderNotEmpty(let path):
            "\(path) already exists and is not empty. Choose another folder."
        case .noSubfolder(let f):
            "The repository has no folder \(f). The clone was kept; check the folder name."
        case .timedOut:
            "Git took too long and was stopped."
        case .cancelled:
            "Cancelled."
        case .failed(let message):
            message
        }
    }
}

struct GitResult: Sendable {
    var exitCode: Int32 = -1
    var stdout = ""
    var stderr = ""
    /// Set when git could not be started, timed out or was cancelled.
    var error: GitError?
}

/// Runs git for stacks cloned from a repository: argument arrays only (no shell), no prompts, https only, no hooks or submodules.
struct Git: Sendable {
    typealias Runner = @Sendable (_ binary: String, _ args: [String], _ dir: URL, _ env: [String: String],
                                  _ timeout: TimeInterval, _ onLine: @escaping @Sendable (String) -> Void) async -> GitResult

    var binary: String?
    var timeout: TimeInterval = 600
    /// The transports git may use, also for redirects and submodules. Only https outside tests.
    var protocols = ["https"]
    var runner: Runner = Git.runProcess

    init(binary: String? = TerraformCLI.locate(command: "git"), timeout: TimeInterval = 600) {
        self.binary = binary
        self.timeout = timeout
    }

    /// Settings passed before every command: they win over the user's and the repository's configuration.
    var hardening: [String] {
        ["-c", "protocol.allow=never"] + protocols.flatMap { ["-c", "protocol.\($0).allow=always"] }
            + ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "submodule.recurse=false",
               "-c", "core.askPass="]
    }

    /// The app's environment without any GIT_* variable (GIT_DIR, GIT_SSH_COMMAND, GIT_CONFIG_PARAMETERS… would change
    /// what git runs or where it writes) or askpass program, and with prompts turned off: git fails instead of waiting.
    /// With credentials, git gets them as an Authorization header for `https://<host>/` only, through
    /// GIT_CONFIG_COUNT/KEY/VALUE: not in its arguments (visible to other processes) or in any file.
    static func environment(base: [String: String], credentials: GitCredentials? = nil, host: String? = nil) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("GIT_") && $0.key != "SSH_ASKPASS" && $0.key != "GCM_INTERACTIVE" }
        var seen = Set<String>()
        env["PATH"] = ((env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []) + TerraformCLI.searchPaths)
            .filter { seen.insert($0).inserted }.joined(separator: ":")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = ""
        env["GCM_INTERACTIVE"] = "never"
        if let credentials, credentials.isValid, let host {
            env["GIT_CONFIG_COUNT"] = "1"
            env["GIT_CONFIG_KEY_0"] = "http.https://\(host)/.extraHeader"
            env["GIT_CONFIG_VALUE_0"] = credentials.header
        }
        return env
    }

    /// The arguments of `git clone`: shallow, no submodules, `--` before the URL and the folder.
    func cloneArguments(_ source: GitSource, remote: String, into folder: URL) -> [String] {
        hardening + ["clone", "--depth=1", "--no-recurse-submodules"]
            + (source.branch.map { ["--branch=\($0)", "--single-branch"] } ?? []) + ["--", remote, folder.path]
    }

    var pullArguments: [String] { hardening + ["pull", "--ff-only", "--no-recurse-submodules"] }

    /// Clones the repository into `folder` (which must not exist or be empty) and returns the stack's folder in it.
    /// `remote` replaces the repository's address in tests only, together with `protocols`.
    func clone(_ source: GitSource, into folder: URL, remote: String? = nil, credentials: GitCredentials? = nil,
               onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        if let items = try? FileManager.default.contentsOfDirectory(atPath: folder.path), !items.isEmpty {
            throw GitError.folderNotEmpty(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try await run(cloneArguments(source, remote: remote ?? source.cloneURL, into: folder),
                              in: folder.deletingLastPathComponent(), credentials: credentials, host: source.hostName, onLine: onLine)
        if r.exitCode != 0 { throw Self.error(r, branch: source.branch) }
        return try source.stackFolder(in: folder)
    }

    /// Fast-forwards the clone to its remote branch; it never merges or rewrites local changes.
    func pull(_ clone: URL, host: String? = nil, credentials: GitCredentials? = nil,
              onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws -> GitResult {
        let r = try await run(pullArguments, in: clone, credentials: credentials, host: host, onLine: onLine)
        if r.exitCode != 0 { throw Self.error(r, branch: nil) }
        return r
    }

    private func run(_ args: [String], in dir: URL, credentials: GitCredentials? = nil, host: String? = nil,
                     onLine: @escaping @Sendable (String) -> Void) async throws -> GitResult {
        guard let binary, FileManager.default.isExecutableFile(atPath: binary) else { throw GitError.notInstalled }
        if let credentials, !credentials.isValid { throw GitError.failed("The user name or token is not valid (empty, or with a line break).") }
        // The header must not follow a redirect to another server.
        let args = credentials == nil ? args : ["-c", "http.followRedirects=false"] + args
        let env = Self.environment(base: ProcessInfo.processInfo.environment, credentials: credentials, host: host)
        let r = await runner(binary, args, dir, env, timeout, onLine)
        if let e = r.error { throw e }
        return r
    }

    /// A clear message for what git printed when it failed.
    static func error(_ r: GitResult, branch: String?) -> GitError {
        if let e = r.error { return e }
        let text = (r.stderr + "\n" + r.stdout).lowercased()
        func any(_ keys: String...) -> Bool { keys.contains { text.contains($0) } }
        // /usr/bin/git is a stub that only asks to install the Command Line Tools.
        if any("xcrun: error", "active developer path", "no developer tools") { return .notInstalled }
        if let branch, any("remote branch \(branch.lowercased()) not found", "couldn't find remote ref") {
            return .branchNotFound(branch)
        }
        if any("repository not found", "error: 404") { return .notFound }
        if any("could not read username", "terminal prompts disabled", "authentication failed", "error: 403",
               "invalid username or password", "permission denied") { return .authRequired }
        if any("could not resolve host", "failed to connect", "connection timed out", "network is unreachable") { return .network }
        if any("already exists and is not an empty directory") { return .folderNotEmpty("The folder") }
        if any("not possible to fast-forward", "diverging branches") {
            return .failed("The clone has local commits or changes that the update would overwrite; Atlas only fast-forwards. Resolve them in the folder with git.")
        }
        let line = (r.stderr + "\n" + r.stdout).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.lowercased().hasPrefix("fatal:") || $0.lowercased().hasPrefix("error:") }
        return .failed(line ?? "git exited with code \(r.exitCode).")
    }

    /// Runs git as a child process with an argument array; output is streamed line by line.
    static let runProcess: Runner = { binary, args, dir, env, timeout, onLine in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.currentDirectoryURL = dir
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdout = Captured(onLine: onLine), stderr = Captured(onLine: onLine)
        out.fileHandleForReading.readabilityHandler = { stdout.feed($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { stderr.feed($0.availableData) }
        let stopped = Captured(onLine: { _ in })

        let code: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    stopped.mark(.failed(error.localizedDescription))
                    done.resume(returning: -1)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    stopped.mark(.timedOut)
                    process.terminate()
                }
            }
        } onCancel: {
            stopped.mark(.cancelled)
            if process.isRunning { process.terminate() }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        // Without a child the pipes never reach their end: there is nothing to read.
        if case .failed = stopped.error { return GitResult(exitCode: code, error: stopped.error) }
        stdout.feed(out.fileHandleForReading.readDataToEndOfFile())
        stderr.feed(err.fileHandleForReading.readDataToEndOfFile())
        stdout.finish(); stderr.finish()
        return GitResult(exitCode: code, stdout: stdout.text, stderr: stderr.text, error: stopped.error)
    }
}

/// A stream's text (bounded), forwarded line by line; also holds why a run was stopped.
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void
    private var pending = Data()
    private var captured = ""
    private var stopReason: GitError?

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    var text: String { lock.withLock { captured } }
    var error: GitError? { lock.withLock { stopReason } }
    func mark(_ e: GitError) { lock.withLock { if stopReason == nil { stopReason = e } } }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            pending.append(data)
            var out: [String] = []
            // git ends progress lines with \r: each one is a line too.
            while let nl = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                if !line.isEmpty { out.append(line) }
            }
            if captured.utf8.count < 1_000_000 { out.forEach { captured += $0 + "\n" } }
            return out
        }
        lines.forEach(onLine)
    }

    func finish() {
        let rest: String? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            let s = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            captured += s + "\n"
            return s
        }
        if let rest { onLine(rest) }
    }
}
