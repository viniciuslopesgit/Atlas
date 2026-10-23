import Foundation
import Testing
@testable import Atlas

/// Service tests against the URLProtocol mock — no real AWS calls.
/// Serialized because the mock's handler is shared.
@Suite(.serialized)
struct ServiceTests {
    @Test func ec2InstancesFollowsPagination() async throws {
        let client = MockURLProtocol.client { _, body in
            let token = formParams(body)["NextToken"]
            let id = token == nil ? "i-1" : "i-2"
            let next = token == nil ? "<nextToken>page2</nextToken>" : ""
            return .init(body: """
            <DescribeInstancesResponse><reservationSet><item><reservationId>r-1</reservationId><ownerId>111</ownerId>
            <instancesSet><item><instanceId>\(id)</instanceId><instanceType>t3.micro</instanceType>
            <instanceState><name>running</name></instanceState><metadataOptions><httpTokens>required</httpTokens></metadataOptions>
            <cpuOptions><coreCount>1</coreCount><threadsPerCore>2</threadsPerCore></cpuOptions>
            <tagSet><item><key>Name</key><value>web-\(id)</value></item></tagSet></item></instancesSet></item></reservationSet>
            \(next)</DescribeInstancesResponse>
            """)
        }
        let instances = try await Ec2Service(client: client).instances()
        #expect(instances.map(\.instanceId) == ["i-1", "i-2"])
        #expect(instances[0].name == "web-i-1")
        #expect(instances[0].vCpuCount == 2)
        #expect(instances[0].publicIpAddress == "—")
        #expect(instances[0].instanceArn == "arn:aws:ec2:us-east-1:111:instance/i-1")

        let first = MockURLProtocol.requests[0]
        #expect(first.request.url?.host == "ec2.us-east-1.amazonaws.com")
        #expect(formParams(first.body)["Action"] == "DescribeInstances")
        #expect(formParams(first.body)["Version"] == "2016-11-15")
        #expect(first.request.value(forHTTPHeaderField: "Authorization")?.contains("/us-east-1/ec2/aws4_request") == true)
    }

    @Test func ec2ActionsSendInstanceIds() async throws {
        let client = MockURLProtocol.client { _, _ in .init(body: "<StopInstancesResponse/>") }
        try await Ec2Service(client: client).stop(["i-a", "i-b"])
        let p = formParams(MockURLProtocol.requests[0].body)
        #expect(p["Action"] == "StopInstances")
        #expect(p["InstanceId.1"] == "i-a")
        #expect(p["InstanceId.2"] == "i-b")
    }

    @Test func queryErrorBecomesAWSError() async {
        let client = MockURLProtocol.client { _, _ in
            .init(status: 403, body: "<ErrorResponse><Error><Code>AccessDenied</Code><Message>no</Message></Error></ErrorResponse>")
        }
        await #expect(throws: AWSError.self) { try await IamService(client: client).users() }
        do { _ = try await IamService(client: client).users() } catch let e as AWSError {
            #expect(e.code == "AccessDenied")
            #expect(e.status == 403)
        } catch { Issue.record("unexpected error \(error)") }
        // IAM is global: always iam.amazonaws.com signed for us-east-1.
        #expect(MockURLProtocol.requests[0].request.url?.host == "iam.amazonaws.com")
    }

    @Test func transferProgressReachesTheUIAtMostOncePerPercent() {
        let throttle = ProgressThrottle()
        let reported = (0...100_000).map { Double($0) / 100_000 }.filter(throttle.shouldReport)
        #expect(reported.count <= 101, "\(reported.count) UI updates for one transfer")
        #expect(reported.first == 0 && reported.last == 1)
        #expect(!throttle.shouldReport(1), "the end is reported once")
    }

