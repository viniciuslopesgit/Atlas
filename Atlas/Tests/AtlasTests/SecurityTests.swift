import Foundation
import Testing
import AppKit
@testable import Atlas

/// Attack tests: what an AWS account, a bucket or a stack definition could put in front of Atlas to make it
/// write outside a folder, run a command, leak a credential or rewrite Terraform. They also run inside
/// the sandbox of scripts/test-isolated.sh, where the first test proves the sandbox holds.
@Suite(.serialized)
struct SecurityTests {
    private static let sandboxed = ProcessInfo.processInfo.environment["ATLAS_SANDBOX"] == "1"

    private func tempFolder() throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: The sandbox itself

    @Test("The test process cannot write outside its folder or reach the network", .enabled(if: sandboxed))
    func sandboxHolds() throws {
        let root = try #require(ProcessInfo.processInfo.environment["ATLAS_SANDBOX_ROOT"])
        let canary = URL(fileURLWithPath: root).appendingPathComponent("sandbox-canary-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try Data("x".utf8).write(to: canary) }
        #expect(!FileManager.default.fileExists(atPath: canary.path))

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(443).bigEndian
        addr.sin_addr.s_addr = inet_addr("1.1.1.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(rc != 0, "a connection to the internet went through")

        let mine = TestTemp.root.appendingPathComponent("own-\(UUID().uuidString)")
        try Data("ok".utf8).write(to: mine)
        #expect(FileManager.default.fileExists(atPath: mine.path))
    }

    // MARK: S3 keys chosen by whoever wrote the bucket

    @Test(arguments: ["..", ".", "a/..", "a/.", "../../../etc/passwd", "", "/", "folder/"])
    func downloadNameNeverLeavesTheFolder(key: String) throws {
        let folder = try tempFolder()
        let url = S3Download.destination(forKey: key, in: folder)
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(![".", ".."].contains(url.lastPathComponent))
    }

    @Test func downloadNeverReplacesAnExistingFile() throws {
        let folder = try tempFolder()
        try Data("mine".utf8).write(to: folder.appendingPathComponent("report.csv"))
        try Data("mine".utf8).write(to: folder.appendingPathComponent("report (2).csv"))
        try Data("mine".utf8).write(to: folder.appendingPathComponent("notes"))
        #expect(S3Download.destination(forKey: "x/report.csv", in: folder).lastPathComponent == "report (3).csv")
        #expect(S3Download.destination(forKey: "notes", in: folder).lastPathComponent == "notes (2)")
        #expect(S3Download.destination(forKey: "new.txt", in: folder).lastPathComponent == "new.txt")
    }

    @Test func downloadOntoAFolderFailsWithoutDeletingIt() async throws {
        let folder = try tempFolder()
        let precious = folder.appendingPathComponent("precious.txt")
        try Data("keep".utf8).write(to: precious)
        let client = MockURLProtocol.client { _, _ in .init(body: "object body") }
        client.rememberBucketRegion("b", "us-east-1")
        await #expect(throws: (any Error).self) {
            try await S3Service(client: client).download(bucket: "b", key: "k", to: folder) { _ in }
        }
        #expect(try String(contentsOf: precious, encoding: .utf8) == "keep")
    }

    // MARK: Values written into Terraform

    @Test(arguments: [
        "x\"\n}\nresource \"aws_iam_user\" \"evil\" {\n  name = \"evil",
        "${file(\"~/.aws/credentials\")}",
        "%{ for k in [1] }x%{ endfor }",
        "back\\slash\" and \"quote",
    ])
    func hclStringsStayStrings(value: String) {
        let q = HclGenerator.quote(value)
        #expect(q.hasPrefix("\"") && q.hasSuffix("\""))
        let inner = q.dropFirst().dropLast()
        #expect(!inner.contains("\n"), "a raw newline would end the string")
        // Every quote inside is escaped, so the string cannot be closed early.
        var escaped = false
        for c in inner {
            if c == "\"" { #expect(escaped, "unescaped quote in \(q)") }
            escaped = c == "\\" ? !escaped : false
        }
        #expect(!inner.replacingOccurrences(of: "$${", with: "").contains("${"))
        #expect(!inner.replacingOccurrences(of: "%%{", with: "").contains("%{"))
    }

    @Test func resourceNamesAreBareIdentifiers() {
        for raw in ["../../etc", "a\"b", "x{y}", "1 2 3", "évil name", ""] {
            let id = HclGenerator.identifier(raw)
            #expect(id.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil, "\(raw) → \(id)")
        }
    }

    @Test func taggedBucketCannotInjectResources() {
        var o = CreateBucketOptions()
        o.bucketName = "logs"
        o.region = "eu-west-1"
        o.tags = [("Owner", "x\"\n}\nresource \"aws_iam_user\" \"evil\" {\n")]
        let files = ImportDiscovery.suggestedFiles([TerraformAware.bucket(o)])
        let all = files.values.joined()
        #expect(!all.contains("resource \"aws_iam_user\""))
    }

    // MARK: SSM: the script Terminal runs and the data channel

    @Test(arguments: ["i-1;rm -rf ~", "i-0123456789abcdef0/../../x", "$(id)", "i-ABCDEF12", ""])
    func ssmRejectsTargetsThatAreNotInstanceIds(target: String) {
        #expect(throws: SsmService.SsmError.self) {
            try SsmService.commandScript(executable: "/p", sessionFile: "/t/s", region: "us-east-1", instanceId: target)
        }
    }

    @Test func ssmRejectsRegionsThatAreNotRegions() {
        for region in ["us-east-1; curl evil", "$(id)", "eu-west-1.evil.com/x", ""] {
            #expect(throws: SsmService.SsmError.self) {
                try SsmService.commandScript(executable: "/p", sessionFile: "/t/s", region: region, instanceId: "i-0123456789abcdef0")
            }
        }
    }

