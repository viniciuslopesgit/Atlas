import CryptoKit
import Foundation

/// The Session Manager data channel: the binary messages AWS's session-manager-plugin exchanges with the
/// SSM Agent over the StartSession WebSocket. Implemented here so Atlas needs no plugin installed.
enum SsmProtocol {
    enum PayloadType: UInt32 {
        case none = 0, output = 1, error = 2, size = 3, parameter = 4
        case handshakeRequest = 5, handshakeResponse = 6, handshakeComplete = 7
        case encChallengeRequest = 8, encChallengeResponse = 9, flag = 10, stdErr = 11, exitCode = 12
    }

    enum MessageType {
        static let input = "input_stream_data"
        static let output = "output_stream_data"
        static let acknowledge = "acknowledge"
        static let channelClosed = "channel_closed"
    }

    struct Message: Equatable {
        var type: String
        var schemaVersion: UInt32 = 1
        var createdDate: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
        var sequenceNumber: Int64 = 0
        var flags: UInt64 = 0
        var messageId = UUID()
        var payloadType: UInt32 = PayloadType.none.rawValue
        var payload = Data()
    }

    enum DecodeError: Error, Equatable {
        case tooShort, badHeader, badLength, badDigest
    }

    /// Bytes before the payload length: length(4) type(32) schema(4) date(8) sequence(8) flags(8) id(16) digest(32) payloadType(4).
    static let headerLength: UInt32 = 116
    /// Larger payloads are refused: the agent sends at most a few KB per message.
    static let maxPayload = 1 << 20

