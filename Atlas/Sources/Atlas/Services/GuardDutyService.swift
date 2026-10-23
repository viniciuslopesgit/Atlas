import Foundation

/// GuardDuty (REST-JSON): ListDetectors, GetDetector, ListFindings, GetFindings, Archive/UnarchiveFindings.
struct GuardDutyService {
    let client: AWSClient

    struct Detector: Equatable {
        let id: String
        /// False when GuardDuty is suspended in the region (it keeps its findings but finds nothing new).
        let enabled: Bool
    }

    private var host: String { "guardduty.\(client.region).amazonaws.com" }

    private func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        try await client.restJSON(method: method, host: host, signingName: "guardduty", path: path, body: body)
    }

    /// The region's detector id, or nil when GuardDuty was never enabled here. An id that isn't one
    /// (AWS's are 32 hex characters) is ignored: it goes into request paths.
    func detectorId() async throws -> String? {
        try await call("GET", "/detector").strings("detectorIds")
            .first { $0.range(of: "^[A-Za-z0-9]{1,300}$", options: .regularExpression) != nil }
    }

    func detector() async throws -> Detector? {
        guard let id = try await detectorId() else { return nil }
        let status = try await call("GET", "/detector/\(id)").string("status")
        return Detector(id: id, enabled: status != "DISABLED")
    }

    /// Active findings of the region's detector, highest severity first; none without a detector.
    func findings() async throws -> [GuardDutyFinding] {
        guard let id = try await detectorId() else { return [] }
        return try await findings(detectorId: id)
    }

    /// Archived or active findings, optionally only those updated after a date (ListFindings takes epoch ms).
    func findings(detectorId: String, archived: Bool = false, updatedAfter: Date? = nil) async throws -> [GuardDutyFinding] {
        var criterion: [String: Any] = ["service.archived": ["eq": [archived ? "true" : "false"]]]
        if let updatedAfter { criterion["updatedAt"] = ["gt": Int64(updatedAfter.timeIntervalSince1970 * 1000)] }

        var ids: [String] = []
        var token: String?
        repeat {
            var body: [String: Any] = [
                "maxResults": 50,
                "findingCriteria": ["criterion": criterion],
                "sortCriteria": ["attributeName": "severity", "orderBy": "DESC"],
            ]
            if let token { body["nextToken"] = token }
            let resp = try await call("POST", "/detector/\(detectorId)/findings", body)
            ids += resp.strings("findingIds")
            let next = resp.string("nextToken")
            token = next.isEmpty ? nil : next
        } while token != nil

        var findings: [GuardDutyFinding] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            let resp = try await call("POST", "/detector/\(detectorId)/findings/get", ["findingIds": batch])
            findings += resp.array("findings").map { Self.finding($0, region: client.region) }
        }
        return findings.sorted { ($1.severity, $0.title) < ($0.severity, $1.title) }
    }

    func archive(detectorId: String, ids: [String]) async throws {
        try await change(detectorId, "archive", ids)
    }

    func unarchive(detectorId: String, ids: [String]) async throws {
        try await change(detectorId, "unarchive", ids)
    }

    /// Archive/UnarchiveFindings take at most 50 ids per call.
    private func change(_ detectorId: String, _ action: String, _ ids: [String]) async throws {
        for start in stride(from: 0, to: ids.count, by: 50) {
            _ = try await call("POST", "/detector/\(detectorId)/findings/\(action)",
                               ["findingIds": Array(ids[start..<min(start + 50, ids.count)])])
        }
    }

    // MARK: Parsing (the Finding shape of the GuardDuty API reference)

    static func finding(_ f: [String: Any], region: String) -> GuardDutyFinding {
        let resource = f.dict("resource")
        let service = f.dict("service")
        let action = service.dict("action")
        let resourceType = resource.string("resourceType")
        var finding = GuardDutyFinding(
            id: f.string("id"), title: f.string("title"), description: f.string("description"),
            severity: f.number("severity"), type: f.string("type"),
            resourceType: resourceType.isEmpty ? "Unknown" : resourceType,
            region: f.string("region").isEmpty ? region : f.string("region"), accountId: f.string("accountId"),
            createdAt: AWSDate.parse(f.string("createdAt")), updatedAt: AWSDate.parse(f.string("updatedAt")))
        finding.archived = service["archived"] as? Bool ?? false
        finding.count = max(1, Int(service.number("count")))
        finding.firstSeen = AWSDate.parse(service.string("eventFirstSeen"))
        finding.lastSeen = AWSDate.parse(service.string("eventLastSeen"))
        finding.actionType = action.string("actionType")
        (finding.resourceId, finding.resource) = resourceDetails(resource)
        (finding.action, finding.actor) = actionDetails(action, service: service)
        return finding
    }

    private static func details(_ pairs: [(String, String)]) -> [GuardDutyDetail] {
        pairs.filter { !$0.1.isEmpty }.map { GuardDutyDetail(label: $0.0, value: $0.1) }
    }

    /// The affected resource's id and what the finding says about it.
    private static func resourceDetails(_ r: [String: Any]) -> (String, [GuardDutyDetail]) {
        let instance = r.dict("instanceDetails")
        let nic = instance.array("networkInterfaces").first ?? [:]
        let key = r.dict("accessKeyDetails")
        let buckets = r.array("s3BucketDetails")
        let eks = r.dict("eksClusterDetails")
        let workload = r.dict("kubernetesDetails").dict("kubernetesWorkloadDetails")
        let ecs = r.dict("ecsClusterDetails")
        let lambda = r.dict("lambdaDetails")
        let rds = r.dict("rdsDbInstanceDetails")
        let container = r.dict("containerDetails")
        let tags = instance.array("tags").map { "\($0.string("key"))=\($0.string("value"))" }.joined(separator: ", ")

        let list = details([
            ("Instance", instance.string("instanceId")), ("Instance type", instance.string("instanceType")),
            ("Image", instance.string("imageId")), ("Public IP", nic.string("publicIp")),
            ("Private IP", nic.string("privateIpAddress")), ("VPC", nic.string("vpcId")), ("Tags", tags),
            ("User", key.string("userName")), ("User type", key.string("userType")),
            ("Access key", key.string("accessKeyId")), ("Principal", key.string("principalId")),
            ("Buckets", buckets.map { $0.string("name") }.joined(separator: ", ")),
            ("EKS cluster", eks.string("name")), ("Workload", workload.string("name")),
            ("Namespace", workload.string("namespace")),
            ("ECS cluster", ecs.string("name")), ("Task definition", ecs.dict("taskDetails").string("definitionArn")),
            ("Lambda function", lambda.string("functionName")),
            ("Database", rds.string("dbInstanceIdentifier")), ("Engine", rds.string("engine")),
            ("Container", container.string("name")), ("Image", container.string("image")),
        ])
        let id = [instance.string("instanceId"), buckets.map { $0.string("name") }.joined(separator: ", "),
                  key.string("userName"), workload.string("name"), eks.string("name"), ecs.string("name"),
                  lambda.string("functionName"), rds.string("dbInstanceIdentifier"), container.string("name"),
                  key.string("accessKeyId")].first { !$0.isEmpty } ?? ""
        return (id, list)
    }

    /// What happened (API call, connection, port probe, DNS request…) and who did it.
    private static func actionDetails(_ a: [String: Any], service: [String: Any]) -> ([GuardDutyDetail], [GuardDutyDetail]) {
        let api = a.dict("awsApiCallAction")
        let network = a.dict("networkConnectionAction")
        let probe = a.dict("portProbeAction")
        let dns = a.dict("dnsRequestAction")
        let kubernetes = a.dict("kubernetesApiCallAction")
        let rds = a.dict("rdsLoginAttemptAction")
        let probes = probe.array("portProbeDetails")
        func flag(_ d: [String: Any], _ k: String) -> String { (d[k] as? Bool).map { $0 ? "Yes" : "No" } ?? "" }
        func port(_ d: [String: Any]) -> String { d["port"].map { "\($0)" } ?? "" }

        let action = details([
            ("API", api.string("api")), ("Service", api.string("serviceName")), ("Error", api.string("errorCode")),
            ("User agent", api.string("userAgent")),
            ("Direction", network.string("connectionDirection")), ("Protocol", network.string("protocol")),
            ("Local port", port(network.dict("localPortDetails"))), ("Remote port", port(network.dict("remotePortDetails"))),
            ("Blocked", flag(network, "blocked")),
            ("Probed ports", probes.map { port($0.dict("localPortDetails")) }.filter { !$0.isEmpty }.joined(separator: ", ")),
            ("Probe blocked", flag(probe, "blocked")),
            ("Domain", dns.string("domain")), ("DNS blocked", flag(dns, "blocked")),
            ("Request", [kubernetes.string("verb"), kubernetes.string("requestUri")].filter { !$0.isEmpty }.joined(separator: " ")),
            ("Login attempts", rds.array("LoginAttributes").map { "\($0.string("user")) (\(Int($0.number("failedLoginAttempts"))) failed)" }
                .joined(separator: ", ")),
        ])

        let remote = [api, network, kubernetes, rds].map { $0.dict("remoteIpDetails") }.first { !$0.isEmpty }
            ?? probes.first?.dict("remoteIpDetails") ?? [:]
        let place = [remote.dict("city").string("cityName"), remote.dict("country").string("countryName")]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        let org = remote.dict("organization")
        let info = service.dict("additionalInfo")
        let actors = service.dict("detection").dict("sequence").array("actors")
        let actor = details([
            ("Remote IP", remote.string("ipAddressV4").isEmpty ? remote.string("ipAddressV6") : remote.string("ipAddressV4")),
            ("Location", place), ("Organization", org.string("asnOrg").isEmpty ? org.string("org") : org.string("asnOrg")),
            ("ISP", org.string("isp")), ("ASN", org.string("asn")),
            ("Caller type", api.string("callerType")), ("Remote account", api.dict("remoteAccountDetails").string("accountId")),
            ("Threat", info.string("threatName")), ("Threat list", info.string("threatListName")),
            ("Actors in sequence", actors.isEmpty ? "" : actors.map { $0.string("id") }.joined(separator: ", ")),
        ])
        return (action, actor)
    }
}