    @Test func ssmScriptPathsNeverReachTheShellUnquoted() throws {
        let hostile = "/tmp/'; touch /tmp/pwned; echo '$(id)`id`"
        let script = try SsmService.commandScript(executable: "/Applications/Atlas.app/Contents/MacOS/Atlas",
                                                  sessionFile: hostile, region: "eu-west-1", instanceId: "mi-0123456789abcdef0")
        // Run the script's argument list through a real shell, with Atlas replaced by printf.
        let dir = try tempFolder()
        let file = dir.appendingPathComponent("s.sh")
        let exec = try #require(script.components(separatedBy: "\n").first { $0.hasPrefix("exec ") })
        let line = exec.replacingOccurrences(of: "exec '/Applications/Atlas.app/Contents/MacOS/Atlas'", with: "printf '%s\\n'")
        try Data((line + "\n").utf8).write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [file.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let args = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(p.terminationStatus == 0)
        #expect(args.prefix(2) == ["--ssm-session", hostile], "the path reached Atlas intact, as one argument")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/pwned"))
    }

    @Test(arguments: ["wss://evil.example.com/v1/data-channel/s", "ws://ssmmessages.us-east-1.amazonaws.com/x",
                      "https://ssmmessages.us-east-1.amazonaws.com/x", "wss://ssmmessages.us-east-1.amazonaws.com.evil.io/x",
                      "wss://user:pw@ssmmessages.us-east-1.amazonaws.com/x", "wss://amazonaws.com/x", "not a url"])
    func ssmShellOnlyConnectsToSessionManager(url: String) {
        #expect(throws: SsmShell.ShellError.self) { try SsmShell.streamURL(url) }
    }

    @Test func ssmShellAcceptsRealEndpoints() throws {
        #expect(try SsmShell.streamURL("wss://ssmmessages.eu-west-1.amazonaws.com/v1/data-channel/s-1?role=publish_subscribe").host
                == "ssmmessages.eu-west-1.amazonaws.com")
        _ = try SsmShell.streamURL("wss://ssmmessages.cn-north-1.amazonaws.com.cn/v1/data-channel/s-1")
    }

    @Test func ssmDecoderRejectsMalformedMessages() {
        let good = SsmProtocol.encode(.init(type: "output_stream_data", payloadType: 1, payload: Data("hi".utf8)))
        #expect(throws: SsmProtocol.DecodeError.tooShort) { try SsmProtocol.decode(good.prefix(50)) }
        var lying = good
        lying[116..<120] = Data([0x7F, 0xFF, 0xFF, 0xFF]) // claims a 2 GB payload
        #expect(throws: SsmProtocol.DecodeError.badLength) { try SsmProtocol.decode(lying) }
        var huge = [UInt8](good)
        huge[0..<4] = [0xFF, 0xFF, 0xFF, 0xFF] // header longer than the frame
        #expect(throws: SsmProtocol.DecodeError.badHeader) { try SsmProtocol.decode(Data(huge)) }
        var tampered = good
        tampered[tampered.count - 1] ^= 0xFF
        #expect(throws: SsmProtocol.DecodeError.badDigest) { try SsmProtocol.decode(tampered) }
        #expect(throws: SsmProtocol.DecodeError.badLength) { try SsmProtocol.decode(good + Data([0])) }
    }

    @Test func ssmSessionIgnoresGarbageFromTheSocket() {
        let s = SsmProtocol.Session()
        #expect(s.receive(Data(repeating: 0xFF, count: 4096)).isEmpty)
        #expect(s.receive(Data()).isEmpty)
    }

    // MARK: Credentials