    static func encode(_ m: Message) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        u32(headerLength)
        var type = Array(m.type.utf8.prefix(32))
        type += Array(repeating: UInt8(ascii: " "), count: 32 - type.count)
        d.append(contentsOf: type)
        u32(m.schemaVersion)
        u64(m.createdDate)
        u64(UInt64(bitPattern: m.sequenceNumber))
        u64(m.flags)
        // The plugin writes the UUID's least significant half first.
        let id = withUnsafeBytes(of: m.messageId.uuid) { Array($0) }
        d.append(contentsOf: id[8..<16])
        d.append(contentsOf: id[0..<8])
        d.append(contentsOf: SHA256.hash(data: m.payload))
        u32(m.payloadType)
        u32(UInt32(m.payload.count))
        d.append(m.payload)
        return d
    }

    static func decode(_ data: Data) throws -> Message {
        let b = [UInt8](data)
        guard b.count >= Int(headerLength) + 4 else { throw DecodeError.tooShort }
        func u32(_ o: Int) -> UInt32 { b[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func u64(_ o: Int) -> UInt64 { b[o..<o + 8].reduce(0) { $0 << 8 | UInt64($1) } }
        let header = Int(u32(0))
        guard header >= Int(headerLength), b.count >= header + 4 else { throw DecodeError.badHeader }
        let length = Int(u32(header))
        guard length <= maxPayload, b.count == header + 4 + length else { throw DecodeError.badLength }
        let payload = Data(b[(header + 4)...])
        guard Data(SHA256.hash(data: payload)) == Data(b[80..<112]) else { throw DecodeError.badDigest }
        let type = String(decoding: b[4..<36], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        let id = Array(b[72..<80]) + Array(b[64..<72])
        let uuid = UUID(uuid: (id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7],
                               id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15]))
        return Message(type: type, schemaVersion: u32(36), createdDate: u64(40), sequenceNumber: Int64(bitPattern: u64(48)),
                       flags: u64(56), messageId: uuid, payloadType: u32(112), payload: payload)
    }

    /// First frame on the WebSocket: authenticates the channel with the StartSession token.
    static func openDataChannel(token: String, clientId: UUID = UUID()) -> String {
        let o: [String: String] = ["MessageSchemaVersion": "1.0", "RequestId": UUID().uuidString.lowercased(),
                                   "TokenValue": token, "ClientId": clientId.uuidString.lowercased(),
                                   "ClientVersion": Session.clientVersion]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    /// One interactive shell session: orders the agent's output, acknowledges it, answers the handshake and
    /// frames keystrokes and terminal sizes. No I/O of its own, so it is tested without a network.
    final class Session {
        static let clientVersion = "1.2.0.0"

        enum Event: Equatable {
            /// Bytes to send on the WebSocket.
            case send(Data)
            /// Bytes for the terminal.
            case output(Data)
            /// The session ended, with the agent's or Atlas's reason.
            case closed(String)
        }

        private var nextOutgoing: Int64 = 0
        private var expected: Int64 = 0
        private var pending: [Int64: Message] = [:]
        private(set) var handshakeDone = false
        private var size: (cols: Int, rows: Int)?

        init() {}

        /// Keystrokes from the terminal.
        func input(_ bytes: Data) -> Data { frame(.output, bytes) }

        /// The terminal's size; sent now and again whenever it changes.
        func resize(cols: Int, rows: Int) -> Data? {
            guard cols > 0, rows > 0 else { return nil }
            size = (cols, rows)
            return frame(.size, json(["cols": cols, "rows": rows]))
        }

        /// Handles one WebSocket frame from the agent.
        func receive(_ data: Data) -> [Event] {
            guard let m = try? SsmProtocol.decode(data) else { return [] }
            switch m.type {
            case MessageType.output:
                var events = [Event.send(acknowledge(m))]
                guard m.sequenceNumber >= expected else { return events } // a duplicate, already shown
                pending[m.sequenceNumber] = m
                while let next = pending.removeValue(forKey: expected) {
                    expected += 1
                    events += handle(next)
                }
                return events
            case MessageType.channelClosed:
                let o = (try? JSONSerialization.jsonObject(with: m.payload)) as? [String: Any]
                return [.closed((o?["Output"] as? String) ?? "")]
            default:
                return [] // acknowledgements of our input, start/pause publication
            }
        }

        private func handle(_ m: Message) -> [Event] {
            switch PayloadType(rawValue: m.payloadType) {
            case .output, .stdErr, .error:
                return [.output(m.payload)]
            case .handshakeRequest:
                return handshake(m.payload)
            case .handshakeComplete:
                handshakeDone = true
                let o = (try? JSONSerialization.jsonObject(with: m.payload)) as? [String: Any]
                var events: [Event] = []
                if let text = o?["CustomerMessage"] as? String, !text.isEmpty { events.append(.output(Data((text + "\r\n").utf8))) }
                if let size, let d = resize(cols: size.cols, rows: size.rows) { events.append(.send(d)) }
                return events
            default:
                return []
            }
        }

        /// Accepts the shell session; KMS-encrypted sessions need keys the terminal does not have, so they are refused.
        private func handshake(_ payload: Data) -> [Event] {
            let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let actions = o?["RequestedClientActions"] as? [[String: Any]] ?? []
            var processed: [[String: Any]] = []
            var refused: String?
            for action in actions {
                let type = action["ActionType"] as? String ?? ""
                switch type {
                case "SessionType":
                    processed.append(["ActionType": type, "ActionStatus": 1])
                default:
                    refused = type == "KMSEncryption"
                        ? "This instance's Session Manager preferences require KMS encryption, which Atlas does not support yet."
                        : "Atlas does not support the session action \(type)."
                    processed.append(["ActionType": type, "ActionStatus": 3, "Error": refused ?? ""])
                }
            }
            let response = json(["ClientVersion": Self.clientVersion, "ProcessedClientActions": processed,
                                 "Errors": refused.map { [$0] } ?? []])
            var events = [Event.send(frame(.handshakeResponse, response))]
            if let refused { events.append(.closed(refused)) }
            return events
        }

        private func acknowledge(_ m: Message) -> Data {
            let payload = json(["AcknowledgedMessageType": m.type,
                                "AcknowledgedMessageId": m.messageId.uuidString.lowercased(),
                                "AcknowledgedMessageSequenceNumber": m.sequenceNumber,
                                "IsSequentialMessage": true])
            return encode(Message(type: MessageType.acknowledge, flags: 3, payload: payload))
        }

        private func frame(_ type: PayloadType, _ payload: Data) -> Data {
            defer { nextOutgoing += 1 }
            return encode(Message(type: MessageType.input, sequenceNumber: nextOutgoing, payloadType: type.rawValue, payload: payload))
        }

        private func json(_ o: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        }
    }
}
