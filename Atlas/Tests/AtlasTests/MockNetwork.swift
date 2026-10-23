import Foundation
@testable import Atlas

/// Intercepts every request of a session; tests answer them without touching the network.
final class MockURLProtocol: URLProtocol {
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        init(status: Int = 200, headers: [String: String] = [:], body: String = "") {
            self.status = status
            self.headers = headers
            self.body = Data(body.utf8)
        }
    }

    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> Response)?
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        Self.requests.append((request, body))
        let r = Self.handler?(request, body) ?? Response(status: 500, body: "no handler")
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    /// A client whose session only talks to this mock.
    static func client(region: String = "us-east-1", _ handler: @escaping (URLRequest, Data) -> Response) -> AWSClient {
        self.handler = handler
        requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return AWSClient(credentials: AWSCredentials(accessKeyId: "AKIDTEST", secretAccessKey: "secret"),
                         region: region, session: URLSession(configuration: config))
    }
}

extension Data {
    var string: String { String(decoding: self, as: UTF8.self) }
}

func formParams(_ body: Data) -> [String: String] {
    var map: [String: String] = [:]
    for pair in body.string.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        map[kv[0]] = kv.count > 1 ? kv[1] : ""
    }
    return map
}