    @Test func terraformGetsCredentialsOnlyThroughTheChildEnvironment() async throws {
        let dir = try tempFolder()
        let bin = dir.appendingPathComponent("terraform")
        try Data("#!/bin/bash\necho \"args: $0 $*\"\n".utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let cli = TerraformCLI(binary: bin.path, timeout: 30)
        let creds = TerraformCredentials(accessKeyId: "AKIDCHILD", secretAccessKey: "very-secret-value", region: "eu-west-1")
        let r = await cli.run(["plan"], in: dir, credentials: creds, onLine: { _ in })
        #expect(r.isSuccess)
        #expect(r.stdout.contains("/terraform plan"), "the fake terraform ran with the plan arguments")
        #expect(!r.fullOutput.contains("very-secret-value"), "the secret appeared in the command line")
        #expect(ProcessInfo.processInfo.environment["AWS_SECRET_ACCESS_KEY"] != "very-secret-value")
    }

    @Test func stackContainersGetSecretsOnlyThroughStdinAndNeverEvaluateThem() async throws {
        let fake = try FakeDocker()
        let c = StackContainer(runtime: fake.runtime, stack: UUID(), engine: .terraform)
        #expect(await c.ensure(folder: fake.workspace, log: { _ in }).isSuccess)
        let pwned = fake.workspace.appendingPathComponent("pwned")
        let creds = TerraformCredentials(accessKeyId: "AKIDBOX", secretAccessKey: "box-secret-value", region: "eu-west-1")
        let r = await TerraformCLI(container: c, timeout: 30).run(
            ["plan"], in: fake.workspace, credentials: creds,
            tfVars: ["db_password": "$(touch \(pwned.path))`touch \(pwned.path)`", "x;touch \(pwned.path)": "1"])
        #expect(r.isSuccess)
        #expect(r.stdout.contains("secret=\(Redactor.mask)"), "terraform in the container got the secret, masked in its output")
        #expect(!r.stdout.contains("box-secret-value"))
        #expect(!fake.log.contains("box-secret-value") && !fake.log.contains("AKIDBOX"), "a secret reached the command line")
        #expect(!FileManager.default.fileExists(atPath: pwned.path), "a value or name was evaluated by the shell")
        // A path that would add mount options is refused.
        #expect(!StackContainer.canMount(URL(fileURLWithPath: "/tmp/x,target=/etc")))
        #expect(!StackContainer.canMount(URL(fileURLWithPath: "/tmp/x:/etc")))
    }

    /// The provider cache shared by an engine's stacks is a new writable mount: it lives in Atlas's own folder, one per
    /// engine, and a path that would add mount options is refused before any container is made.
    @Test func theSharedProviderCacheIsAtlasOwnedPerEngineAndNeverInjectsMountOptions() async throws {
        let fake = try FakeDocker()
        let support = fake.dir.appendingPathComponent("support")
        let store = StackStore(folder: support, secrets: InMemorySecretStore())
        for engine in TerraformEngine.allCases {
            #expect(store.pluginCacheFolder(engine).path.hasPrefix(support.path + "/plugin-cache/"))
        }
        #expect(store.pluginCacheFolder(.terraform) != store.pluginCacheFolder(.tofu))
        let c = StackContainer(runtime: fake.runtime, stack: UUID(), engine: .terraform)
        let odd = fake.dir.appendingPathComponent("cache,target=/etc", isDirectory: true)
        let r = await c.ensure(folder: fake.workspace, plugins: odd, log: { _ in })
        #expect(!r.isSuccess && r.diagnostic.contains("cannot be mounted"))
        #expect(!fake.log.contains("create"), "no container was made with the injected option")
    }

    /// Deleting a stack removes only Atlas's data folder for it, named by the stack's id, never the stack's folder,
    /// even when the stack's folder is inside Atlas's own folder.
    @Test @MainActor func deletingAStackRemovesOnlyItsOwnDataFolder() async throws {
        let support = TestTemp.root.appendingPathComponent("support-\(UUID().uuidString)", isDirectory: true)
        let project = support.appendingPathComponent("stacks", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("resource {}".utf8).write(to: project.appendingPathComponent("main.tf"))
        let store = StackStore(folder: support, secrets: InMemorySecretStore())
        let model = StacksModel(store: store, clientFor: { _ in nil }, makeCLI: { _ in TerraformCLI(binary: nil) })
        let s = model.create(name: "inside", folder: project, accountId: "a", region: "eu-west-1")
        let other = UUID()
        try PrivateFile.createFolder(store.dataFolder(other, .terraform))
        #expect(store.stacksFolder(s.id).deletingLastPathComponent().standardizedFileURL == project.standardizedFileURL)
        _ = model.delete(s.id)
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("main.tf").path))
        #expect(FileManager.default.fileExists(atPath: store.dataFolder(other, .terraform).path), "another stack's data stays")
    }

    /// The stand-in `aws` signs with the stack's credentials: a cluster name, region or token from the configuration
    /// cannot add headers, run commands or get the secret printed.
    @Test func theAwsStandInRejectsHostileArgumentsAndNeverPrintsTheSecret() throws {
        let pwned = TestTemp.root.appendingPathComponent("aws-pwned-\(UUID().uuidString)")
        let env = ["AWS_ACCESS_KEY_ID": "AKIDEXAMPLE", "AWS_SECRET_ACCESS_KEY": "stand-in-secret-value", "AWS_REGION": "eu-west-1"]
        for args in [["--cluster-name", "c\nhost:evil.example"], ["--cluster-name", "$(touch \(pwned.path))"],
                     ["--cluster-name", "c", "--region", "eu-west-1;touch \(pwned.path)"], ["--cluster-name", "c", "--role-arn", "x"]] {
            let r = try StacksContainerModelTests.runAws(["eks", "get-token"] + args, env: env)
            #expect(r.status != 0, "accepted \(args)")
            #expect(!r.out.contains("stand-in-secret-value") && !r.err.contains("stand-in-secret-value"))
        }
        var badToken = env
        badToken["AWS_SESSION_TOKEN"] = "abc&X-Amz-Expires=99999"
        #expect(try StacksContainerModelTests.runAws(["eks", "get-token", "--cluster-name", "c"], env: badToken).status != 0)
        let ok = try StacksContainerModelTests.runAws(["eks", "get-token", "--cluster-name", "c"], env: env)
        #expect(ok.status == 0 && !ok.out.contains("stand-in-secret-value"))
        #expect(!FileManager.default.fileExists(atPath: pwned.path), "an argument was evaluated by the shell")
    }

