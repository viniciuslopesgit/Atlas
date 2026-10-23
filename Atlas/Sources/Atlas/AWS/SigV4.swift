import Foundation
import CryptoKit

struct AWSCredentials: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
}

enum AWSEncoding {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// RFC 3986 percent-encoding as required by SigV4.
    static func uri(_ s: String, keepSlash: Bool = false) -> String {
        var allowed = unreserved
        if keepSlash { allowed.insert("/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func md5Base64(_ data: Data) -> String {
        Data(Insecure.MD5.hash(data: data)).base64EncodedString()
    }

    static let emptyHash = sha256Hex(Data())
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
}

/// AWS Signature Version 4 request builder.
struct SigV4Signer: Sendable {
    let credentials: AWSCredentials

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
    private static let amzDateFormatter = formatter("yyyyMMdd'T'HHmmss'Z'")
    private static let dateStampFormatter = formatter("yyyyMMdd")

    /// Builds a fully signed request.
    /// - Parameters:
    ///   - encodedPath: path already percent-encoded (e.g. "/my%20key").
    ///   - query: raw (unencoded) query items.
    func request(
        method: String,
        host: String,
        encodedPath: String,
        query: [(String, String)] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        payloadHash: String? = nil,
        service: String,
        region: String,
        date: Date = Date(),
        includeContentHashHeader: Bool = true
    ) -> URLRequest {
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = Self.dateStampFormatter.string(from: date)
        let hash = payloadHash ?? AWSEncoding.sha256Hex(body ?? Data())

        let encodedQuery: [(String, String)] = query.map { (AWSEncoding.uri($0.0), AWSEncoding.uri($0.1)) }
        let sortedQuery = encodedQuery.sorted { (a: (String, String), b: (String, String)) -> Bool in
            a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        let canonicalQuery = sortedQuery.map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        var allHeaders: [String: String] = [:]
        for (k, v) in headers { allHeaders[k.lowercased()] = v.trimmingCharacters(in: .whitespaces) }
        allHeaders["host"] = host
        allHeaders["x-amz-date"] = amzDate
        if includeContentHashHeader { allHeaders["x-amz-content-sha256"] = hash }

        let sortedKeys = allHeaders.keys.sorted()
        let canonicalHeaders = sortedKeys.map { "\($0):\(allHeaders[$0]!)\n" }.joined()
        let signedHeaders = sortedKeys.joined(separator: ";")
        let path = encodedPath.isEmpty ? "/" : encodedPath

        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, hash]
            .joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope,
            AWSEncoding.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let kDate = hmac(Data("AWS4\(credentials.secretAccessKey)".utf8), dateStamp)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        let kSigning = hmac(kService, "aws4_request")
        let signature = hmac(kSigning, stringToSign).map { String(format: "%02x", $0) }.joined()

        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var urlString = "https://\(host)\(path)"
        if !canonicalQuery.isEmpty { urlString += "?\(canonicalQuery)" }

        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 60
        for (k, v) in allHeaders where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        return req
    }

    private func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }
}