    @Test func s3ListsFoldersThenFiles() async throws {
        let client = MockURLProtocol.client { _, _ in
            .init(body: """
            <ListBucketResult><IsTruncated>false</IsTruncated>
            <Contents><Key>docs/</Key><Size>0</Size></Contents>
            <Contents><Key>docs/b.txt</Key><Size>2048</Size><StorageClass>STANDARD</StorageClass><ETag>"abc"</ETag></Contents>
            <Contents><Key>docs/a.json</Key><Size>10</Size></Contents>
            <CommonPrefixes><Prefix>docs/img/</Prefix></CommonPrefixes>
            </ListBucketResult>
            """)
        }
        let objects = try await S3Service(client: client).objects(bucket: "my-bucket", prefix: "docs/")
        #expect(objects.map(\.key) == ["docs/img/", "docs/a.json", "docs/b.txt"])
        #expect(objects[0].isFolder)
        #expect(objects[2].eTag == "abc")
        #expect(objects[2].displaySize == "2.0 KB")

        let url = MockURLProtocol.requests[0].request.url!
        #expect(url.host == "my-bucket.s3.us-east-1.amazonaws.com")
        #expect(url.query?.contains("delimiter=%2F") == true)
        #expect(url.query?.contains("prefix=docs%2F") == true)
    }

    @Test func s3RetriesInBucketRegionAfterRedirect() async throws {
        let client = MockURLProtocol.client { req, _ in
            if req.url!.host!.contains("us-east-1") {
                return .init(status: 301, headers: ["x-amz-bucket-region": "eu-west-1"],
                             body: "<Error><Code>PermanentRedirect</Code></Error>")
            }
            return .init(body: "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>")
        }
        _ = try await S3Service(client: client).objects(bucket: "eu-bucket", prefix: "")
        #expect(MockURLProtocol.requests.count == 2)
        #expect(MockURLProtocol.requests[1].request.url?.host == "eu-bucket.s3.eu-west-1.amazonaws.com")
        #expect(MockURLProtocol.requests[1].request.value(forHTTPHeaderField: "Authorization")?.contains("/eu-west-1/s3/") == true)
        #expect(client.bucketRegion("eu-bucket") == "eu-west-1")
    }

    @Test func s3BucketsWithDotsUsePathStyle() async throws {
        let client = MockURLProtocol.client { _, _ in .init() }
        try await S3Service(client: client).deleteObject(bucket: "my.dotted.bucket", key: "a b.txt")
        let url = MockURLProtocol.requests[0].request.url!
        #expect(url.host == "s3.us-east-1.amazonaws.com")
        #expect(url.absoluteString.hasSuffix("/my.dotted.bucket/a%20b.txt"))
    }

