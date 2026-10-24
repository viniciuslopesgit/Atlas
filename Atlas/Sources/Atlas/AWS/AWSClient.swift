import Foundation

struct AWSError: LocalizedError {
    let code: String
    let message: String
    let status: Int

    var errorDescription: String? {
        message.isEmpty ? "\(code) (HTTP \(status))" : "\(code): \(message)"
    }
}

/// AWS services spoken over the Query protocol (form-encoded POST, XML response).
enum QueryService {
    case ec2, sts, iam, cloudWatch, autoScaling, elbv2, rds, elastiCache, sns

    var version: String {
        switch self {
        case .ec2: "2016-11-15"
        case .sts: "2011-06-15"
        case .iam: "2010-05-08"
        case .cloudWatch: "2010-08-01"
        case .autoScaling: "2011-01-01"
        case .elbv2: "2015-12-01"
        case .rds: "2014-10-31"
        case .elastiCache: "2015-02-02"
        case .sns: "2010-03-31"
        }
    }

    var signingName: String {
        switch self {
        case .ec2: "ec2"
        case .sts: "sts"
        case .iam: "iam"
        case .cloudWatch: "monitoring"
        case .autoScaling: "autoscaling"
        case .elbv2: "elasticloadbalancing"
        case .rds: "rds"
        case .elastiCache: "elasticache"
        case .sns: "sns"
        }
    }

    /// IAM is a global service that always signs against us-east-1.
    func host(region: String) -> String {
        switch self {
        case .iam: "iam.amazonaws.com"
        default: "\(signingName).\(region).amazonaws.com"
        }
    }

    func signingRegion(_ region: String) -> String { self == .iam ? "us-east-1" : region }
}

/// Lightweight AWS client: SigV4 + Query/JSON/REST-JSON/S3 transports.
final class AWSClient: @unchecked Sendable {
    let credentials: AWSCredentials
    let region: String
    let signer: SigV4Signer
    let session: URLSession

    /// Cache of bucket → region discovered through ListBuckets or redirects.
    private let bucketRegions = BucketRegionCache()

    /// AWS traffic never goes through the shared session: no response cache on disk (S3 listings, policies)
    /// and no cookies.
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    init(credentials: AWSCredentials, region: String, session: URLSession = AWSClient.defaultSession) {
        self.credentials = credentials
        self.region = region
        self.signer = SigV4Signer(credentials: credentials)
        self.session = session
    }

    // MARK: Transport

    /// Only HTTPS to an AWS endpoint: a region or bucket name such as `evil.example#` must never take a
    /// signed request (and what it carries) to another host.
    static func isAWSEndpoint(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
        else { return false }
        return host.hasSuffix(".amazonaws.com") || host.hasSuffix(".amazonaws.com.cn")
    }

    static func checked(_ request: URLRequest) throws -> URLRequest {
        guard isAWSEndpoint(request.url) else {
            throw AWSError(code: "UntrustedEndpoint", message: "Refusing to send a request to \(request.url?.host ?? "an invalid URL"): not an AWS endpoint. Check the region and names.", status: 0)
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: Self.checked(request))
        guard let http = response as? HTTPURLResponse else {
            throw AWSError(code: "InvalidResponse", message: "Non-HTTP response", status: 0)
        }
        return (data, http)
    }

    static let maxErrorBody = 300

    static func error(from data: Data, status: Int) -> AWSError {
        if let xml = XNode.parse(data) {
            let code = xml.find("Code")?.text ?? "HTTP\(status)"
            let message = xml.find("Message")?.text ?? ""
            return AWSError(code: code, message: message, status: status)
        }
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let rawType = (json["__type"] as? String) ?? (json["code"] as? String) ?? (json["Code"] as? String) ?? "HTTP\(status)"
            let code = rawType.split(separator: "#").last.map(String.init) ?? rawType
            let message = (json["message"] as? String) ?? (json["Message"] as? String) ?? ""
            return AWSError(code: code, message: message, status: status)
        }
        // Not AWS's format (a proxy's or captive portal's page): show its start, never megabytes of HTML.
        let text = String(decoding: data.prefix(maxErrorBody), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return AWSError(code: "HTTP\(status)", message: data.count > maxErrorBody ? text + "…" : text, status: status)
    }

    // MARK: Query protocol

    func query(_ service: QueryService, _ action: String, _ params: [String: String] = [:]) async throws -> XNode {
        var items = [("Action", action), ("Version", service.version)]
        items += params.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let body = items.map { "\(AWSEncoding.uri($0.0))=\(AWSEncoding.uri($0.1))" }.joined(separator: "&")
        let bodyData = Data(body.utf8)

        let req = signer.request(
            method: "POST",
            host: service.host(region: region),
            encodedPath: "/",
            headers: ["content-type": "application/x-www-form-urlencoded; charset=utf-8"],
            body: bodyData,
            service: service.signingName,
            region: service.signingRegion(region))

        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
        guard let xml = XNode.parse(data) else {
            throw AWSError(code: "InvalidXML", message: "Could not parse \(action) response", status: http.statusCode)
        }
        return xml
    }

    /// Runs a paginated Query call, following `nextToken`/`NextToken`/`Marker`.
    func queryPaged(_ service: QueryService, _ action: String, _ params: [String: String] = [:],
                    tokenParam: String, tokenPath: (XNode) -> String?,
                    page: (XNode) -> Void) async throws {
        var token: String?
        repeat {
            var p = params
            if let token { p[tokenParam] = token }
            let xml = try await query(service, action, p)
            page(xml)
            token = tokenPath(xml).flatMap { $0.isEmpty ? nil : $0 }
        } while token != nil
    }

