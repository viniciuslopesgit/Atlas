import Foundation
import Testing
@testable import Atlas

extension ServiceTests {
    @Test func ssmStartSessionUsesJsonTarget() async throws {
        let client = MockURLProtocol.client(region: "eu-west-1") { _, _ in
            .init(body: #"{"SessionId":"s-1","StreamUrl":"wss://x","TokenValue":"tok"}"#)
        }
        let s = try await SsmService(client: client).startSession(instanceId: "i-123")
        #expect(s == .init(sessionId: "s-1", streamUrl: "wss://x", tokenValue: "tok"))
        let req = try #require(MockURLProtocol.requests.first)
        #expect(req.request.url?.host == "ssm.eu-west-1.amazonaws.com")
        #expect(req.request.value(forHTTPHeaderField: "x-amz-target") == "AmazonSSM.StartSession")
        #expect(req.body.string.contains("i-123"))
    }

    @Test func ssmNotConnectedHasActionableMessage() async {
        let client = MockURLProtocol.client { _, _ in
            .init(status: 400, body: #"{"__type":"TargetNotConnected","message":"i-9 is not connected."}"#)
        }
        await #expect(throws: SsmService.SsmError.self) { try await SsmService(client: client).startSession(instanceId: "i-9") }
    }
}

struct SsmScriptTests {
    @Test func commandScriptRunsAtlasWithTheSessionFileOnly() throws {
        let script = try SsmService.commandScript(executable: "/Applications/Atlas.app/Contents/MacOS/Atlas",
                                                  sessionFile: "/tmp/atlas-ssm-1/session.json",
                                                  region: "us-east-1", instanceId: "i-0123456789abcdef0")
        #expect(script.hasPrefix("#!/bin/bash\nrm -f \"$0\""))
        #expect(script.contains("exec '/Applications/Atlas.app/Contents/MacOS/Atlas' --ssm-session '/tmp/atlas-ssm-1/session.json'"))
        #expect(!script.contains("session-manager-plugin"))
        #expect(!script.contains("AKID") && !script.contains("AWS_SECRET"))
    }

    @Test func launchFilesKeepTheTokenPrivateAndOutOfTheScript() throws {
        let parent = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let script = try SsmService.writeLaunchFiles(
            session: .init(sessionId: "s-1", streamUrl: "wss://ssmmessages.us-east-1.amazonaws.com/v1/data-channel/s-1", tokenValue: "secret-token"),
            executable: "/Applications/Atlas.app/Contents/MacOS/Atlas", region: "us-east-1",
            instanceId: "i-0123456789abcdef0", in: parent)
        let dir = script.deletingLastPathComponent()
        let session = dir.appendingPathComponent("session.json")
        func mode(_ url: URL) throws -> Int { try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1 }
        #expect(try mode(dir) == 0o700 && mode(script) == 0o700 && mode(session) == 0o600)
        #expect(try !String(contentsOf: script, encoding: .utf8).contains("secret-token"))
        #expect(try SsmShell.readSession(session.path).token == "secret-token")
    }

    @Test func sessionFileIsReadOnceAndDeleted() throws {
        let dir = TestTemp.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.json")
        try Data(#"{"StreamUrl":"wss://ssmmessages.eu-west-1.amazonaws.com/v1/data-channel/s-1?role=publish_subscribe","TokenValue":"tok"}"#.utf8).write(to: file)
        let s = try SsmShell.readSession(file.path)
        #expect(s.token == "tok" && s.url.host == "ssmmessages.eu-west-1.amazonaws.com")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(throws: SsmShell.ShellError.unreadable) { try SsmShell.readSession(file.path) }
    }
}

/// The Session Manager data channel, against messages built the way the SSM Agent builds them.
struct SsmProtocolTests {
    typealias P = SsmProtocol

    private func agent(_ seq: Int64, _ type: P.PayloadType, _ payload: String, kind: String = P.MessageType.output) -> Data {
        P.encode(.init(type: kind, sequenceNumber: seq, payloadType: type.rawValue, payload: Data(payload.utf8)))
    }

    private func sent(_ events: [P.Session.Event]) -> [P.Message] {
        events.compactMap { if case .send(let d) = $0 { try? P.decode(d) } else { nil } }
    }

    private func output(_ events: [P.Session.Event]) -> String {
        events.map { if case .output(let d) = $0 { String(decoding: d, as: UTF8.self) } else { "" } }.joined()
    }

    @Test func messageLayoutMatchesThePlugin() throws {
        let id = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let d = P.encode(.init(type: "input_stream_data", createdDate: 1, sequenceNumber: 7, flags: 0, messageId: id,
                               payloadType: 1, payload: Data("ls\r".utf8)))
        let b = [UInt8](d)
        #expect(b.count == 120 + 3)
        #expect(Array(b[0..<4]) == [0, 0, 0, 116], "header length")
        #expect(String(decoding: b[4..<36], as: UTF8.self) == "input_stream_data" + String(repeating: " ", count: 15))
        #expect(Array(b[48..<56]) == [0, 0, 0, 0, 0, 0, 0, 7], "sequence number, big-endian")
        #expect(Array(b[64..<80]) == [0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77],
                "least significant half of the UUID first")
        #expect(Array(b[116..<120]) == [0, 0, 0, 3], "payload length")
        let back = try P.decode(d)
        #expect(back.messageId == id && back.sequenceNumber == 7 && back.payload == Data("ls\r".utf8))
    }

    @Test func handshakeIsAcceptedThenTheSizeIsSent() throws {
        let s = P.Session()
        _ = s.resize(cols: 120, rows: 40)
        let request = #"{"AgentVersion":"3.3","RequestedClientActions":[{"ActionType":"SessionType","ActionParameters":{"SessionType":"Standard_Stream"}}]}"#
        let events = s.receive(agent(0, .handshakeRequest, request))
        let msgs = sent(events)
        #expect(msgs[0].type == "acknowledge" && msgs[0].flags == 3)
        let ack = try #require(try JSONSerialization.jsonObject(with: msgs[0].payload) as? [String: Any])
        #expect(ack["AcknowledgedMessageSequenceNumber"] as? Int == 0)
        #expect(msgs[1].type == "input_stream_data" && msgs[1].payloadType == P.PayloadType.handshakeResponse.rawValue)
        let response = try #require(try JSONSerialization.jsonObject(with: msgs[1].payload) as? [String: Any])
        let actions = try #require(response["ProcessedClientActions"] as? [[String: Any]])
        #expect(actions.first?["ActionStatus"] as? Int == 1)

        let complete = s.receive(agent(1, .handshakeComplete, #"{"HandshakeTimeToComplete":1,"CustomerMessage":"Welcome"}"#))
        #expect(s.handshakeDone)
        #expect(output(complete) == "Welcome\r\n")
        let size = try #require(sent(complete).last)
        #expect(size.payloadType == P.PayloadType.size.rawValue)
        #expect(String(decoding: size.payload, as: UTF8.self) == #"{"cols":120,"rows":40}"#)
    }

    @Test func outputIsShownInOrderOnceAndAlwaysAcknowledged() {
        let s = P.Session()
        let late = s.receive(agent(1, .output, "world"))
        #expect(output(late).isEmpty, "waits for message 0")
        #expect(sent(late).count == 1, "but acknowledges it")
        #expect(output(s.receive(agent(0, .output, "hello "))) == "hello world")
        let dup = s.receive(agent(0, .output, "hello "))
        #expect(output(dup).isEmpty && sent(dup).count == 1)
    }

    @Test func keystrokesAreNumberedInputMessages() throws {
        let s = P.Session()
        let a = try P.decode(s.input(Data("l".utf8)))
        let b = try P.decode(s.input(Data("s".utf8)))
        #expect(a.type == "input_stream_data" && a.payloadType == 1)
        #expect((a.sequenceNumber, b.sequenceNumber) == (0, 1))
        #expect(s.resize(cols: 0, rows: 0) == nil)
    }

    @Test func kmsEncryptedSessionsAreRefusedWithAReason() throws {
        let s = P.Session()
        let request = #"{"RequestedClientActions":[{"ActionType":"SessionType"},{"ActionType":"KMSEncryption"}]}"#
        let events = s.receive(agent(0, .handshakeRequest, request))
        #expect(events.contains { if case .closed(let r) = $0 { r.contains("KMS") } else { false } })
        let response = try #require(sent(events).last)
        let o = try #require(try JSONSerialization.jsonObject(with: response.payload) as? [String: Any])
        #expect((o["ProcessedClientActions"] as? [[String: Any]])?.last?["ActionStatus"] as? Int == 3)
    }

    @Test func channelClosedEndsTheSessionWithTheAgentsMessage() {
        let events = P.Session().receive(agent(0, .output, #"{"Output":"Exiting session with sessionId: s-1."}"#,
                                               kind: P.MessageType.channelClosed))
        #expect(events == [.closed("Exiting session with sessionId: s-1.")])
    }

    @Test func openDataChannelCarriesTheToken() throws {
        let o = try #require(try JSONSerialization.jsonObject(with: Data(P.openDataChannel(token: "tok").utf8)) as? [String: String])
        #expect(o["TokenValue"] == "tok" && o["MessageSchemaVersion"] == "1.0" && o["ClientId"] != nil)
    }
}
