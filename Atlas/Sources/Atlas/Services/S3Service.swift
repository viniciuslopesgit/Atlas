import Foundation
import UniformTypeIdentifiers

struct S3Service {
    let client: AWSClient

    func buckets() async throws -> [S3Bucket] {
        var buckets: [S3Bucket] = []
        var token: String?
        repeat {
            var q = [("max-buckets", "1000")]
            if let token { q.append(("continuation-token", token)) }
            let (data, _) = try await client.s3(method: "GET", bucket: nil, query: q)
            guard let xml = XNode.parse(data) else { break }
            for b in xml.list("Buckets", item: "Bucket") {
                let name = b.str("Name")
                let region = b.str("BucketRegion")
                if !region.isEmpty { client.rememberBucketRegion(name, region) }
                buckets.append(S3Bucket(name: name, creationDate: b.date("CreationDate"), region: region))
            }
            token = xml.str("ContinuationToken").isEmpty ? nil : xml.str("ContinuationToken")
        } while token != nil
        return buckets.sorted { $0.name < $1.name }
    }

    /// Lists one "folder" level: common prefixes first, then objects.
    func objects(bucket: String, prefix: String) async throws -> [S3Object] {
        var folders: [S3Object] = []
        var files: [S3Object] = []
        try await listObjects(bucket: bucket, prefix: prefix, delimiter: "/") { xml in
            for cp in xml.all("CommonPrefixes") {
                folders.append(S3Object(key: cp.str("Prefix"), isFolder: true))
            }
            files += Self.parseContents(xml, excluding: prefix)
        }
        return folders.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            + files.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func allObjects(bucket: String, prefix: String) async throws -> [S3Object] {
        var results: [S3Object] = []
        try await listObjects(bucket: bucket, prefix: prefix, delimiter: nil) { xml in
            results += Self.parseContents(xml, excluding: nil)
        }
        return results
    }

    private static func parseContents(_ xml: XNode, excluding prefix: String?) -> [S3Object] {
        xml.all("Contents").compactMap { o in
            let key = o.str("Key")
            if key == prefix { return nil }
            return S3Object(key: key, sizeBytes: Int64(o.str("Size")) ?? 0, lastModified: o.date("LastModified"),
                            storageClass: o.str("StorageClass").isEmpty ? "STANDARD" : o.str("StorageClass"),
                            eTag: o.str("ETag").trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
    }

    private func listObjects(bucket: String, prefix: String, delimiter: String?,
                             page: (XNode) -> Void) async throws {
        var token: String?
        repeat {
            var q = [("list-type", "2"), ("prefix", prefix), ("max-keys", "1000")]
            if let delimiter { q.append(("delimiter", delimiter)) }
            if let token { q.append(("continuation-token", token)) }
            let (data, _) = try await client.s3(method: "GET", bucket: bucket, query: q)
            guard let xml = XNode.parse(data) else { return }
            page(xml)
            token = xml.bool("IsTruncated") ? xml.str("NextContinuationToken") : nil
        } while token != nil
    }

    // MARK: Objects

    func createFolder(bucket: String, key: String) async throws {
        _ = try await client.s3(method: "PUT", bucket: bucket, key: key, body: Data())
    }

    func deleteObject(bucket: String, key: String) async throws {
        _ = try await client.s3(method: "DELETE", bucket: bucket, key: key)
    }

    /// Deletes keys in batches of 1000 (DeleteObjects).
    func deleteObjects(bucket: String, keys: [(key: String, versionId: String?)]) async throws {
        for start in stride(from: 0, to: keys.count, by: 1000) {
            let batch = keys[start..<min(start + 1000, keys.count)]
            var xml = "<Delete><Quiet>true</Quiet>"
            for k in batch {
                xml += "<Object><Key>\(Self.xmlEscape(k.key))</Key>"
                if let v = k.versionId { xml += "<VersionId>\(Self.xmlEscape(v))</VersionId>" }
                xml += "</Object>"
            }
            xml += "</Delete>"
            let body = Data(xml.utf8)
            _ = try await client.s3(method: "POST", bucket: bucket, query: [("delete", "")],
                                    headers: ["content-md5": AWSEncoding.md5Base64(body),
                                              "content-type": "application/xml"],
                                    body: body)
        }
    }

    /// Deletes a key or, for a folder, every object under the prefix.
    func delete(bucket: String, object: S3Object) async throws {
        if object.isFolder {
            let keys = try await allObjects(bucket: bucket, prefix: object.key).map { (key: $0.key, versionId: String?.none) }
            try await deleteObjects(bucket: bucket, keys: keys + [(key: object.key, versionId: nil)])
        } else {
            try await deleteObject(bucket: bucket, key: object.key)
        }
    }

    func getText(bucket: String, key: String) async throws -> String {
        let (data, _) = try await client.s3(method: "GET", bucket: bucket, key: key)
        return String(decoding: data, as: UTF8.self)
    }

    func putText(bucket: String, key: String, content: String) async throws {
        _ = try await client.s3(method: "PUT", bucket: bucket, key: key,
                                headers: ["content-type": Self.contentType(for: key)],
                                body: Data(content.utf8))
    }

    static func contentType(for key: String) -> String {
        let ext = (key as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    fileprivate static func xmlEscape(_ s: String) -> String { XNode.escape(s) }

    // MARK: Transfers with progress

    func upload(bucket: String, key: String, file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        await client.resolveBucketRegion(bucket)
        var req = client.s3Request(method: "PUT", bucket: bucket, key: key,
                                   headers: ["content-type": Self.contentType(for: key)],
                                   unsignedPayload: true)
        req.timeoutInterval = 3600
        req = try AWSClient.checked(req)
        let throttle = ProgressThrottle()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var observation: NSKeyValueObservation?
            let task = client.session.uploadTask(with: req, fromFile: file) { data, response, error in
                observation?.invalidate()
                if let error { return cont.resume(throwing: error) }
                let http = response as? HTTPURLResponse
                guard let http, (200..<300).contains(http.statusCode) else {
                    return cont.resume(throwing: AWSClient.error(from: data ?? Data(), status: http?.statusCode ?? 0))
                }
                cont.resume()
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in
                if throttle.shouldReport(p.fractionCompleted) { progress(p.fractionCompleted) }
            }
            task.resume()
        }
    }

    func download(bucket: String, key: String, to destination: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        await client.resolveBucketRegion(bucket)
        var req = client.s3Request(method: "GET", bucket: bucket, key: key)
        req.timeoutInterval = 3600
        req = try AWSClient.checked(req)
        let throttle = ProgressThrottle()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var observation: NSKeyValueObservation?
            let task = client.session.downloadTask(with: req) { tmp, response, error in
                observation?.invalidate()
                if let error { return cont.resume(throwing: error) }
                let http = response as? HTTPURLResponse
                guard let http, (200..<300).contains(http.statusCode), let tmp else {
                    let body = tmp.flatMap { try? Data(contentsOf: $0) } ?? Data()
                    return cont.resume(throwing: AWSClient.error(from: body, status: http?.statusCode ?? 0))
                }
                do {
                    let fm = FileManager.default
                    // Replaces a file the user chose to overwrite, never a folder.
                    var isFolder: ObjCBool = false
                    if fm.fileExists(atPath: destination.path, isDirectory: &isFolder) {
                        guard !isFolder.boolValue else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path]) }
                        try fm.removeItem(at: destination)
                    }
                    try fm.moveItem(at: tmp, to: destination)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in
                if throttle.shouldReport(p.fractionCompleted) { progress(p.fractionCompleted) }
            }
            task.resume()
        }
    }

    // MARK: Buckets

    func createBucket(_ o: CreateBucketOptions) async throws {
        let name = o.bucketName
        client.rememberBucketRegion(name, o.region)

        var body: Data?
        if o.region != "us-east-1" {
            body = Data("""
            <CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
            <LocationConstraint>\(o.region)</LocationConstraint></CreateBucketConfiguration>
            """.utf8)
        }
        _ = try await client.s3(method: "PUT", bucket: name, body: body)

        let flag = o.blockAllPublicAccess ? "true" : "false"
        try await putConfig(name, "publicAccessBlock", """
        <PublicAccessBlockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
        <BlockPublicAcls>\(flag)</BlockPublicAcls><IgnorePublicAcls>\(flag)</IgnorePublicAcls>\
        <BlockPublicPolicy>\(flag)</BlockPublicPolicy><RestrictPublicBuckets>\(flag)</RestrictPublicBuckets>\
        </PublicAccessBlockConfiguration>
        """)

        if o.versioningEnabled {
            try await putConfig(name, "versioning", """
            <VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>
            """)
        }

        let rule: String
        switch o.encryption {
        case .sseS3:
            rule = "<ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm></ApplyServerSideEncryptionByDefault>"
        case .sseKms:
            let key = o.kmsKeyArn.isEmpty ? "" : "<KMSMasterKeyID>\(Self.xmlEscape(o.kmsKeyArn))</KMSMasterKeyID>"
            rule = "<ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm>\(key)</ApplyServerSideEncryptionByDefault>"
                + "<BucketKeyEnabled>\(o.bucketKeyEnabled)</BucketKeyEnabled>"
        }
        try await putConfig(name, "encryption", """
        <ServerSideEncryptionConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Rule>\(rule)</Rule></ServerSideEncryptionConfiguration>
        """)

        let tags = o.tags.filter { !$0.0.isEmpty }
        if !tags.isEmpty {
            let set = tags.map { "<Tag><Key>\(Self.xmlEscape($0.0))</Key><Value>\(Self.xmlEscape($0.1))</Value></Tag>" }.joined()
            try await putConfig(name, "tagging", "<Tagging><TagSet>\(set)</TagSet></Tagging>")
        }
    }

    fileprivate func putConfig(_ bucket: String, _ subresource: String, _ xml: String,
                               contentType: String = "application/xml") async throws {
        let body = Data(xml.utf8)
        _ = try await client.s3(method: "PUT", bucket: bucket, query: [(subresource, "")],
                                headers: ["content-md5": AWSEncoding.md5Base64(body),
                                          "content-type": contentType],
                                body: body)
    }

    /// Empties the bucket (objects and versions) and deletes it.
    func deleteBucket(_ bucket: String) async throws {
        await client.resolveBucketRegion(bucket)
        let keys = try await allObjects(bucket: bucket, prefix: "").map { (key: $0.key, versionId: String?.none) }
        try await deleteObjects(bucket: bucket, keys: keys)

        var keyMarker: String?
        var versionMarker: String?
        repeat {
            var q = [("versions", ""), ("max-keys", "1000")]
            if let keyMarker { q.append(("key-marker", keyMarker)) }
            if let versionMarker { q.append(("version-id-marker", versionMarker)) }
            let (data, _) = try await client.s3(method: "GET", bucket: bucket, query: q)
            guard let xml = XNode.parse(data) else { break }
            let versions = (xml.all("Version") + xml.all("DeleteMarker"))
                .map { (key: $0.str("Key"), versionId: Optional($0.str("VersionId"))) }
            try await deleteObjects(bucket: bucket, keys: versions)
            if xml.bool("IsTruncated") {
                keyMarker = xml.str("NextKeyMarker")
                versionMarker = xml.str("NextVersionIdMarker")
            } else {
                keyMarker = nil
            }
        } while keyMarker != nil

        _ = try await client.s3(method: "DELETE", bucket: bucket)
    }

    /// True when the bucket is missing any Block Public Access flag.
    func isPubliclyAccessible(_ bucket: String) async -> Bool {
        do {
            let (data, _) = try await client.s3(method: "GET", bucket: bucket, query: [("publicAccessBlock", "")])
            guard let xml = XNode.parse(data) else { return false }
            return !(xml.bool("BlockPublicAcls") && xml.bool("IgnorePublicAcls")
                     && xml.bool("BlockPublicPolicy") && xml.bool("RestrictPublicBuckets"))
        } catch let e as AWSError where e.code == "NoSuchPublicAccessBlockConfiguration" {
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Bucket settings

extension S3Service {
    private static let ns = #"xmlns="http://s3.amazonaws.com/doc/2006-03-01/""#

    /// Reads every section at once. "Not configured" answers are the defaults; other errors stay per section.
    func settings(_ bucket: String) async -> S3BucketSettings {
        await client.resolveBucketRegion(bucket)
        async let versioning = section(bucket, "versioning")
        async let encryption = section(bucket, "encryption", missing: "ServerSideEncryptionConfigurationNotFoundError")
        async let publicAccess = section(bucket, "publicAccessBlock", missing: "NoSuchPublicAccessBlockConfiguration")
        async let tagging = section(bucket, "tagging", missing: "NoSuchTagSet")
        async let lifecycle = section(bucket, "lifecycle", missing: "NoSuchLifecycleConfiguration")
        async let policy = section(bucket, "policy", missing: "NoSuchBucketPolicy")

        var s = S3BucketSettings()
        func apply(_ name: String, _ result: Result<Data?, Error>, _ read: (Data) -> Void) {
            switch result {
            case .success(let data): if let data { read(data) }
            case .failure(let error): s.errors[name] = error.localizedDescription
            }
        }
        apply("versioning", await versioning) { data in
            let xml = XNode.parse(data)
            s.versioning = S3BucketSettings.Versioning(rawValue: xml?.str("Status") ?? "") ?? .off
            s.mfaDelete = xml?.str("MfaDelete") == "Enabled"
        }
        apply("encryption", await encryption) { data in
            guard let rule = XNode.parse(data)?.find("Rule") else { return }
            s.encryption = S3BucketSettings.Encryption(rawValue: rule.str("ApplyServerSideEncryptionByDefault/SSEAlgorithm")) ?? .sseS3
            s.kmsKeyId = rule.str("ApplyServerSideEncryptionByDefault/KMSMasterKeyID")
            s.bucketKeyEnabled = rule.bool("BucketKeyEnabled")
        }
        apply("publicAccessBlock", await publicAccess) { data in
            guard let xml = XNode.parse(data) else { return }
            s.publicAccess = .init(blockPublicAcls: xml.bool("BlockPublicAcls"), ignorePublicAcls: xml.bool("IgnorePublicAcls"),
                                   blockPublicPolicy: xml.bool("BlockPublicPolicy"),
                                   restrictPublicBuckets: xml.bool("RestrictPublicBuckets"))
        }
        apply("tagging", await tagging) { data in
            s.tags = (XNode.parse(data)?.list("TagSet", item: "Tag") ?? [])
                .map { .init(key: $0.str("Key"), value: $0.str("Value")) }
        }
        apply("lifecycle", await lifecycle) { data in
            s.lifecycle = (XNode.parse(data)?.all("Rule") ?? []).map(Self.rule)
        }
        apply("policy", await policy) { data in s.policy = Self.prettyJSON(data) }
        return s
    }

    /// GET ?<subresource>: nil when S3 answers that the section isn't configured.
    private func section(_ bucket: String, _ subresource: String, missing: String? = nil) async -> Result<Data?, Error> {
        do {
            return .success(try await client.s3(method: "GET", bucket: bucket, query: [(subresource, "")]).0)
        } catch let e as AWSError where e.code == missing {
            return .success(nil)
        } catch {
            return .failure(error)
        }
    }

    private static func prettyJSON(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: pretty, as: UTF8.self)
    }

    static func rule(_ x: XNode) -> S3BucketSettings.LifecycleRule {
        var r = S3BucketSettings.LifecycleRule(ruleId: x.str("ID"), enabled: x.str("Status") == "Enabled")
        let simple: [String: Set<String>] = [
            "ID": [], "Status": [], "Prefix": [], "Filter": ["Prefix"], "Transition": ["Days", "StorageClass"],
            "Expiration": ["Days"], "NoncurrentVersionExpiration": ["NoncurrentDays"],
            "AbortIncompleteMultipartUpload": ["DaysAfterInitiation"],
        ]
        let isSimple = x.children.allSatisfy { c in
            guard let allowed = simple[c.name] else { return false }
            return c.children.allSatisfy { allowed.contains($0.name) }
        }
        guard isSimple else { r.raw = x.xml; return r }
        r.prefix = x["Filter"] != nil ? x.str("Filter/Prefix") : x.str("Prefix")
        r.transitions = x.all("Transition").map { .init(days: $0.int("Days") ?? 0, storageClass: $0.str("StorageClass")) }
        r.expirationDays = x.int("Expiration/Days")
        r.noncurrentExpirationDays = x.int("NoncurrentVersionExpiration/NoncurrentDays")
        r.abortMultipartDays = x.int("AbortIncompleteMultipartUpload/DaysAfterInitiation")
        return r
    }

    static func lifecycleXML(_ rules: [S3BucketSettings.LifecycleRule]) -> String {
        let body = rules.map { r -> String in
            if let raw = r.raw { return raw }
            var x = "<Rule><ID>\(xmlEscape(r.ruleId))</ID><Filter><Prefix>\(xmlEscape(r.prefix))</Prefix></Filter>"
            x += "<Status>\(r.enabled ? "Enabled" : "Disabled")</Status>"
            for t in r.transitions {
                x += "<Transition><Days>\(t.days)</Days><StorageClass>\(xmlEscape(t.storageClass))</StorageClass></Transition>"
            }
            if let d = r.expirationDays { x += "<Expiration><Days>\(d)</Days></Expiration>" }
            if let d = r.noncurrentExpirationDays { x += "<NoncurrentVersionExpiration><NoncurrentDays>\(d)</NoncurrentDays></NoncurrentVersionExpiration>" }
            if let d = r.abortMultipartDays { x += "<AbortIncompleteMultipartUpload><DaysAfterInitiation>\(d)</DaysAfterInitiation></AbortIncompleteMultipartUpload>" }
            return x + "</Rule>"
        }.joined()
        return "<LifecycleConfiguration \(ns)>\(body)</LifecycleConfiguration>"
    }

    // MARK: Changes (each one is confirmed in the UI first)

    func setVersioning(_ bucket: String, enabled: Bool) async throws {
        try await putConfig(bucket, "versioning", """
        <VersioningConfiguration \(Self.ns)><Status>\(enabled ? "Enabled" : "Suspended")</Status></VersioningConfiguration>
        """)
    }

    func setEncryption(_ bucket: String, _ encryption: S3BucketSettings.Encryption, kmsKeyId: String, bucketKey: Bool) async throws {
        var rule = "<ApplyServerSideEncryptionByDefault><SSEAlgorithm>\(encryption.rawValue)</SSEAlgorithm>"
        let key = kmsKeyId.trimmingCharacters(in: .whitespaces)
        if encryption != .sseS3 && !key.isEmpty { rule += "<KMSMasterKeyID>\(Self.xmlEscape(key))</KMSMasterKeyID>" }
        rule += "</ApplyServerSideEncryptionByDefault>"
        if encryption == .sseKms { rule += "<BucketKeyEnabled>\(bucketKey)</BucketKeyEnabled>" }
        try await putConfig(bucket, "encryption", """
        <ServerSideEncryptionConfiguration \(Self.ns)><Rule>\(rule)</Rule></ServerSideEncryptionConfiguration>
        """)
    }

    func setPublicAccessBlock(_ bucket: String, _ p: S3BucketSettings.PublicAccessBlock) async throws {
        try await putConfig(bucket, "publicAccessBlock", """
        <PublicAccessBlockConfiguration \(Self.ns)>\
        <BlockPublicAcls>\(p.blockPublicAcls)</BlockPublicAcls><IgnorePublicAcls>\(p.ignorePublicAcls)</IgnorePublicAcls>\
        <BlockPublicPolicy>\(p.blockPublicPolicy)</BlockPublicPolicy><RestrictPublicBuckets>\(p.restrictPublicBuckets)</RestrictPublicBuckets>\
        </PublicAccessBlockConfiguration>
        """)
    }

    /// Replaces the whole tag set; no tags deletes it.
    func setTags(_ bucket: String, _ tags: [S3BucketSettings.Tag]) async throws {
        let tags = tags.filter { !$0.key.isEmpty }
        guard !tags.isEmpty else {
            _ = try await client.s3(method: "DELETE", bucket: bucket, query: [("tagging", "")])
            return
        }
        let set = tags.map { "<Tag><Key>\(Self.xmlEscape($0.key))</Key><Value>\(Self.xmlEscape($0.value))</Value></Tag>" }.joined()
        try await putConfig(bucket, "tagging", "<Tagging \(Self.ns)><TagSet>\(set)</TagSet></Tagging>")
    }

    /// Replaces every lifecycle rule; no rules deletes the configuration.
    func setLifecycle(_ bucket: String, _ rules: [S3BucketSettings.LifecycleRule]) async throws {
        guard !rules.isEmpty else {
            _ = try await client.s3(method: "DELETE", bucket: bucket, query: [("lifecycle", "")])
            return
        }
        try await putConfig(bucket, "lifecycle", Self.lifecycleXML(rules))
    }

    /// Sends the policy as written (S3 validates it); an empty policy deletes it.
    func setPolicy(_ bucket: String, _ policy: String) async throws {
        let text = policy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            _ = try await client.s3(method: "DELETE", bucket: bucket, query: [("policy", "")])
            return
        }
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any] else {
            throw AWSError(code: "MalformedPolicy", message: "The policy is not a JSON object.", status: 0)
        }
        try await putConfig(bucket, "policy", text, contentType: "application/json")
    }
}

/// Where an object goes when it is downloaded into a folder: a key is chosen by whoever wrote the
/// bucket, so its name never escapes the folder and never replaces what is already there.
/// Passes progress on only when it moved by `step` (and once at the end): KVO fires for every chunk, and each
/// report schedules a UI update, so a large transfer would otherwise flood the main thread.
final class ProgressThrottle: @unchecked Sendable {
    private let step: Double
    private var last = -1.0
    private let lock = NSLock()

    init(step: Double = 0.01) { self.step = step }

    func shouldReport(_ fraction: Double) -> Bool {
        lock.withLock {
            let report = fraction >= 1 ? last < 1 : fraction - last >= step
            if report { last = fraction }
            return report
        }
    }
}

enum S3Download {
    /// The key's last component, usable as a file name ("." and ".." are not).
    static func fileName(forKey key: String) -> String {
        let last = key.split(separator: "/").last.map(String.init) ?? ""
        let clean = last.replacingOccurrences(of: "\0", with: "")
        return clean.isEmpty || clean == "." || clean == ".." ? "download" : clean
    }

    /// A file in `folder` for the key, numbered ("name (2).ext") when the name is taken.
    static func destination(forKey key: String, in folder: URL, fileManager: FileManager = .default) -> URL {
        let name = fileName(forKey: key) as NSString
        var url = folder.appendingPathComponent(name as String)
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            let numbered = name.pathExtension.isEmpty
                ? "\(name) (\(n))" : "\(name.deletingPathExtension) (\(n)).\(name.pathExtension)"
            url = folder.appendingPathComponent(numbered)
            n += 1
        }
        return url
    }
}