    @Test func dockerDesktopComesOnlyFromDockerAndMustBeSignedByDocker() {
        let url = DockerDesktopInstaller.downloadURL
        #expect(url.scheme == "https" && url.host == "desktop.docker.com")
        // Apple-signed code that is not Docker Inc's, and code that does not exist, are refused.
        #expect(!DockerDesktopInstaller.isSignedByDocker(URL(fileURLWithPath: "/usr/bin/true")))
        #expect(!DockerDesktopInstaller.isSignedByDocker(URL(fileURLWithPath: "/nonexistent/Docker.app")))
    }

    @Test func stackSecretsAndOutputNeverReachTheDiskInPlainText() throws {
        let folder = try tempFolder()
        let secrets = InMemorySecretStore()
        let store = StackStore(folder: folder, secrets: secrets)
        var stack = StackEntry(name: "prod", projectPath: folder.path, accountId: "a", region: "eu-west-1")
        stack.envVars = [StackEnvVar(tfVarName: "db_password", envKey: "TF_VAR_db_password", value: "hunter2-db",
                                     resourceType: "aws_db_instance", resourceName: "main", sourceFile: "rds.tf")]
        var run = StackRun(type: .plan, trigger: "manual")
        run.output = "Outputs:\nconnection = \"postgres://admin:hunter2-out@db\"\n"
        stack.runs = [run]
        store.save([stack])

        let disk = try String(contentsOf: folder.appendingPathComponent("stacks.json"), encoding: .utf8)
        #expect(!disk.contains("hunter2-db") && !disk.contains("hunter2-out"))
        let loaded = try #require(store.load().first)
        #expect(loaded.envVars.first?.value == "hunter2-db")
        #expect(loaded.runs.first?.output.contains("hunter2-out") == true)

        // Without the key (another Mac, a copied file) the output cannot be read back.
        let elsewhere = StackStore(folder: folder, secrets: InMemorySecretStore())
        #expect(elsewhere.load().first?.runs.first?.output.contains("hunter2-out") != true)
    }

    @Test func tamperedStackOutputIsRejected() throws {
        let key = SymmetricKeyFixture.key
        let sealed = try #require(StackStore.encrypt("terraform output", key: key))
        var bytes = try #require(Data(base64Encoded: sealed))
        bytes[bytes.count - 1] ^= 0x01
        #expect(StackStore.decrypt(bytes.base64EncodedString(), key: key) == nil)
    }

    // MARK: Where signed requests go

    @Test(arguments: ["evil.example#", "evil.example/x?", "x.evil.example:443/", "us-east-1@evil.example"])
    func aRegionCannotSendSignedRequestsToAnotherHost(region: String) async throws {
        let client = MockURLProtocol.client(region: region) { _, _ in .init(body: "<R/>") }
        await #expect(throws: AWSError.self) { _ = try await client.query(.ec2, "DescribeInstances") }
        await #expect(throws: AWSError.self) { _ = try await client.s3(method: "GET", bucket: "b") }
        #expect(MockURLProtocol.requests.isEmpty, "a signed request left for a non-AWS host")
    }

