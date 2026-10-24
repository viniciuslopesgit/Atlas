import AppKit
import Foundation

/// Opens an interactive SSM shell in Terminal.app: StartSession through our client, then Atlas's own
/// executable (`--ssm-session`, see SsmShell) takes over the I/O. Nothing to install: no AWS CLI, no
/// session-manager-plugin, and no access keys or session token on any command line.
struct SsmService {
    let client: AWSClient

    struct Session: Equatable {
        let sessionId: String
        let streamUrl: String
        let tokenValue: String
    }

    enum SsmError: LocalizedError {
        case notConnected(String)
        case invalidTarget(String)

        var errorDescription: String? {
            switch self {
            case .notConnected(let id):
                "Instance \(id) is not connected to SSM. Check that the SSM Agent is running, the instance profile has "
                    + "AmazonSSMManagedInstanceCore, and the instance can reach the SSM endpoints."
            case .invalidTarget(let id):
                "\"\(id)\" is not an EC2 instance or managed node ID."
            }
        }
    }

    private var host: String { "ssm.\(client.region).amazonaws.com" }

    func startSession(instanceId: String) async throws -> Session {
        do {
            let r = try await client.json(host: host, signingName: "ssm", signingRegion: client.region,
                                          target: "AmazonSSM.StartSession", body: ["Target": instanceId])
            return Session(sessionId: r["SessionId"] as? String ?? "", streamUrl: r["StreamUrl"] as? String ?? "",
                           tokenValue: r["TokenValue"] as? String ?? "")
        } catch let e as AWSError where e.code == "TargetNotConnected" {
            throw SsmError.notConnected(instanceId)
        }
    }

    /// An instance (`i-…`) or managed node (`mi-…`) id: it names the script file and goes into it.
    static func isValidTarget(_ id: String) -> Bool {
        id.range(of: #"^m?i-[0-9a-f]{8,17}$"#, options: .regularExpression) != nil
    }

    /// A region name such as eu-west-1 or us-gov-west-1: it becomes part of the endpoint.
    static func isValidRegion(_ region: String) -> Bool {
        region.range(of: #"^[a-z]{2}(-[a-z]+)+-[0-9]$"#, options: .regularExpression) != nil
    }

    /// Shell script that removes itself and runs Atlas as the session's terminal client.
    /// The session token stays in `sessionFile` (0600, deleted once read), never in the script or `ps`.
    static func commandScript(executable: String, sessionFile: String, region: String, instanceId: String) throws -> String {
        guard isValidTarget(instanceId) else { throw SsmError.invalidTarget(instanceId) }
        guard isValidRegion(region) else { throw SsmError.invalidTarget(region) }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/bash
        rm -f "$0"
        clear
        echo \(quote("Atlas — SSM session to \(instanceId) (\(region)). Type exit to close."))
        exec \(quote(executable)) \(SsmShell.flag) \(quote(sessionFile))

        """
    }

    /// Writes, in a new private folder inside `parent`, the session file (0600) and the script Terminal runs (0700).
    static func writeLaunchFiles(session: Session, executable: String, region: String, instanceId: String,
                                 in parent: URL) throws -> URL {
        let dir = parent.appendingPathComponent("atlas-ssm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sessionFile = dir.appendingPathComponent("session.json")
        let json = try JSONSerialization.data(withJSONObject: ["StreamUrl": session.streamUrl, "TokenValue": session.tokenValue])
        guard FileManager.default.createFile(atPath: sessionFile.path, contents: json, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }

        let script = try commandScript(executable: executable, sessionFile: sessionFile.path, region: region, instanceId: instanceId)
        let file = dir.appendingPathComponent("\(instanceId).command")
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    /// Starts the session and opens it in Terminal.app.
    func connect(instanceId: String) async throws {
        guard let executable = Bundle.main.executablePath else { throw SsmError.invalidTarget(instanceId) }
        let session = try await startSession(instanceId: instanceId)
        let file = try Self.writeLaunchFiles(session: session, executable: executable, region: client.region,
                                             instanceId: instanceId, in: FileManager.default.temporaryDirectory)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: .init())
    }
}
