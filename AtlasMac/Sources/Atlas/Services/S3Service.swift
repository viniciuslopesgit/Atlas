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

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Transfers with progress

    func upload(bucket: String, key: String, file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        await client.resolveBucketRegion(bucket)
        var req = client.s3Request(method: "PUT", bucket: bucket, key: key,
                                   headers: ["content-type": Self.contentType(for: key)],
                                   unsignedPayload: true)
        req.timeoutInterval = 3600
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
            observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }

    func download(bucket: String, key: String, to destination: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        await client.resolveBucketRegion(bucket)
        var req = client.s3Request(method: "GET", bucket: bucket, key: key)
        req.timeoutInterval = 3600
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
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.moveItem(at: tmp, to: destination)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
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

    private func putConfig(_ bucket: String, _ subresource: String, _ xml: String) async throws {
        let body = Data(xml.utf8)
        _ = try await client.s3(method: "PUT", bucket: bucket, query: [(subresource, "")],
                                headers: ["content-md5": AWSEncoding.md5Base64(body),
                                          "content-type": "application/xml"],
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
