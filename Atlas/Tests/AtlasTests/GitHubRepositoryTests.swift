import Foundation
import Testing
@testable import Atlas

/// Records what a fake git was asked to run, and answers with `respond`.
final class GitCalls: @unchecked Sendable {
    struct Call { let args: [String]; let dir: URL; let env: [String: String] }
    private let lock = NSLock()
    private var items: [Call] = []
    var all: [Call] { lock.withLock { items } }
    func add(_ c: Call) { lock.withLock { items.append(c) } }
}

func fakeGit(_ calls: GitCalls, respond: @escaping @Sendable ([String]) -> GitResult = { _ in GitResult(exitCode: 0) }) -> Git {
    var git = Git(binary: "/bin/echo")
    git.runner = { _, args, dir, env, _, onLine in
        calls.add(.init(args: args, dir: dir, env: env))
        let r = respond(args)
        (r.stdout + r.stderr).split(separator: "\n").forEach { onLine(String($0)) }
        return r
    }
    return git
}

private func tempFolder() throws -> URL {
    let dir = TestTemp.root.appendingPathComponent("gh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct GitHubSourceTests {
    @Test func acceptsTheWaysARepositoryIsCopiedFromGitHub() throws {
        for url in ["https://github.com/hashicorp/terraform-guides", "https://github.com/hashicorp/terraform-guides/",
                    "https://github.com/hashicorp/terraform-guides.git", "github.com/hashicorp/terraform-guides",
                    "  https://github.com/hashicorp/terraform-guides\n"] {
            let s = try GitHubSource(url: url)
            #expect(s.owner == "hashicorp" && s.repo == "terraform-guides", "\(url)")
            #expect(s.branch == nil && s.subfolder == nil)
            #expect(s.cloneURL == "https://github.com/hashicorp/terraform-guides.git")
        }
        let s = try GitHubSource(url: "https://github.com/a-b/repo.name_1", branch: " release/v1.2 ", subfolder: "/infra/prod/")
        #expect(s.branch == "release/v1.2" && s.subfolder == "infra/prod")
        #expect(s.label == "a-b/repo.name_1 @ release/v1.2")
    }

    @Test func refusesWhatIsNotARepositoryURL() {
        for url in ["", "https://github.com/", "https://github.com/owner", "https://github.com/owner/repo/tree/main",
                    "https://gitlab.com/owner/repo"] {
            #expect(throws: GitHubSource.Invalid.url, "\(url)") { try GitHubSource(url: url) }
        }
    }

    @Test func branchesAndFoldersAreChecked() throws {
        #expect(GitHubSource.isValidBranch("main") && GitHubSource.isValidBranch("feature/x-1"))
        #expect(!GitHubSource.isValidBranch("a.lock") && !GitHubSource.isValidBranch("a/") && !GitHubSource.isValidBranch("a/.b"))
        #expect(throws: GitHubSource.Invalid.branch) { try GitHubSource(url: "github.com/a/b", branch: "a b") }
        #expect(try GitHubSource.normalized(subfolder: " / ") == nil)
        #expect(try GitHubSource.normalized(subfolder: "my stacks/prod") == "my stacks/prod")
        #expect(throws: GitHubSource.Invalid.subfolder) { try GitHubSource.normalized(subfolder: "a//b") }
    }

    @Test func theStackFolderMustExistInTheClone() throws {
        let clone = try tempFolder()
        try FileManager.default.createDirectory(at: clone.appendingPathComponent("infra/prod"), withIntermediateDirectories: true)
        try Data().write(to: clone.appendingPathComponent("README"))
        #expect(try GitHubSource(owner: "a", repo: "b").stackFolder(in: clone) == clone)
        let sub = try GitHubSource(owner: "a", repo: "b", subfolder: "infra/prod").stackFolder(in: clone)
        #expect(sub.path.hasSuffix("/infra/prod"))
        #expect(throws: GitError.noSubfolder("missing")) { try GitHubSource(owner: "a", repo: "b", subfolder: "missing").stackFolder(in: clone) }
        #expect(throws: GitError.noSubfolder("README")) { try GitHubSource(owner: "a", repo: "b", subfolder: "README").stackFolder(in: clone) }
    }
}

struct GitTests {
    @Test func cloneIsShallowWithoutSubmodulesAndTheURLAfterDashDash() async throws {
        let calls = GitCalls()
        let parent = try tempFolder()
        let target = parent.appendingPathComponent("a-b")
        let git = fakeGit(calls) { args in
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: args.last!).appendingPathComponent("envs/prod"),
                                                     withIntermediateDirectories: true)
            return GitResult(exitCode: 0, stderr: "Cloning into 'a-b'...")
        }
        let lines = GitCalls()
        let folder = try await git.clone(GitHubSource(owner: "a", repo: "b", branch: "dev", subfolder: "envs/prod"), into: target) {
            lines.add(.init(args: [$0], dir: parent, env: [:]))
        }
        #expect(folder.path.hasSuffix("/a-b/envs/prod"))
        #expect(lines.all.map(\.args) == [["Cloning into 'a-b'..."]])
        let call = try #require(calls.all.first)
        let clone = try #require(call.args.firstIndex(of: "clone"))
        #expect(Array(call.args[clone...]) == ["clone", "--depth=1", "--no-recurse-submodules", "--branch=dev", "--single-branch",
                                               "--", "https://github.com/a/b.git", target.path])
        #expect(call.args.starts(with: ["-c", "protocol.allow=never", "-c", "protocol.https.allow=always"]))
        #expect(call.args.contains("core.hooksPath=/dev/null"))
        #expect(call.env["GIT_TERMINAL_PROMPT"] == "0" && call.env["GIT_ASKPASS"] == "")
        #expect(call.dir.standardizedFileURL == parent.standardizedFileURL)
    }

    @Test func cloneRefusesAFolderWithFilesAndAMissingGit() async throws {
        let target = try tempFolder()
        try Data("x".utf8).write(to: target.appendingPathComponent("main.tf"))
        let calls = GitCalls()
        await #expect(throws: GitError.self) { try await fakeGit(calls).clone(GitHubSource(owner: "a", repo: "b"), into: target) }
        #expect(calls.all.isEmpty, "git never ran")
        let missing = Git(binary: nil)
        await #expect(throws: GitError.notInstalled) {
            try await missing.clone(GitHubSource(owner: "a", repo: "b"), into: target.appendingPathComponent("new"))
        }
    }

    @Test func pullOnlyFastForwards() async throws {
        let calls = GitCalls()
        let dir = try tempFolder()
        _ = try await fakeGit(calls).pull(dir)
        let args = try #require(calls.all.first?.args)
        #expect(Array(args.drop { $0 != "pull" }) == ["pull", "--ff-only", "--no-recurse-submodules"])
        let failing = fakeGit(calls) { _ in GitResult(exitCode: 128, stderr: "fatal: Not possible to fast-forward, aborting.") }
        await #expect(throws: GitError.self) { _ = try await failing.pull(dir) }
    }

    @Test func gitFailuresGetClearMessages() {
        func error(_ stderr: String, branch: String? = nil) -> GitError {
            Git.error(GitResult(exitCode: 128, stderr: stderr), branch: branch)
        }
        #expect(error("fatal: could not read Username for 'https://github.com': terminal prompts disabled") == .authRequired)
        #expect(error("remote: Repository not found.\nfatal: repository 'https://github.com/a/b.git/' not found") == .notFound)
        #expect(error("warning: Could not find remote branch nope to clone.\nfatal: Remote branch nope not found in upstream origin",
                      branch: "nope") == .branchNotFound("nope"))
        #expect(error("fatal: unable to access 'https://github.com/a/b.git/': Could not resolve host: github.com") == .network)
        #expect(error("xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools)") == .notInstalled)
        #expect(error("fatal: destination path 'b' already exists and is not an empty directory.") == .folderNotEmpty("The folder"))
        #expect(error("hint: something\nfatal: something odd") == .failed("fatal: something odd"))
        #expect(Git.error(GitResult(exitCode: 3), branch: nil) == .failed("git exited with code 3."))
        #expect(Git.error(GitResult(error: .timedOut), branch: nil) == .timedOut)
        for e: GitError in [.notInstalled, .authRequired, .notFound, .branchNotFound("x"), .network, .folderNotEmpty("~/x"),
                            .noSubfolder("x"), .timedOut, .cancelled, .failed("x")] {
            #expect(!(e.errorDescription ?? "").isEmpty)
        }
        #expect(GitError.authRequired.errorDescription!.contains("gh auth setup-git"))
    }

    /// A real git: a local repository stands in for GitHub (file transport, allowed in this test only).
    @Test(.enabled(if: Git().binary != nil)) func clonesAndPullsARealRepository() async throws {
        let dir = try tempFolder()
        let origin = dir.appendingPathComponent("origin")
        try FileManager.default.createDirectory(at: origin.appendingPathComponent("infra"), withIntermediateDirectories: true)
        try Data("resource \"null_resource\" \"a\" {}\n".utf8).write(to: origin.appendingPathComponent("infra/main.tf"))
        let binary = try #require(Git().binary)
        let env = Git.environment(base: ProcessInfo.processInfo.environment)
        func sh(_ args: [String]) async throws {
            let r = await Git.runProcess(binary, ["-c", "user.name=Atlas", "-c", "user.email=atlas@example.com"] + args,
                                         origin, env, 60, { _ in })
            try #require(r.exitCode == 0, "git \(args): \(r.stderr)")
        }
        try await sh(["init", "-q", "-b", "main"])
        try await sh(["add", "."])
        try await sh(["commit", "-q", "-m", "one"])

        var git = Git(binary: binary)
        git.protocols = ["file"]
        let source = GitHubSource(owner: "a", repo: "b", subfolder: "infra")
        let clone = dir.appendingPathComponent("clone")
        let folder = try await git.clone(source, into: clone, remote: "file://\(origin.path)")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("main.tf").path))

        try Data("# two\n".utf8).write(to: origin.appendingPathComponent("infra/two.tf"))
        try await sh(["add", "."])
        try await sh(["commit", "-q", "-m", "two"])
        _ = try await git.pull(clone)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("two.tf").path))

        // The same clone with https only: the local transport is refused.
        await #expect(throws: GitError.self) {
            try await Git(binary: binary).clone(source, into: dir.appendingPathComponent("refused"), remote: "file://\(origin.path)")
        }
    }

    @Test func aStoppedOrMissingProcessIsReported() async throws {
        let dir = try tempFolder()
        let slow = await Git.runProcess("/bin/sleep", ["5"], dir, [:], 0.2, { _ in })
        #expect(slow.error == .timedOut)
        let missing = await Git.runProcess(dir.appendingPathComponent("nope").path, [], dir, [:], 5, { _ in })
        if case .failed = missing.error {} else { Issue.record("expected a launch failure, got \(String(describing: missing.error))") }
        let task = Task { await Git.runProcess("/bin/sleep", ["5"], dir, [:], 10, { _ in }) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        #expect(await task.value.error == .cancelled)
    }
}