    @Test func aBucketNameCannotSendSignedRequestsToAnotherHost() async throws {
        let client = MockURLProtocol.client { _, _ in .init(body: "x") }
        let folder = try tempFolder()
        for bucket in ["evil#", "evil?x", "me@evil", "evil/x"] {
            client.rememberBucketRegion(bucket, "us-east-1")
            await #expect(throws: AWSError.self) {
                try await S3Service(client: client).download(bucket: bucket, key: "k", to: folder.appendingPathComponent("f")) { _ in }
            }
        }
        #expect(MockURLProtocol.requests.isEmpty)
        #expect(AWSClient.isAWSEndpoint(URL(string: "https://s3.eu-west-1.amazonaws.com/b")))
        #expect(AWSClient.isAWSEndpoint(URL(string: "https://ec2.cn-north-1.amazonaws.com.cn/")))
        #expect(!AWSClient.isAWSEndpoint(URL(string: "http://ec2.us-east-1.amazonaws.com/")))
        #expect(!AWSClient.isAWSEndpoint(URL(string: "https://amazonaws.com.evil.example/")))
    }

    @Test func aDetectorIdCannotRewriteGuardDutyRequestPaths() async throws {
        let client = MockURLProtocol.client { req, _ in
            req.url!.path == "/detector" ? .init(body: #"{"detectorIds":["../../x?y", "a/b", "ok1"]}"#) : .init(body: "{}")
        }
        #expect(try await GuardDutyService(client: client).detectorId() == "ok1")
        _ = try await GuardDutyService(client: client).findings()
        #expect(MockURLProtocol.requests.map { $0.request.url!.path }.allSatisfy { $0 == "/detector" || $0.hasPrefix("/detector/ok1/") })
    }

    @Test func bucketSettingsCannotInjectXML() async throws {
        let client = MockURLProtocol.client { _, _ in .init() }
        let evil = "</Value></Tag><Tag><Key>owner</Key><Value>attacker"
        try await S3Service(client: client).setTags("b", [.init(key: "k", value: evil)])
        try await S3Service(client: client).setLifecycle("b", [.init(ruleId: "</ID><Status>", prefix: "<Expiration>", expirationDays: 1)])
        try await S3Service(client: client).setEncryption("b", .sseKms, kmsKeyId: "</KMSMasterKeyID>x", bucketKey: false)
        for r in MockURLProtocol.requests {
            let xml = try #require(XNode.parse(r.body))
            #expect(xml.find("Value")?.text == evil || xml.find("Value") == nil)
        }
        let tags = try #require(XNode.parse(MockURLProtocol.requests[0].body))
        #expect(tags.list("TagSet", item: "Tag").count == 1)
        let rules = try #require(XNode.parse(MockURLProtocol.requests[1].body)).all("Rule")
        #expect(rules.map { $0.str("ID") } == ["</ID><Status>"])
        #expect(rules[0].str("Filter/Prefix") == "<Expiration>")
        #expect(try #require(XNode.parse(MockURLProtocol.requests[2].body)).find("KMSMasterKeyID")?.text == "</KMSMasterKeyID>x")
    }

    @Test func awsResponsesAreNeverCachedOnDiskOrGiveCookies() {
        let client = AWSClient(credentials: AWSCredentials(accessKeyId: "AKID", secretAccessKey: "s"), region: "us-east-1")
        #expect(client.session.configuration.urlCache == nil)
        #expect(client.session.configuration.httpCookieStorage == nil)
        #expect(client.session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func aNonAWSErrorPageIsCutShort() {
        let page = "<html>" + String(repeating: "x", count: 100_000)
        let e = AWSClient.error(from: Data(page.utf8), status: 502)
        #expect(e.message.count <= AWSClient.maxErrorBody + 1)
    }

    // MARK: Private files

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func accountsFileIsReadableOnlyByTheUser() throws {
        let folder = try tempFolder().appendingPathComponent("Atlas")
        let store = AccountStore(folder: folder)
        store.save([AwsAccount(name: "prod", accessKeyId: "AKIDPROD", defaultRegion: "us-east-1", isActive: true)])
        #expect(try permissions(folder.appendingPathComponent("accounts.json")) == 0o600)
        #expect(try permissions(folder) == 0o700)
        #expect(store.load().map(\.accessKeyId) == ["AKIDPROD"])
    }

    @Test func privateKeyIsWrittenOwnerOnlyAndCanReplaceAnOldOne() throws {
        let folder = try tempFolder()
        let pem = folder.appendingPathComponent("key.pem")
        try PrivateFile.write(Data("old".utf8), to: pem, permissions: 0o400)
        try PrivateFile.write(Data("new key".utf8), to: pem, permissions: 0o400)
        #expect(try permissions(pem) == 0o400)
        #expect(try String(contentsOf: pem, encoding: .utf8) == "new key")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["key.pem"], "a temporary file was left")
    }

    @Test func privateFileNeverWritesThroughASymlink() throws {
        let folder = try tempFolder()
        let target = folder.appendingPathComponent("elsewhere")
        try Data("keep".utf8).write(to: target)
        let link = folder.appendingPathComponent("key.pem")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try PrivateFile.write(Data("secret".utf8), to: link)
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(try permissions(link) == 0o600)
    }

    @Test func privateFileNeverReplacesAFolderAndLeavesNoTemporaryFile() throws {
        let folder = try tempFolder()
        let target = folder.appendingPathComponent("key.pem", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: target.appendingPathComponent("inside"))
        #expect(throws: POSIXError.self) { try PrivateFile.write(Data("secret".utf8), to: target) }
        #expect(try String(contentsOf: target.appendingPathComponent("inside"), encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["key.pem"], "a temporary file was left")
    }

    @Test func privateFileFailsCleanlyInAMissingFolder() throws {
        let missing = try tempFolder().appendingPathComponent("no/such/key.pem")
        #expect(throws: POSIXError.self) { try PrivateFile.write(Data("x".utf8), to: missing) }
    }

    // MARK: Feedback

    @Test func feedbackCannotAddRecipientsOrHeaders() throws {
        var f = Feedback()
        f.subject = "hi&cc=evil@example.com&bcc=evil@example.com"
        f.description = "body\r\nBcc: evil@example.com"
        let url = try #require(f.mailURL(systemInfo: "test"))
        let c = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(c.path == Feedback.recipient)
        #expect(Set(c.queryItems?.map(\.name) ?? []) == ["subject", "body"])
    }
}

import CryptoKit

private enum SymmetricKeyFixture {
    static let key = SymmetricKey(size: .bits256)
}

// MARK: - Secrets at rest and in output

