import Darwin
import Foundation

/// `Atlas --ssm-session <file>`: the interactive SSM shell that Terminal.app runs, in place of AWS's
/// session-manager-plugin. Reads the StartSession result from a private file (and deletes it), opens the
/// WebSocket and connects it to the terminal in raw mode.
enum SsmShell {
    static let flag = "--ssm-session"

    enum ShellError: LocalizedError, Equatable {
        case unreadable
        case untrustedStream(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "The SSM session file could not be read. Connect again from Atlas."
            case .untrustedStream(let url): "Refusing to connect to \(url): not an AWS Session Manager endpoint."
            }
        }
    }

    /// The session file's stream URL must be an AWS Session Manager WebSocket.
    static func streamURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), url.scheme == "wss", let host = url.host?.lowercased(),
              host.hasPrefix("ssmmessages."), host.hasSuffix(".amazonaws.com") || host.hasSuffix(".amazonaws.com.cn"),
              url.user == nil, url.password == nil
        else { throw ShellError.untrustedStream(string) }
        return url
    }

    /// Reads and deletes the session file written by `SsmService.connect`.
    static func readSession(_ path: String) throws -> (url: URL, token: String) {
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let data = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let stream = o["StreamUrl"], let token = o["TokenValue"]
        else { throw ShellError.unreadable }
        return (try streamURL(stream), token)
    }

    /// Runs the session until it closes; returns the process exit code.
    static func run(sessionFile: String) -> Int32 {
        let session: (url: URL, token: String)
        do { session = try readSession(sessionFile) } catch {
            FileHandle.standardError.write(Data("✗ \(error.localizedDescription)\n".utf8))
            return 1
        }
        let link = Link(url: session.url)
        return link.run(token: session.token)
    }

    /// The WebSocket, the terminal and the protocol state, serialised on one queue.
    private final class Link: @unchecked Sendable {
        private let queue = DispatchQueue(label: "atlas.ssm")
        private let task: URLSessionWebSocketTask
        private let core = SsmProtocol.Session()
        private let done = DispatchSemaphore(value: 0)
        private var exitCode: Int32 = 0
        private var finished = false
        private var original = termios()
        private var lastSize = (cols: 0, rows: 0)
        private var timers: [DispatchSourceProtocol] = []

        init(url: URL) { task = URLSession.shared.webSocketTask(with: url) }

        func run(token: String) -> Int32 {
            task.resume()
            task.send(.string(SsmProtocol.openDataChannel(token: token))) { [weak self] error in
                if let error { self?.finish("Could not open the session: \(error.localizedDescription)", code: 1) }
            }
            receive()
            rawMode()
            readKeys()
            watchSize()
            done.wait()
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            return exitCode
        }

        private func rawMode() {
            tcgetattr(STDIN_FILENO, &original)
            var raw = original
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }

        private func receive() {
            task.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(.data(let d)): queue.async { self.apply(self.core.receive(d)) }
                case .success(.string(let s)): queue.async { self.apply(self.core.receive(Data(s.utf8))) }
                case .success: break
                case .failure(let e): finish("Connection closed: \(e.localizedDescription)", code: 1); return
                }
                receive()
            }
        }

        private func apply(_ events: [SsmProtocol.Session.Event]) {
            for event in events {
                switch event {
                case .send(let d): task.send(.data(d)) { _ in }
                case .output(let d): FileHandle.standardOutput.write(d)
                case .closed(let reason): finish(reason, code: 0)
                }
            }
        }

        private func readKeys() {
            Thread.detachNewThread { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let n = read(STDIN_FILENO, &buffer, buffer.count)
                    guard n > 0, let self else { self?.finish("", code: 0); return }
                    let bytes = Data(buffer[0..<n])
                    queue.async { self.task.send(.data(self.core.input(bytes))) { _ in } }
                }
            }
        }

        /// Sends the size now and whenever the window changes; pings keep idle sessions open.
        private func watchSize() {
            let check = DispatchSource.makeTimerSource(queue: queue)
            check.schedule(deadline: .now(), repeating: .milliseconds(500))
            check.setEventHandler { [weak self] in
                guard let self else { return }
                var ws = winsize()
                guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 else { return }
                let size = (cols: Int(ws.ws_col), rows: Int(ws.ws_row))
                guard size != lastSize, let d = core.resize(cols: size.cols, rows: size.rows) else { return }
                lastSize = size
                task.send(.data(d)) { _ in }
            }
            let ping = DispatchSource.makeTimerSource(queue: queue)
            ping.schedule(deadline: .now() + 60, repeating: 60)
            ping.setEventHandler { [weak self] in self?.task.sendPing { _ in } }
            timers = [check, ping]
            timers.forEach { $0.resume() }
        }

        private func finish(_ reason: String, code: Int32) {
            queue.async { [self] in
                guard !finished else { return }
                finished = true
                exitCode = code
                timers.forEach { $0.cancel() }
                task.cancel(with: .normalClosure, reason: nil)
                if !reason.isEmpty { FileHandle.standardOutput.write(Data("\r\n\(reason)\r\n".utf8)) }
                done.signal()
            }
        }
    }
}
