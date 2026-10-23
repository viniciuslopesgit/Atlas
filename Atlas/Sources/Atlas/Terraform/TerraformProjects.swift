import Foundation

/// A folder with Terraform configuration that Atlas runs commands in.
struct TerraformProject: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var path: String
    var createdAt = Date()

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Persists the project list and the active project in `terraform-projects.json`.
struct TerraformProjectStore {
    struct Contents: Codable, Equatable {
        var projects: [TerraformProject] = []
        var activeId: UUID?
    }

    var folder: URL = AccountStore.defaultFolder

    private var file: URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("terraform-projects.json")
    }

    func load() -> Contents {
        guard let data = try? Data(contentsOf: file) else { return Contents() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Contents.self, from: data)) ?? Contents()
    }

    func save(_ contents: Contents) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(contents) { try? data.write(to: file, options: [.atomic]) }
    }

    /// The active project, if its folder still exists.
    var activeProject: TerraformProject? {
        let c = load()
        guard let p = c.projects.first(where: { $0.id == c.activeId }) else { return nil }
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }
}

/// Writes resources into a Terraform project so the next plan adopts them instead of creating duplicates:
/// the Atlas template (when there is one) plus an `import {}` block in `imports.tf`.
enum TerraformAware {
    static let importsFile = "imports.tf"

    /// Returns the files written.
    @discardableResult
    static func adopt(_ resources: [DiscoveredResource], into project: URL) throws -> [URL] {
        guard !resources.isEmpty else { return [] }
        var written: [URL] = []
        for (name, content) in ImportDiscovery.suggestedFiles(resources).sorted(by: { $0.key < $1.key }) {
            let r = try HclGenerator.write(content, to: project.appendingPathComponent(name))
            if r.wasWritten { written.append(r.path) }
        }
        if let imports = try appendImports(resources, in: project) { written.append(imports) }
        return written
    }

    /// Appends import blocks for addresses that `imports.tf` doesn't have yet. Returns the file when it changed.
    static func appendImports(_ resources: [DiscoveredResource], in project: URL) throws -> URL? {
        let file = project.appendingPathComponent(importsFile)
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let missing = resources.filter { r in
            !existing.contains("to = \(r.address)\n") && !existing.contains("to = \(r.address)\r\n")
        }
        guard !missing.isEmpty else { return nil }
        let content = existing.isEmpty
            ? ImportDiscovery.importBlocks(missing)
            : existing + (existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n")
                + ImportDiscovery.importBlocks(missing, header: false)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A bucket Atlas just created, modelled from the options it was created with.
    static func bucket(_ o: CreateBucketOptions) -> DiscoveredResource {
        let tf = ImportDiscovery.tfName(o.bucketName, fallback: "bucket")
        var m = S3BucketHcl()
        m.resourceName = tf
        m.bucketName = o.bucketName
        m.blockPublicAcls = o.blockAllPublicAccess
        m.blockPublicPolicy = o.blockAllPublicAccess
        m.ignorePublicAcls = o.blockAllPublicAccess
        m.restrictPublicBuckets = o.blockAllPublicAccess
        m.versioning = o.versioningEnabled
        m.serverSideEncryption = true
        m.tags = o.tags.filter { !$0.0.isEmpty }.map { HclTag(key: $0.0, value: $0.1) }
        return ImportDiscovery.resource(.s3Bucket, awsId: o.bucketName, name: o.bucketName, tfName: tf,
                                        importId: o.bucketName, region: o.region,
                                        tags: Dictionary(o.tags, uniquingKeysWith: { a, _ in a }), hcl: .s3(m))
    }

    /// Instances Atlas just launched, read back from EC2 so the HCL matches what exists.
    static func instances(_ ids: [String], client: AWSClient) async throws -> [DiscoveredResource] {
        var options = ImportOptions()
        options.types = [.ec2Instance]
        options.instanceIds = ids
        // EC2 is eventually consistent: a just-launched instance can take a moment to be describable.
        for attempt in 0..<4 {
            let analysis = await ImportDiscoverer(client: client).discover(options)
            if let error = analysis.partialErrors[.ec2Instance], !error.contains("InvalidInstanceID.NotFound") {
                throw AWSError(code: "DescribeInstances", message: error, status: 0)
            }
            if analysis.resources.count == ids.count || attempt == 3 { return analysis.resources }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return []
    }

    /// Adopts freshly created resources into the active project. Returns a message for the user, or nil
    /// when there is no active project. Failures are reported in the message, never thrown: the AWS
    /// operation already succeeded.
    static func record(_ make: () async throws -> [DiscoveredResource],
                       store: TerraformProjectStore = TerraformProjectStore()) async -> String? {
        guard let project = store.activeProject else { return nil }
        do {
            let files = try adopt(try await make(), into: project.url)
            guard !files.isEmpty else { return nil }
            return "Added to \(project.name): " + files.map(\.lastPathComponent).joined(separator: ", ")
        } catch {
            return "Created, but writing Terraform to \(project.name) failed: \(error.localizedDescription)"
        }
    }
}