/// Plan files, run output, the stacks file and the pasteboard were places a secret could be read back from.
struct SecretLeakTests {
    private func folder(_ name: String) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    /// An engine that prints what it was given (a provider error, a debug line, a `local-exec`…) must not put
    /// the secret key, session token or variable values into the run's output, its saved log or the drift report.
    @Test func secretsTheEngineGetsAreMaskedInEverythingItPrints() async throws {
        let dir = try folder("redact")
        let bin = dir.appendingPathComponent("terraform")
        try Data("""
        #!/bin/bash
        echo "secret=$AWS_SECRET_ACCESS_KEY token=$AWS_SESSION_TOKEN db=$TF_VAR_db_password"
        echo "log=${TF_LOG:-none} path=${TF_LOG_PATH:-none}" >&2
        exit 1
        """.utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        setenv("TF_LOG", "TRACE", 1)
        defer { unsetenv("TF_LOG") }
        let lines = LockedLines()
        let creds = TerraformCredentials(accessKeyId: "AKIAVISIBLE", secretAccessKey: "wJalrSECRETkey/EXAMPLE",
                                         region: "eu-west-1", sessionToken: "IQoSESSIONtoken==")
        let r = await TerraformCLI(binary: bin.path).run(["plan"], in: dir, credentials: creds,
                                                         tfVars: ["db_password": "hunter2-db-pass", "flag": "1"],
                                                         onLine: { lines.add($0) })
        let everything = r.fullOutput + r.diagnostic + r.errors.joined() + lines.all.joined(separator: "\n")
        for secret in ["wJalrSECRETkey/EXAMPLE", "IQoSESSIONtoken==", "hunter2-db-pass"] {
            #expect(!everything.contains(secret), "\(secret) reached the output")
        }
        #expect(r.stdout.contains("secret=\(Redactor.mask) token=\(Redactor.mask) db=\(Redactor.mask)"))
        #expect(r.stderr.contains("log=none path=none"), "Terraform's debug logs stay off")
        #expect(Redactor(secrets: ["1", "abcdef", "abcdefgh"]).redact("1 abcdefgh abcdef") == "1 \(Redactor.mask) \(Redactor.mask)")
    }

    /// A plan file holds the configuration and the variables in plain text: it is saved in Atlas's folder (0700),
    /// never in the stack's or project's folder, which may be shared, synced or committed.
    @Test @MainActor func planFilesAreKeptOutOfTheStackFolder() async throws {
        let dir = try folder("plans")
        let bin = dir.appendingPathComponent("terraform")
        try Data("""
        #!/bin/bash
        for a in "$@"; do case "$a" in -out=*) echo "plan with hunter2" > "${a#-out=}" ;; esac; done
        exit 2
        """.utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let project = try folder("stack")
        try Data("old plan".utf8).write(to: project.appendingPathComponent(StacksModel.planFile))
        let support = dir.appendingPathComponent("support")
        let model = StacksModel(store: StackStore(folder: support, secrets: InMemorySecretStore()), clientFor: { _ in nil },
                                makeCLI: { _ in TerraformCLI(binary: bin.path) })
        let s = model.create(name: "s", folder: project, accountId: "a", region: "eu-west-1")
        model.plan(s.id)
        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        let plans = model.planFiles(for: s)
        #expect(model.hasSavedPlan(s))
        #expect(plans.folder.path.hasPrefix(support.path))
        #expect(try permissions(plans.folder) == 0o700)
        let inProject = try FileManager.default.contentsOfDirectory(atPath: project.path)
        #expect(!inProject.contains { $0.hasSuffix(".tfplan") }, "a plan was left in the stack's folder: \(inProject)")

        let projects = try folder("iac")
        let store = TerraformProjectStore(folder: projects)
        let id = UUID()
        #expect(store.planFolder(id).path.hasPrefix(projects.path) && store.planFolder(id).path.contains(id.uuidString))
        store.save(.init(projects: [TerraformProject(id: id, name: "p", path: project.path)], activeId: id))
        #expect(try permissions(projects.appendingPathComponent("terraform-projects.json")) == 0o600)
    }

    /// stacks.json was written with the default permissions, and a drift report (which can show resource values) was
    /// in it in plain text.
    @Test func theStacksFileIsPrivateAndTheDriftReportEncrypted() throws {
        let support = try folder("stacks-json")
        let store = StackStore(folder: support, secrets: InMemorySecretStore())
        var s = StackEntry(name: "s", projectPath: "/tmp/s", accountId: "a", region: "eu-west-1")
        s.driftStatus = .drifted
        s.driftSummary = "1 to change"
        s.driftDiff = "~ password = \"hunter2-drift\""
        store.save([s])
        let file = support.appendingPathComponent("stacks.json")
        #expect(try permissions(file) == 0o600)
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("hunter2-drift") && !raw.contains("1 to change"))
        let loaded = try #require(StackStore(folder: support, secrets: store.secrets).load().first)
        #expect(loaded.driftDiff == s.driftDiff && loaded.driftSummary == "1 to change" && loaded.driftStatus == .drifted)
    }

    /// A copied secret access key is marked concealed and transient, and cleared unless something else was copied.
    @Test @MainActor func copiedSecretsAreConcealedAndCleared() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        Clipboard.copy("AKIAPLAIN", to: board)
        #expect(board.types?.contains(Clipboard.concealedType) != true)
        Clipboard.copy("wJalrSECRET", secret: true, to: board)
        #expect(board.string(forType: .string) == "wJalrSECRET")
        #expect(board.types?.contains(Clipboard.concealedType) == true && board.types?.contains(Clipboard.transientType) == true)
        let count = board.changeCount
        #expect(Clipboard.clear(board, ifStill: count))
        #expect(board.string(forType: .string) == nil)
        Clipboard.copy("wJalrSECRET", secret: true, to: board)
        let stale = board.changeCount
        Clipboard.copy("something else", to: board)
        #expect(!Clipboard.clear(board, ifStill: stale), "what the user copied later is left alone")
        #expect(board.string(forType: .string) == "something else")
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

/// Moving the state deletes files in the user's folder: only the engine's two local state files, and only once the
/// state was read back from S3.
struct StateMigrationTests {
    @Test @MainActor func movingTheStateRemovesOnlyTheStateFilesAndOnlyAfterReadingItBack() async throws {
        let dir = try StackStateTests.folder()
        let bin = try StackStateTests.engine(in: dir)
        let client = StackStateTests.client()
        let model = StacksModel(store: StackStore(folder: dir.appendingPathComponent("support"), secrets: InMemorySecretStore()),
                                clientFor: { _ in client }, makeCLI: { _ in TerraformCLI(binary: bin) })
        let project = dir.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for name in StateBackend.localStateFiles + ["main.tf", "notes.tfstate.txt"] {
            try Data("{\"secret\": \"hunter2\"}".utf8).write(to: project.appendingPathComponent(name))
        }
        let s = model.create(name: "legacy", folder: project, accountId: "a", region: "eu-west-1")

        // The state can't be read back from S3: nothing is removed.
        try Data().write(to: dir.appendingPathComponent("failList"))
        model.moveStateToS3(s.id)
        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(model.stack(s.id)?.lastRun?.status == .failed)
        #expect(StateBackend.hasLocalState(in: project), "kept when the copy could not be checked")

        try FileManager.default.removeItem(at: dir.appendingPathComponent("failList"))
        model.moveStateToS3(s.id)
        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        let run = try #require(model.stack(s.id)?.lastRun)
        #expect(run.type == .migrateState && run.status == .success, "\(run.output)")
        #expect(run.phases.map(\.name) == ["Preparing state", "Moving state", "Verifying"])
        let calls = try String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)
        #expect(calls.contains("init -no-color -migrate-state -force-copy") && calls.contains("state list"))
        #expect(!StateBackend.hasLocalState(in: project))
        for kept in ["main.tf", "notes.tfstate.txt", StateBackend.file] {
            #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent(kept).path), "\(kept) was removed")
        }

        // A configuration with its own backend is never rewritten.
        let other = dir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("terraform {\n  backend \"gcs\" {}\n}\n".utf8).write(to: other.appendingPathComponent("backend.tf"))
        try Data("{\"version\": 4}".utf8).write(to: other.appendingPathComponent("terraform.tfstate"))
        let o = model.create(name: "other", folder: other, accountId: "a", region: "eu-west-1")
        model.moveStateToS3(o.id)
        for _ in 0..<300 where model.busy.contains(o.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(model.stack(o.id)?.lastRun?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent(StateBackend.file).path))
        #expect(StateBackend.hasLocalState(in: other))
    }
}

/// The diagram opens documentation links and module folders built from the stack's files: a crafted .tf file must
/// not make Atlas open another site or a folder outside the stack.
struct DiagramLinkTests {
    @Test func docsLinksOnlyGoToTheTerraformRegistry() {
        #expect(TerraformDocs.url(type: "aws_s3_bucket", kind: .resource)?.absoluteString
                == "https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket")
        #expect(TerraformDocs.url(type: "aws_iam_policy_document", kind: .data)?.absoluteString
                == "https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document")
        for type in ["aws_x/../../../evil", "aws_x?u=https://evil.example", "aws_x#frag", "evil_bucket", "aws", "AWS_S3_BUCKET",
                     "aws_x@evil.example", "aws_x\nhttps://evil"] {
            #expect(TerraformDocs.url(type: type, kind: .resource) == nil, "\(type)")
        }
        #expect(TerraformDocs.url(type: "aws_s3_bucket", kind: .module) == nil)
        for source in ["https://evil.example/a/b/c", "git::https://evil.example/x.git", "../a/b/c", "a/b/c?x=y", "//evil.example/a/b",
                       "a/b/c/../../d", "a@evil.example/b/c"] {
            #expect(TerraformDocs.url(moduleSource: source) == nil, "\(source)")
        }
        #expect(TerraformDocs.url(moduleSource: "terraform-aws-modules/vpc/aws")?.host == "registry.terraform.io")
        #expect(TerraformDocs.url(moduleSource: "registry.terraform.io/terraform-aws-modules/vpc/aws")?.host == "registry.terraform.io")
    }

    @Test func modulesOnlyOpenInsideTheStack() throws {
        let base = TestTemp.root.appendingPathComponent("diagram-\(UUID().uuidString)")
        let root = base.appendingPathComponent("stack")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("modules/vpc"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("outside"))
        try "x".write(to: root.appendingPathComponent("file.tf"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: base) }

        let inside = TerraformDocs.localModule("./modules/vpc", from: root, root: root)
        #expect(inside?.lastPathComponent == "vpc")
        // From a module, going back up into the stack is fine.
        #expect(TerraformDocs.localModule("../vpc", from: root.appendingPathComponent("modules/vpc"), root: root) != nil)
        for source in ["../outside", "./../outside", "./link", "./modules/../../outside", "/etc", "./missing", "./file.tf",
                       "git::https://evil.example/x.git", "terraform-aws-modules/vpc/aws", "~/Library"] {
            #expect(TerraformDocs.localModule(source, from: root, root: root) == nil, "\(source)")
        }
    }

    @Test func oversizedFilesAreNotRead() throws {
        let folder = TestTemp.root.appendingPathComponent("diagram-big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = "resource \"aws_vpc\" \"a\" {}\n" + String(repeating: "#", count: TerraformConfig.maxFileBytes)
        try big.write(to: folder.appendingPathComponent("big.tf"), atomically: true, encoding: .utf8)
        #expect(TerraformConfig.graph(folder: folder).nodes.isEmpty)
    }

    // MARK: Stacks from git repositories

    @Test func onlyHttpsRepositoriesAreCloned() {
        let attacks = [
            "file:///etc", "file://github.com/a/b", "ext::sh -c touch% /tmp/pwned", "ssh://git@bitbucket.org/a/b",
            "git@bitbucket.org:a/b.git", "git://github.com/a/b", "http://bitbucket.org/a/b", "https://evil..com/a/b",
            "https://-evil.com/a/b", "https://bitbucket.org:99999x/a/b", "https://127.0.0.1/a/b", "https://10.0.0.1:8443/a/b", "https://localhost/a/b",
            "https://[::1]/a/b", "https://bitbucket.org/a/b?ref=x", "https://bitbucket.org/a/b#x", "https://github.com/-a/b",
            "https://bitbucket.org/a/-b", "https://github.com/a/--upload-pack=touch", "https://bitbucket.org/a/../c",
            "https://bitbucket.org/a/..", "https://bitbucket.org/./a/b", "https://github.com/a/b\nhttps://evil.com/x/y",
            "https://bitbucket.org/a/$(touch x)", "https://bitbucket.org/a/b;rm", "https://bitbucket.org/a/`id`",
            "-uhttps://github.com/a/b", "--upload-pack=touch /tmp/x", "https://GITHUB.com/a/b", "https://bitbucket.org/a/b c",
            "https://bitbucket.org/a%2F..%2Fb/c", "https://bitbucket.org\\@evil.com/a/b", "https://github.com/a/b/c",
        ]
        for url in attacks {
            #expect(throws: (any Error).self, "\(url)") { try GitSource(url: url) }
        }
        // A user or password in the address would be saved with the stack, in plain text: refused.
        for url in ["https://user@bitbucket.org/a/b", "https://x-token-auth:secret@bitbucket.org/a/b", "https://:t@github.com/a/b"] {
            #expect(throws: GitSource.Invalid.credentialsInURL, "\(url)") { try GitSource(url: url) }
        }
    }

    @Test func branchesCannotBecomeGitOptions() {
        for branch in ["--upload-pack=touch /tmp/x", "-b", "-", "main..dev", "../../x", "a;rm -rf ~", "$(touch x)", "`x`",
                       "a b", "a\nb", "@{-1}", "~1", "refs/../x", ".hidden", "a/.b", "a//b", "x.lock", "a/"] {
            #expect(throws: GitSource.Invalid.branch, "\(branch)") { try GitSource(url: "https://github.com/a/b", branch: branch) }
        }
        // A valid branch still reaches git bound to --branch=, before the "--" that ends the options.
        let args = Git(binary: "/bin/echo").cloneArguments(GitSource(owner: "a", repo: "b", branch: "dev"), remote: "u",
                                                           into: URL(fileURLWithPath: "/x"))
        #expect(args.contains("--branch=dev") && !args.contains("dev"))
        #expect(args.suffix(3) == ["--", "u", "/x"])
    }

    @Test func theSubfolderStaysInsideTheClone() throws {
        for sub in ["..", "../..", "a/../../b", "./a", "a/./b", "~", "~/x", "a\\..\\b", "a\u{0}b", "a\nb"] {
            #expect(throws: GitSource.Invalid.subfolder, "\(sub)") { try GitSource(url: "https://github.com/a/b", subfolder: sub) }
        }
        // A symbolic link in the repository that points outside it is refused after the clone.
        let dir = TestTemp.root.appendingPathComponent("gh-sec-\(UUID().uuidString)", isDirectory: true)
        let clone = dir.appendingPathComponent("clone")
        let outside = dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: clone.appendingPathComponent("infra"), withDestinationURL: outside)
        #expect(throws: GitError.noSubfolder("infra")) {
            try GitSource(owner: "a", repo: "b", subfolder: "infra").stackFolder(in: clone)
        }
        // A clone folder whose name starts like the clone's (clone-evil) is outside too.
        let sibling = dir.appendingPathComponent("clone-evil")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: clone.appendingPathComponent("x"), withDestinationURL: sibling)
        #expect(throws: GitError.noSubfolder("x")) { try GitSource(owner: "a", repo: "b", subfolder: "x").stackFolder(in: clone) }
    }

    @Test func gitRunsWithoutPromptsHooksOrTheCallersGitVariables() {
        let env = Git.environment(base: ["GIT_SSH_COMMAND": "touch /tmp/pwned", "GIT_DIR": "/etc", "GIT_CONFIG_PARAMETERS": "'core.sshCommand=x'",
                                         "GIT_CONFIG_COUNT": "1", "GIT_EXEC_PATH": "/tmp", "SSH_ASKPASS": "/tmp/x", "HOME": "/Users/x"])
        #expect(env.keys.filter { $0.hasPrefix("GIT_") }.sorted() == ["GIT_ASKPASS", "GIT_TERMINAL_PROMPT"])
        #expect(env["GIT_TERMINAL_PROMPT"] == "0" && env["GIT_ASKPASS"] == "" && env["SSH_ASKPASS"] == nil && env["HOME"] == "/Users/x")
        let h = Git(binary: "/bin/echo").hardening
        for setting in ["protocol.allow=never", "protocol.https.allow=always", "core.hooksPath=/dev/null", "core.fsmonitor=false",
                        "submodule.recurse=false"] {
            #expect(h.contains(setting), "\(setting)")
        }
        #expect(!h.contains { $0.hasPrefix("protocol.file") || $0.hasPrefix("protocol.ext") || $0.hasPrefix("protocol.ssh") })
        #expect(Git(binary: "/bin/echo").pullArguments.contains("--ff-only"))
    }
}