    // MARK: JSON protocol (1.1 by default; DynamoDB and SQS speak 1.0)

    func json(host: String, signingName: String, signingRegion: String, target: String,
              body: [String: Any], version: String = "1.1") async throws -> [String: Any] {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let req = signer.request(
            method: "POST", host: host, encodedPath: "/",
            headers: ["content-type": "application/x-amz-json-\(version)", "x-amz-target": target],
            body: bodyData, service: signingName, region: signingRegion)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: REST-JSON protocol (GuardDuty)

    func restJSON(method: String, host: String, signingName: String, path: String,
                  query: [(String, String)] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        var headers: [String: String] = [:]
        if bodyData != nil { headers["content-type"] = "application/json" }
        let req = signer.request(
            method: method, host: host, encodedPath: path, query: query, headers: headers,
            body: bodyData, service: signingName, region: region)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: REST-XML protocol (Route 53)

    func restXML(method: String = "GET", host: String, signingName: String, signingRegion: String,
                 path: String, query: [(String, String)] = []) async throws -> XNode {
        let req = signer.request(method: method, host: host, encodedPath: path, query: query,
                                 service: signingName, region: signingRegion)
        let (data, http) = try await send(req)
        guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
        guard let xml = XNode.parse(data) else {
            throw AWSError(code: "InvalidXML", message: "Could not parse \(path) response", status: http.statusCode)
        }
        return xml
    }

    // MARK: S3 (REST-XML)

    func rememberBucketRegion(_ bucket: String, _ region: String) {
        bucketRegions.set(bucket, region)
    }

    func bucketRegion(_ bucket: String) -> String { bucketRegions.get(bucket) ?? region }

    /// Builds a signed S3 request. Uses virtual-hosted style unless the bucket name contains dots.
    func s3Request(method: String, bucket: String?, key: String? = nil, query: [(String, String)] = [],
                   headers: [String: String] = [:], body: Data? = nil, unsignedPayload: Bool = false,
                   region overrideRegion: String? = nil) -> URLRequest {
        let r = overrideRegion ?? bucket.map(bucketRegion) ?? region
        let regionalHost = "s3.\(r).amazonaws.com"
        let encodedKey = key.map { "/" + AWSEncoding.uri($0, keepSlash: true) } ?? ""

        let host: String
        let path: String
        if let bucket, !bucket.contains(".") {
            host = "\(bucket).\(regionalHost)"
            path = encodedKey.isEmpty ? "/" : encodedKey
        } else if let bucket {
            host = regionalHost
            path = "/\(AWSEncoding.uri(bucket))\(encodedKey)"
        } else {
            host = regionalHost
            path = "/"
        }

        return signer.request(
            method: method, host: host, encodedPath: path, query: query, headers: headers, body: body,
            payloadHash: unsignedPayload ? AWSEncoding.unsignedPayload : nil,
            service: "s3", region: r)
    }

    /// Sends an S3 request, transparently retrying once in the bucket's real region on a redirect.
    func s3(method: String, bucket: String?, key: String? = nil, query: [(String, String)] = [],
            headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = s3Request(method: method, bucket: bucket, key: key, query: query, headers: headers, body: body)
        var (data, http) = try await send(req)

        if let bucket, !(200..<300).contains(http.statusCode),
           let real = Self.redirectRegion(http: http, data: data), real != bucketRegion(bucket) {
            rememberBucketRegion(bucket, real)
            req = s3Request(method: method, bucket: bucket, key: key, query: query, headers: headers, body: body)
            (data, http) = try await send(req)
        }

        guard (200..<300).contains(http.statusCode) else { throw Self.error(from: data, status: http.statusCode) }
        return (data, http)
    }

    /// Discovers a bucket's region with a HEAD request (S3 always returns `x-amz-bucket-region`).
    func resolveBucketRegion(_ bucket: String) async {
        guard bucketRegions.get(bucket) == nil else { return }
        let req = s3Request(method: "HEAD", bucket: bucket, region: region)
        if let (_, http) = try? await send(req),
           let r = http.value(forHTTPHeaderField: "x-amz-bucket-region"), !r.isEmpty {
            rememberBucketRegion(bucket, r)
        }
    }

    private static func redirectRegion(http: HTTPURLResponse, data: Data) -> String? {
        guard [301, 307, 400].contains(http.statusCode) else { return nil }
        if let r = http.value(forHTTPHeaderField: "x-amz-bucket-region"), !r.isEmpty { return r }
        if let xml = XNode.parse(data), let r = xml.find("Region")?.text, !r.isEmpty { return r }
        return nil
    }
}

private final class BucketRegionCache: @unchecked Sendable {
    private var map: [String: String] = [:]
    private let lock = NSLock()

    func get(_ bucket: String) -> String? { lock.withLock { map[bucket] } }
    func set(_ bucket: String, _ region: String) { lock.withLock { map[bucket] = region } }
}

// MARK: - JSON helpers

extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func array(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func strings(_ key: String) -> [String] { self[key] as? [String] ?? [] }
    func number(_ key: String) -> Double {
        if let d = self[key] as? Double { return d }
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let s = self[key] as? String { return Double(s) ?? 0 }
        return 0
    }
}
