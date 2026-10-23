import Foundation
import Testing
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