    @Test func billingKeepsTop7AndGroupsOthers() async throws {
        let groups = (1...9).map { #"{"Keys":["svc\#($0)"],"Metrics":{"BlendedCost":{"Amount":"\#($0)","Unit":"USD"}}}"# }
        let client = MockURLProtocol.client { req, _ in
            #expect(req.value(forHTTPHeaderField: "x-amz-target") == "AWSInsightsIndexService.GetCostAndUsage")
            return .init(body: #"{"ResultsByTime":[{"TimePeriod":{"Start":"2026-09-01"},"Groups":[\#(groups.joined(separator: ","))]}]}"#)
        }
        let report = try await CostService(client: client).breakdown(start: Date(), end: Date(), groupBy: "SERVICE")
        #expect(report.topServices.count == 8)
        #expect(report.topServices.first == "svc9")
        #expect(report.topServices.last == "Others")
        #expect(report.entries.first { $0.service == "Others" }?.amount == 3) // svc1 + svc2
        #expect(report.grandTotal == 45)
        #expect(MockURLProtocol.requests[0].request.url?.host == "ce.us-east-1.amazonaws.com")
    }

    // MARK: S3 bucket settings

    /// The subresource of a bucket request ("versioning", "tagging"…), from its query.
    private func subresource(_ req: URLRequest) -> String {
        (req.url?.query ?? "").split(separator: "=").first.map(String.init) ?? ""
    }

    @Test func s3SettingsReadEverySectionAndKeepWhatAtlasCannotEdit() async throws {
        let client = MockURLProtocol.client { req, _ in
            if req.httpMethod == "HEAD" { return .init(headers: ["x-amz-bucket-region": "us-east-1"]) }
            switch self.subresource(req) {
            case "versioning":
                return .init(body: "<VersioningConfiguration><Status>Enabled</Status><MfaDelete>Disabled</MfaDelete></VersioningConfiguration>")
            case "encryption":
                return .init(body: """
                <ServerSideEncryptionConfiguration><Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>aws:kms</SSEAlgorithm>\
                <KMSMasterKeyID>arn:aws:kms:us-east-1:1:key/k</KMSMasterKeyID></ApplyServerSideEncryptionByDefault>\
                <BucketKeyEnabled>true</BucketKeyEnabled></Rule></ServerSideEncryptionConfiguration>
                """)
            case "publicAccessBlock":
                return .init(status: 404, body: "<Error><Code>NoSuchPublicAccessBlockConfiguration</Code></Error>")
            case "tagging":
                return .init(body: "<Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>")
            case "lifecycle":
                return .init(body: """
                <LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
                <Rule><ID>logs</ID><Filter><Prefix>logs/</Prefix></Filter><Status>Enabled</Status>\
                <Transition><Days>30</Days><StorageClass>GLACIER</StorageClass></Transition><Expiration><Days>365</Days></Expiration></Rule>\
                <Rule><ID>tagged</ID><Filter><Tag><Key>tmp</Key><Value>1</Value></Tag></Filter><Status>Disabled</Status>\
                <Expiration><Days>7</Days></Expiration></Rule></LifecycleConfiguration>
                """)
            default:
                return .init(status: 403, body: "<Error><Code>AccessDenied</Code><Message>no policy for you</Message></Error>")
            }
        }
        let s = await S3Service(client: client).settings("my-bucket")
        #expect(s.versioning == .enabled)
        #expect(!s.mfaDelete)
        #expect(s.encryption == .sseKms)
        #expect(s.kmsKeyId == "arn:aws:kms:us-east-1:1:key/k")
        #expect(s.bucketKeyEnabled)
        #expect(s.publicAccess == .init())       // not configured: nothing blocked
        #expect(s.tags == [.init(key: "env", value: "prod")])
        #expect(s.lifecycle.count == 2)
        #expect(s.lifecycle[0].raw == nil)
        #expect(s.lifecycle[0].prefix == "logs/")
        #expect(s.lifecycle[0].transitions == [.init(days: 30, storageClass: "GLACIER")])
        #expect(s.lifecycle[0].expirationDays == 365)
        #expect(s.lifecycle[1].raw != nil)
        #expect(!s.lifecycle[1].enabled)
        #expect(s.policy.isEmpty)
        #expect(s.errors["policy"]?.contains("AccessDenied") == true)
        #expect(s.errors.count == 1)

        // Saving sends the advanced rule back exactly as S3 described it.
        let xml = S3Service.lifecycleXML(s.lifecycle)
        #expect(xml.contains("<Rule><ID>tagged</ID><Filter><Tag><Key>tmp</Key><Value>1</Value></Tag></Filter><Status>Disabled</Status><Expiration><Days>7</Days></Expiration></Rule>"))
        #expect(xml.contains("<Rule><ID>logs</ID><Filter><Prefix>logs/</Prefix></Filter><Status>Enabled</Status><Transition><Days>30</Days><StorageClass>GLACIER</StorageClass></Transition><Expiration><Days>365</Days></Expiration></Rule>"))
        let reparsed = XNode.parse(Data(xml.utf8))?.all("Rule").map(S3Service.rule)
        #expect(reparsed == s.lifecycle)
    }

    @Test func s3SettingsChangesSendTheConfigurationS3Expects() async throws {
        let client = MockURLProtocol.client { _, _ in .init() }
        let s3 = S3Service(client: client)
        try await s3.setVersioning("b", enabled: false)
        try await s3.setEncryption("b", .sseKms, kmsKeyId: " alias/k ", bucketKey: true)
        try await s3.setEncryption("b", .sseS3, kmsKeyId: "ignored", bucketKey: true)
        try await s3.setPublicAccessBlock("b", .init(blockPublicAcls: true, ignorePublicAcls: true,
                                                     blockPublicPolicy: false, restrictPublicBuckets: true))
        try await s3.setTags("b", [.init(key: "a&b", value: "<x>"), .init(key: "", value: "dropped")])
        try await s3.setTags("b", [])
        try await s3.setLifecycle("b", [.init(ruleId: "r", prefix: "tmp/", expirationDays: 3, abortMultipartDays: 1)])
        try await s3.setLifecycle("b", [])
        try await s3.setPolicy("b", #"{"Version":"2012-10-17","Statement":[]}"#)
        try await s3.setPolicy("b", "  ")

        let r = MockURLProtocol.requests
        #expect(r.map { "\($0.request.httpMethod!) \(subresource($0.request))" } == [
            "PUT versioning", "PUT encryption", "PUT encryption", "PUT publicAccessBlock", "PUT tagging", "DELETE tagging",
            "PUT lifecycle", "DELETE lifecycle", "PUT policy", "DELETE policy",
        ])
        #expect(r[0].body.string.contains("<Status>Suspended</Status>"))
        #expect(r[1].body.string.contains("<SSEAlgorithm>aws:kms</SSEAlgorithm><KMSMasterKeyID>alias/k</KMSMasterKeyID>"))
        #expect(r[1].body.string.contains("<BucketKeyEnabled>true</BucketKeyEnabled>"))
        #expect(!r[2].body.string.contains("KMSMasterKeyID") && !r[2].body.string.contains("BucketKey"))
        #expect(r[3].body.string.contains("<BlockPublicPolicy>false</BlockPublicPolicy><RestrictPublicBuckets>true</RestrictPublicBuckets>"))
        #expect(r[4].body.string.contains("<Tag><Key>a&amp;b</Key><Value>&lt;x&gt;</Value></Tag></TagSet>"))
        #expect(!r[4].body.string.contains("dropped"))
        #expect(r[6].body.string.contains("<Rule><ID>r</ID><Filter><Prefix>tmp/</Prefix></Filter><Status>Enabled</Status><Expiration><Days>3</Days></Expiration><AbortIncompleteMultipartUpload><DaysAfterInitiation>1</DaysAfterInitiation></AbortIncompleteMultipartUpload></Rule>"))
        #expect(r[8].request.value(forHTTPHeaderField: "content-type") == "application/json")
        // S3 requires Content-MD5 on lifecycle and tagging writes.
        for i in [0, 3, 4, 6, 8] { #expect(r[i].request.value(forHTTPHeaderField: "content-md5") != nil) }
    }

    @Test func s3PolicyThatIsNotJSONNeverLeavesTheMac() async {
        let client = MockURLProtocol.client { _, _ in .init() }
        await #expect(throws: AWSError.self) { try await S3Service(client: client).setPolicy("b", "{not json") }
        await #expect(throws: AWSError.self) { try await S3Service(client: client).setPolicy("b", "[1]") }
        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test func lifecycleRuleFormNeedsAnIdAndAnAction() {
        #expect(RuleDraft(ruleId: "x").rule == nil)
        #expect(RuleDraft(ruleId: "", expirationDays: "3").rule == nil)
        #expect(RuleDraft(ruleId: "x", expirationDays: "-1").rule == nil)
        #expect(RuleDraft(ruleId: "x", expirationDays: "abc").rule == nil)
        let rule = RuleDraft(ruleId: " x ", transitionDays: "30", storageClass: "GLACIER", expirationDays: "90").rule
        #expect(rule?.ruleId == "x")
        #expect(rule?.transitions == [.init(days: 30, storageClass: "GLACIER")])
        #expect(rule?.expirationDays == 90)
        #expect(rule?.summary == "Whole bucket · GLACIER after 30 d, expire after 90 d")
    }

    @Test func guardDutyPagesAndSortsBySeverity() async throws {
        let client = MockURLProtocol.client { req, body in
            let path = req.url!.path
            if path == "/detector" { return .init(body: #"{"detectorIds":["d1"]}"#) }
            if path == "/detector/d1/findings" {
                let hasToken = body.string.contains("nextToken")
                return .init(body: hasToken ? #"{"findingIds":["f2"]}"# : #"{"findingIds":["f1"],"nextToken":"t"}"#)
            }
            return .init(body: """
            {"findings":[
              {"id":"f1","title":"Low","severity":2,"type":"t","accountId":"1","updatedAt":"2026-01-01T00:00:00.000Z"},
              {"id":"f2","title":"High","severity":8.5,"type":"t","accountId":"1","resource":{"resourceType":"Instance"}}]}
            """)
        }
        let findings = try await GuardDutyService(client: client).findings()
        #expect(findings.map(\.id) == ["f2", "f1"])
        #expect(findings[0].level == .high)
        #expect(findings[1].resourceType == "Unknown")
        #expect(MockURLProtocol.requests.count == 4)
    }

    @Test func guardDutySeverityLevelsFollowAWS() {
        #expect([1, 3.9, 4, 6.9, 7, 8.9, 9, 10].map { GuardDutySeverity(score: $0) }
                == [.low, .low, .medium, .medium, .high, .high, .critical, .critical])
        #expect(GuardDutySeverity.critical.range == "9.0–10.0")
    }

    static let guardDutyFinding = """
    {"id":"f1","type":"UnauthorizedAccess:EC2/SSHBruteForce","title":"SSH brute force","description":"d","severity":9.2,
     "accountId":"111","region":"eu-west-1","createdAt":"2026-10-01T10:00:00.000Z","updatedAt":"2026-10-02T10:00:00.000Z",
     "resource":{"resourceType":"Instance","instanceDetails":{"instanceId":"i-0abc","instanceType":"t3.micro",
       "networkInterfaces":[{"publicIp":"3.3.3.3","vpcId":"vpc-1"}],"tags":[{"key":"Name","value":"web"}]}},
     "service":{"archived":false,"count":42,"eventFirstSeen":"2026-10-01T09:00:00.000Z","eventLastSeen":"2026-10-02T09:59:00.000Z",
       "additionalInfo":{"threatListName":"ProofPoint"},
       "action":{"actionType":"NETWORK_CONNECTION","networkConnectionAction":{"connectionDirection":"INBOUND","protocol":"TCP",
         "blocked":false,"localPortDetails":{"port":22},"remotePortDetails":{"port":50000},
         "remoteIpDetails":{"ipAddressV4":"198.51.100.7","country":{"countryName":"Nowhere"},"city":{"cityName":"Town"},
           "organization":{"asnOrg":"Bad ISP","asn":"64500"}}}}}}
    """

    @Test func guardDutyFindingDetailsNameResourceActionAndActor() throws {
        let json = try #require(JSONSerialization.jsonObject(with: Data(Self.guardDutyFinding.utf8)) as? [String: Any])
        let f = GuardDutyService.finding(json, region: "us-east-1")
        #expect(f.level == .critical)
        #expect(f.region == "eu-west-1")
        #expect(f.resourceId == "i-0abc")
        #expect(f.resourceLabel == "Instance · i-0abc")
        #expect(f.threatPurpose == "UnauthorizedAccess")
        #expect(f.count == 42)
        #expect(f.firstSeen == AWSDate.parse("2026-10-01T09:00:00.000Z"))
        #expect(f.lastSeen == AWSDate.parse("2026-10-02T09:59:00.000Z"))
        #expect(f.actionType == "NETWORK_CONNECTION")
        #expect(f.resource.contains(.init(label: "Public IP", value: "3.3.3.3")))
        #expect(f.resource.contains(.init(label: "Tags", value: "Name=web")))
        #expect(f.action.contains(.init(label: "Local port", value: "22")))
        #expect(f.action.contains(.init(label: "Blocked", value: "No")))
        #expect(f.actor.contains(.init(label: "Remote IP", value: "198.51.100.7")))
        #expect(f.actor.contains(.init(label: "Location", value: "Town, Nowhere")))
        #expect(f.actor.contains(.init(label: "Organization", value: "Bad ISP")))
        #expect(f.actor.contains(.init(label: "Threat list", value: "ProofPoint")))
        #expect(!f.resource.contains { $0.value.isEmpty })

        let api = GuardDutyService.finding(["severity": 2, "resource": ["resourceType": "AccessKey",
            "accessKeyDetails": ["userName": "alice", "accessKeyId": "ASIAEXAMPLE"]],
            "service": ["action": ["actionType": "AWS_API_CALL", "awsApiCallAction": ["api": "ListBuckets", "serviceName": "s3.amazonaws.com",
                "callerType": "Remote IP", "remoteIpDetails": ["ipAddressV4": "203.0.113.9"]]]]], region: "us-east-1")
        #expect(api.resourceId == "alice")
        #expect(api.region == "us-east-1")
        #expect(api.count == 1)
        #expect(api.action.contains(.init(label: "API", value: "ListBuckets")))
        #expect(api.actor.contains(.init(label: "Caller type", value: "Remote IP")))
        #expect(api.actor.contains(.init(label: "Remote IP", value: "203.0.113.9")))
    }

    @Test func guardDutyListsArchivedOrRecentFindingsAndArchivesInBatches() async throws {
        let client = MockURLProtocol.client(region: "eu-west-1") { req, _ in
            switch req.url!.path {
            case "/detector": return .init(body: #"{"detectorIds":["abc123"]}"#)
            case "/detector/abc123": return .init(body: #"{"status":"DISABLED"}"#)
            case "/detector/abc123/findings": return .init(body: #"{"findingIds":["f1"]}"#)
            case "/detector/abc123/findings/get": return .init(body: "{\"findings\":[\(Self.guardDutyFinding)]}")
            default: return .init(body: "{}")
            }
        }
        let gd = GuardDutyService(client: client)
        #expect(try await gd.detector() == .init(id: "abc123", enabled: false))
        let since = Date(timeIntervalSince1970: 1_486_685_375)
        let found = try await gd.findings(detectorId: "abc123", archived: true, updatedAfter: since)
        #expect(found.map(\.id) == ["f1"])
        let list = try #require(JSONSerialization.jsonObject(with: MockURLProtocol.requests[2].body) as? [String: Any])
        let criterion = list.dict("findingCriteria").dict("criterion")
        #expect(criterion.dict("service.archived")["eq"] as? [String] == ["true"])
        #expect(criterion.dict("updatedAt").number("gt") == 1_486_685_375_000)
        #expect(MockURLProtocol.requests[2].request.url?.host == "guardduty.eu-west-1.amazonaws.com")

        MockURLProtocol.requests = []
        let ids = (1...120).map { "f\($0)" }
        try await gd.archive(detectorId: "abc123", ids: ids)
        try await gd.unarchive(detectorId: "abc123", ids: ["f1"])
        let r = MockURLProtocol.requests
        #expect(r.map { $0.request.url!.path } == Array(repeating: "/detector/abc123/findings/archive", count: 3)
                + ["/detector/abc123/findings/unarchive"])
        let batches = r.compactMap { (try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?.strings("findingIds") }
        #expect(batches.map(\.count) == [50, 50, 20, 1])
        #expect(batches.dropLast().flatMap { $0 } == ids)
    }

    @Test func guardDutyWithoutADetectorHasNoFindings() async throws {
        let client = MockURLProtocol.client { _, _ in .init(body: #"{"detectorIds":[]}"#) }
        #expect(try await GuardDutyService(client: client).detector() == nil)
        #expect(try await GuardDutyService(client: client).findings().isEmpty)
        #expect(MockURLProtocol.requests.count == 2)
    }

    @Test func guardDutyFiltersBySeverityTypeResourceAndText() {
        func f(_ id: String, _ sev: Double, _ type: String, _ res: String, _ resId: String = "") -> GuardDutyFinding {
            GuardDutyFinding(id: id, title: "t-\(id)", description: "", severity: sev, type: type, resourceType: res,
                             resourceId: resId, region: "r", accountId: "a", updatedAt: nil)
        }
        let all = [f("a", 9.5, "Recon:EC2/PortProbe", "Instance", "i-1"), f("b", 5, "Recon:EC2/PortProbe", "S3Bucket"),
                   f("c", 7.5, "Trojan:EC2/DNS", "Instance", "i-2"), f("d", 2, "Policy:S3/Public", "S3Bucket", "logs")]
        #expect(GuardDutyFilter().apply(all).count == 4)
        #expect(GuardDutyFilter(severity: .high).apply(all).map(\.id) == ["c"])
        #expect(GuardDutyFilter(severity: .critical).apply(all).map(\.id) == ["a"])
        #expect(GuardDutyFilter(type: "Recon:EC2/PortProbe").apply(all).map(\.id) == ["a", "b"])
        #expect(GuardDutyFilter(type: "Recon:EC2/PortProbe", resourceType: "Instance").apply(all).map(\.id) == ["a"])
        #expect(GuardDutyFilter(search: " LOGS ").apply(all).map(\.id) == ["d"])
        #expect(GuardDutyFilter(search: "i-2").apply(all).map(\.id) == ["c"])
    }
}

/// GuardDuty desktop notifications against fixture responses: no real notification is posted.
@MainActor
@Suite(.serialized)
struct GuardDutyAlertsTests {
    private func finding(_ id: String, _ severity: Double) -> String {
        #"{"id":"\#(id)","title":"Finding \#(id)","severity":\#(severity),"type":"t","accountId":"1","resource":{"resourceType":"Instance"}}"#
    }

    /// GuardDuty with a detector whose recent findings are `ids()`.
    private func client(_ ids: @escaping () -> [(String, Double)]) -> AWSClient {
        MockURLProtocol.client { req, _ in
            switch req.url!.path {
            case "/detector": return .init(body: #"{"detectorIds":["d1"]}"#)
            case "/detector/d1/findings": return .init(body: "{\"findingIds\":[\(ids().map { "\"\($0.0)\"" }.joined(separator: ","))]}")
            default: return .init(body: "{\"findings\":[\(ids().map { self.finding($0.0, $0.1) }.joined(separator: ","))]}")
            }
        }
    }

    @Test func announcesEachNewFindingOnceEvenAfterARestart() async throws {
        let folder = TestTemp.root.appendingPathComponent("gd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var current: [(String, Double)] = [("old", 5)]
        let client = client { current }
        var posted: [(String, String)] = []
        func make() -> GuardDutyAlerts {
            GuardDutyAlerts(folder: folder, context: { .init(key: "acct|us-east-1", client: client) },
                            isEnabled: { true }, post: { posted.append(($0, $1)) })
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let alerts = make()
        // The first check only marks the starting point.
        #expect(await alerts.check(now: t0).isEmpty)
        #expect(MockURLProtocol.requests.isEmpty)

        current = [("old", 5), ("new", 8)]
        let first = await alerts.check(now: t0 + 120)
        #expect(first.map(\.id) == ["new", "old"])
        #expect(posted.count == 2)
        #expect(posted[0].0 == "GuardDuty · High severity")
        #expect(posted[0].1.hasPrefix("Finding new\nInstance"))
        let list = try #require(JSONSerialization.jsonObject(with: MockURLProtocol.requests[1].body) as? [String: Any])
        let gt = list.dict("findingCriteria").dict("criterion").dict("updatedAt").number("gt")
        #expect(gt == (t0.timeIntervalSince1970 - GuardDutyAlerts.overlap) * 1000)

        // A restart reads what was announced: nothing repeats.
        posted = []
        let restarted = make()
        #expect(restarted.memory == alerts.memory)
        #expect(await restarted.check(now: t0 + 240).isEmpty)
        #expect(posted.isEmpty)
        let saved = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("guardduty-alerts.json").path)
        #expect((saved[.posixPermissions] as? Int) == 0o600)
    }

    @Test func manyNewFindingsBecomeOneSummary() async {
        let folder = TestTemp.root.appendingPathComponent("gd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var current: [(String, Double)] = []
        let client = client { current }
        var posted: [(String, String)] = []
        let alerts = GuardDutyAlerts(folder: folder, context: { .init(key: "k", client: client) },
                                     isEnabled: { true }, post: { posted.append(($0, $1)) })
        await alerts.check(now: Date())
        current = [("a", 9.1), ("b", 7.2), ("c", 7.0), ("d", 1.5)]
        #expect(await alerts.check(now: Date()).count == 4)
        #expect(posted.count == 1)
        #expect(posted[0].0 == "4 new GuardDuty findings in us-east-1")
        #expect(posted[0].1 == "1 critical, 2 high, 1 low\nHighest: Finding a")
    }

    @Test func turnedOffOrFailingChecksAnnounceNothingAndKeepTheirStartingPoint() async {
        let folder = TestTemp.root.appendingPathComponent("gd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var enabled = false
        var posted = 0
        let failing = MockURLProtocol.client { _, _ in .init(status: 403, body: #"{"__type":"AccessDeniedException"}"#) }
        let alerts = GuardDutyAlerts(folder: folder, context: { .init(key: "k", client: failing) },
                                     isEnabled: { enabled }, post: { _, _ in posted += 1 })
        await alerts.check(now: Date(timeIntervalSince1970: 100))
        #expect(alerts.memory.isEmpty)
        enabled = true
        await alerts.check(now: Date(timeIntervalSince1970: 100))
        #expect(await alerts.check(now: Date(timeIntervalSince1970: 400)).isEmpty)
        #expect(alerts.memory["k"]?.lastCheck == Date(timeIntervalSince1970: 100))
        #expect(posted == 0)
    }
}

@MainActor
struct AppStateTests {
    private func makeState(_ folder: URL, _ secrets: InMemorySecretStore) -> AppState {
        AppState(store: AccountStore(folder: folder), secrets: secrets)
    }

    @Test func accountLifecycleIsPersistedOutsideTheKeychain() throws {
        let folder = TestTemp.root.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let secrets = InMemorySecretStore()

        let state = makeState(folder, secrets)
        #expect(state.accounts.isEmpty)
        #expect(state.page == .settings)

        try state.addAccount(name: "Prod", accessKeyId: "AKIA1", secret: "s1", region: "eu-west-1")
        try state.addAccount(name: "Dev", accessKeyId: "AKIA2", secret: "s2", region: "us-east-2")
        #expect(state.activeAccount?.name == "Prod")
        #expect(state.region == "eu-west-1")
        #expect(state.client?.credentials.secretAccessKey == "s1")

        let dev = state.accounts[1]
        state.setActive(dev.id)
        #expect(state.region == "us-east-2")
        #expect(state.client?.credentials.accessKeyId == "AKIA2")

        // Reload from disk: metadata persisted, secrets never written to the JSON file.
        let reloaded = makeState(folder, secrets)
        #expect(reloaded.accounts.map(\.name) == ["Prod", "Dev"])
        #expect(reloaded.activeAccount?.name == "Dev")
        let json = try String(contentsOf: folder.appendingPathComponent("accounts.json"), encoding: .utf8)
        #expect(!json.contains("s1") && !json.contains("s2"))

        reloaded.removeAccount(dev.id)
        #expect(reloaded.activeAccount?.name == "Prod")
        #expect(secrets.get(dev.id) == nil)
    }
}