@MainActor
struct GitHubStackTests {
    @Test func aStackRemembersItsRepositoryAndPullsIt() async throws {
        let dir = try tempFolder()
        let clone = dir.appendingPathComponent("a-b")
        let folder = clone.appendingPathComponent("infra")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = StackStore(folder: dir.appendingPathComponent("support"), secrets: InMemorySecretStore())
        let calls = GitCalls()
        let model = StacksModel(store: store, clientFor: { _ in nil }, git: fakeGit(calls) { _ in
            GitResult(exitCode: 0, stdout: "Updating 1..2\nFast-forward")
        })
        let repo = GitHubSource(owner: "a", repo: "b", subfolder: "infra")
        let s = model.create(name: "gh", folder: folder, accountId: "acc", region: "eu-west-1", repository: repo, clone: clone)
        #expect(s.repository == repo && s.clonePath == clone.path)
        #expect(StackStore(folder: dir.appendingPathComponent("support"), secrets: InMemorySecretStore()).load().first?.repository == repo)
        #expect(model.repositoriesFolder.lastPathComponent == "repositories")

        let plans = model.planFiles(for: s).folder
        try PrivateFile.createFolder(plans)
        try Data("plan".utf8).write(to: plans.appendingPathComponent(StacksModel.planFile))
        model.pull(s.id)
        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        let run = try #require(model.stack(s.id)?.lastRun)
        #expect(run.type == .pull && run.status == .success && run.type.label == "Pull" && run.type.phaseName == "Pulling")
        #expect(run.output.contains("Fast-forward"))
        #expect(calls.all.first?.dir.path == clone.path, "pulls the clone's root, not the subfolder")
        #expect(!model.hasSavedPlan(s), "the plan of the old configuration is dropped")

        // A local stack has nothing to pull.
        let local = model.create(name: "local", folder: dir, accountId: "acc", region: "eu-west-1")
        #expect(local.repository == nil && local.clonePath == nil)
        model.pull(local.id)
        #expect(!model.busy.contains(local.id) && model.stack(local.id)?.runs.isEmpty == true)
    }

    @Test func aFailedPullIsAFailedRun() async throws {
        let dir = try tempFolder()
        let store = StackStore(folder: dir.appendingPathComponent("support"), secrets: InMemorySecretStore())
        let model = StacksModel(store: store, clientFor: { _ in nil }, git: fakeGit(GitCalls()) { _ in
            GitResult(exitCode: 128, stderr: "fatal: could not read Username for 'https://github.com': terminal prompts disabled")
        })
        let s = model.create(name: "gh", folder: dir, accountId: "acc", region: "eu-west-1",
                             repository: GitHubSource(owner: "a", repo: "b"))
        model.pull(s.id)
        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        let run = try #require(model.stack(s.id)?.lastRun)
        #expect(run.status == .failed && run.output.contains("gh auth setup-git"))
    }

    @Test func newClonesNeverReuseAFolder() throws {
        let parent = try tempFolder()
        let source = GitHubSource(owner: "a", repo: "b")
        #expect(StacksModel.cloneFolder(for: source, in: parent).lastPathComponent == "a-b")
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("a-b"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("a-b-2"), withIntermediateDirectories: true)
        #expect(StacksModel.cloneFolder(for: source, in: parent).lastPathComponent == "a-b-3")
    }
}
