import AppKit
import Foundation

/// Opens an interactive SSM shell in Terminal.app: StartSession through our client, then the
/// session-manager-plugin takes over the I/O. No AWS CLI and no access keys on any command line.
struct SsmService {
    let client: AWSClient

    struct Session: Equatable {
        let sessionId: String
        let streamUrl: String
        let tokenValue: String
    }

    enum SsmError: LocalizedError {
        case pluginMissing
        case notConnected(String)
        case invalidTarget(String)

        var errorDescription: String? {
            switch self {
            case .pluginMissing:
                "The Session Manager plugin is not installed. Install it with: brew install --cask session-manager-plugin"
            case .notConnected(let id):
                "Instance \(id) is not connected to SSM. Check that the SSM Agent is running, the instance profile has "
                    + "AmazonSSMManagedInstanceCore, and the instance can reach the SSM endpoints."
            case .invalidTarget(let id):
                "\"\(id)\" is not an EC2 instance or managed node id."
            }
        }
    }

    static let pluginPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/sessionmanagerplugin/bin"]

    /// Path of session-manager-plugin in PATH or a well-known install folder.
    static func findPlugin(fileManager: FileManager = .default) -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (path + pluginPaths)
            .map { "\($0)/session-manager-plugin" }
            .first { fileManager.isExecutableFile(atPath: $0) }
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

    /// Shell script that removes itself and hands the session to the plugin.
    static func commandScript(plugin: String, session: Session, region: String, instanceId: String) throws -> String {
        func json(_ o: [String: String]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
        }
        guard isValidTarget(instanceId) else { throw SsmError.invalidTarget(instanceId) }
        guard isValidRegion(region) else { throw SsmError.invalidTarget(region) }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let response = try json(["SessionId": session.sessionId, "StreamUrl": session.streamUrl,
                                 "TokenValue": session.tokenValue])
        let request = try json(["Target": instanceId])
        return """
        #!/bin/bash
        rm -f "$0"
        clear
        echo \(quote("Atlas — SSM session to \(instanceId) (\(region)). Type exit to close."))
        exec \(quote(plugin)) \(quote(response)) \(quote(region)) StartSession '' \(quote(request)) \
        \(quote("https://ssm.\(region).amazonaws.com"))

        """
    }

    /// Starts the session and opens it in Terminal.app.
    func connect(instanceId: String) async throws {
        guard let plugin = Self.findPlugin() else { throw SsmError.pluginMissing }
        let session = try await startSession(instanceId: instanceId)
        let script = try Self.commandScript(plugin: plugin, session: session, region: client.region, instanceId: instanceId)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-ssm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("\(instanceId).command")
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)

        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: .init())
    }
}
