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
    @Test func commandScriptHandsOffToPluginWithoutKeys() throws {
        let script = try SsmService.commandScript(plugin: "/opt/homebrew/bin/session-manager-plugin",
                                                  session: .init(sessionId: "s-1", streamUrl: "wss://x", tokenValue: "it's"),
                                                  region: "us-east-1", instanceId: "i-0123456789abcdef0")
        #expect(script.hasPrefix("#!/bin/bash\nrm -f \"$0\""))
        #expect(script.contains("exec '/opt/homebrew/bin/session-manager-plugin'"))
        #expect(script.contains(#"'{"Target":"i-0123456789abcdef0"}'"#))
        #expect(script.contains("https://ssm.us-east-1.amazonaws.com"))
        #expect(script.contains(#"it'\''s"#), "single quotes must be escaped")
        #expect(!script.contains("AKID") && !script.contains("AWS_SECRET"))
    }
}
