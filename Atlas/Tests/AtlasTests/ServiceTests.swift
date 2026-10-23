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
        #expect(findings[0].severityLabel == "HIGH")
        #expect(findings[1].resourceType == "Unknown")
        #expect(MockURLProtocol.requests.count == 4)
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
