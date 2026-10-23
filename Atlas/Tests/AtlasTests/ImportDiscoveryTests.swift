import Foundation
import Testing
@testable import Atlas

struct ImportNamingTests {
    @Test func tfNamesAreTerraformSafe() {
        #expect(ImportDiscovery.tfName("My App-01.prod", fallback: "x") == "my_app_01_prod")
        #expect(ImportDiscovery.tfName("123-web", fallback: "x") == "r_123_web")
        #expect(ImportDiscovery.tfName("  ", fallback: "i-0abc") == "i_0abc")
        #expect(ImportDiscovery.tfName("--//--", fallback: "x") == "resource")
        #expect(ImportDiscovery.tfName("/aws/lambda/fn", fallback: "x") == "aws_lambda_fn")
    }

    @Test func resolveDedupesAndDisambiguatesCollisions() {
        let a = ImportDiscovery.resource(.acmCertificate, awsId: "arn:aws:acm:eu-west-1:1:certificate/aaaa-11112222",
                                         name: "*.example.com", tfName: "wildcard_example_com", importId: "a", region: "eu-west-1")
        let b = ImportDiscovery.resource(.acmCertificate, awsId: "arn:aws:acm:eu-west-1:1:certificate/bbbb-33334444",
                                         name: "*.example.com", tfName: "wildcard_example_com", importId: "b", region: "eu-west-1")
        let vpc = ImportDiscovery.resource(.vpc, awsId: "vpc-1", name: "", tfName: "vpc_1", importId: "vpc-1", region: "eu-west-1")
        let out = ImportDiscovery.resolve([a, b, a, vpc])

        #expect(out.count == 3)
        #expect(out.first?.type == .vpc, "ordered by type like 1.0.1")
        #expect(out.first?.confidence == .medium, "no name → medium confidence")
        #expect(Set(out.map(\.address)).count == 3)
        #expect(out.contains { $0.tfName == "wildcard_example_com_33334444" && $0.notes.last?.contains("collision") == true })
    }

    @Test func importBlocksQuoteIdsAndCommentNames() {
        var r = ImportDiscovery.resource(.s3Bucket, awsId: "logs", name: "logs\nbucket", tfName: "logs", importId: "logs",
                                         region: "us-east-1")
        r.notes = ["one", "two"]
        let hcl = ImportDiscovery.importBlocks([r])
        #expect(hcl.contains("import {\n  to = aws_s3_bucket.logs\n  id = \"logs\"\n}"))
        #expect(hcl.contains("# Name: logs bucket"))
        #expect(hcl.contains("# Note: one | two"))
    }
}

// MARK: - Discovery against mocked AWS endpoints

private func header(_ r: URLRequest, _ name: String) -> String { r.value(forHTTPHeaderField: name) ?? "" }

private func awsMock() -> AWSClient {
    MockURLProtocol.client(region: "eu-west-1") { req, body in
        let host = req.url?.host ?? ""
        let target = header(req, "x-amz-target")
        let action = formParams(body)["Action"] ?? ""
        switch (host, action, target) {
        case ("ec2.eu-west-1.amazonaws.com", "DescribeInstances", _):
            return .init(body: """
            <DescribeInstancesResponse><reservationSet><item><instancesSet><item>
              <instanceId>i-0abc</instanceId><imageId>ami-1</imageId><instanceType>t3.small</instanceType>
              <instanceState><name>stopped</name></instanceState><rootDeviceName>/dev/xvda</rootDeviceName>
              <blockDeviceMappingSet><item><deviceName>/dev/xvda</deviceName><ebs><volumeId>vol-1</volumeId></ebs></item></blockDeviceMappingSet>
              <groupSet><item><groupId>sg-1</groupId></item></groupSet>
              <metadataOptions><httpTokens>optional</httpTokens></metadataOptions>
              <tagSet><item><key>Name</key><value>Web Server</value></item><item><key>env</key><value>prod</value></item></tagSet>
            </item></instancesSet></item></reservationSet></DescribeInstancesResponse>
            """)
        case ("ec2.eu-west-1.amazonaws.com", "DescribeVolumes", _):
            return .init(body: "<DescribeVolumesResponse><volumeSet><item><volumeId>vol-1</volumeId><size>50</size><volumeType>gp2</volumeType></item></volumeSet></DescribeVolumesResponse>")
        case ("ec2.eu-west-1.amazonaws.com", "DescribeSecurityGroups", _):
            return .init(body: """
            <DescribeSecurityGroupsResponse><securityGroupInfo>
              <item><groupId>sg-1</groupId><groupName>web</groupName><groupDescription>web</groupDescription>
                <ipPermissions>
                  <item><ipProtocol>tcp</ipProtocol><fromPort>443</fromPort><toPort>443</toPort>
                    <ipRanges><item><cidrIp>10.0.0.0/8</cidrIp></item></ipRanges></item>
                  <item><ipProtocol>tcp</ipProtocol><fromPort>5432</fromPort><toPort>5432</toPort>
                    <groups><item><groupId>sg-2</groupId></item></groups></item>
                </ipPermissions></item>
              <item><groupId>sg-0</groupId><groupName>default</groupName></item>
            </securityGroupInfo></DescribeSecurityGroupsResponse>
            """)
        case ("dynamodb.eu-west-1.amazonaws.com", _, "DynamoDB_20120810.ListTables"):
            guard header(req, "Content-Type") == "application/x-amz-json-1.0" else { return .init(status: 400) }
            return .init(body: #"{"TableNames":["orders"]}"#)
        case ("lambda.eu-west-1.amazonaws.com", _, _):
            return .init(body: #"{"Functions":[{"FunctionName":"resize","FunctionArn":"arn:aws:lambda:eu-west-1:1:function:resize","Runtime":"python3.12","MemorySize":256}]}"#)
        case ("route53.amazonaws.com", _, _):
            return .init(body: """
            <ListHostedZonesResponse><HostedZones><HostedZone><Id>/hostedzone/Z123</Id><Name>example.com.</Name>
            <Config><PrivateZone>false</PrivateZone></Config></HostedZone></HostedZones><IsTruncated>false</IsTruncated></ListHostedZonesResponse>
            """)
        case ("iam.amazonaws.com", "ListRoles", _):
            return .init(body: """
            <ListRolesResponse><ListRolesResult><IsTruncated>false</IsTruncated><Roles>
              <member><RoleName>app-role</RoleName><RoleId>AROA1</RoleId><Path>/</Path></member>
              <member><RoleName>AWSServiceRoleForSupport</RoleName><RoleId>AROA2</RoleId><Path>/aws-service-role/</Path></member>
            </Roles></ListRolesResult></ListRolesResponse>
            """)
        case ("elasticloadbalancing.eu-west-1.amazonaws.com", _, _):
            return .init(status: 403, body: "<ErrorResponse><Error><Code>AccessDenied</Code><Message>not allowed</Message></Error></ErrorResponse>")
        default:
            return .init(status: 500, body: "unexpected \(host) \(action) \(target)")
        }
    }
}

extension ServiceTests {
    @Test func discoveryCoversEveryProtocolAndCollectsPartialErrors() async throws {
        var options = ImportOptions()
        options.types = [.ec2Instance, .securityGroup, .dynamoDbTable, .lambdaFunction, .route53HostedZone, .iamRole, .loadBalancer]
        let analysis = await ImportDiscoverer(client: awsMock()).discover(options)

        #expect(analysis.partialErrors.keys.sorted { $0.rawValue < $1.rawValue } == [.loadBalancer])
        #expect(analysis.partialErrors[.loadBalancer]?.contains("AccessDenied") == true)

        let byType = Dictionary(grouping: analysis.resources, by: \.type)
        let ec2 = try #require(byType[.ec2Instance]?.first)
        #expect(ec2.address == "aws_instance.web_server")
        #expect(ec2.notes.contains("Instance is currently stopped."))
        #expect(ec2.notes.contains("IMDSv1 enabled (IMDSv2 recommended)."))
        guard case .ec2(let m) = ec2.hcl else { Issue.record("EC2 has no suggested HCL"); return }
        #expect(m.rootVolumeGb == 50 && m.rootVolumeType == "gp2", "live root volume is used")
        #expect(m.tags == [HclTag(key: "env", value: "prod")])

        let sgs = try #require(byType[.securityGroup])
        #expect(sgs.map(\.importId) == ["sg-1"], "default group skipped")
        guard case .securityGroup(let sg) = sgs[0].hcl else { Issue.record("SG has no suggested HCL"); return }
        #expect(sg.ingress.map(\.cidrBlocks) == [["10.0.0.0/8"]], "group-reference rules are never widened to 0.0.0.0/0")
        #expect(sgs[0].notes.first?.contains("1 rule(s)") == true)

        #expect(byType[.dynamoDbTable]?.map(\.address) == ["aws_dynamodb_table.orders"])
        #expect(byType[.lambdaFunction]?.first?.importId == "resize")
        #expect(byType[.lambdaFunction]?.first?.notes == ["Runtime: python3.12", "Memory: 256MB"])
        #expect(byType[.route53HostedZone]?.first?.importId == "Z123")
        #expect(byType[.route53HostedZone]?.first?.tfName == "example_com")
        #expect(byType[.iamRole]?.map(\.importId) == ["app-role"], "service-linked roles skipped by default")

        let files = ImportDiscovery.suggestedFiles(analysis.resources)
        #expect(Set(files.keys) == ["ec2.tf", "security_groups.tf"])
        #expect(files["ec2.tf"]?.contains("resource \"aws_instance\" \"web_server\"") == true)
    }

    @Test func ec2TagFiltersAndStateFilterAreSent() async throws {
        var options = ImportOptions()
        options.types = [.ec2Instance]
        options.tagFilters = [TagFilter(key: "env", value: "prod"), TagFilter(key: "team")]
        _ = await ImportDiscoverer(client: awsMock()).discover(options)

        let p = try #require(MockURLProtocol.requests.map { formParams($0.body) }.first { $0["Action"] == "DescribeInstances" })
        #expect(p["Filter.1.Name"] == "tag:env" && p["Filter.1.Value.1"] == "prod")
        #expect(p["Filter.2.Name"] == "tag-key" && p["Filter.2.Value.1"] == "team")
        #expect(p["Filter.3.Name"] == "instance-state-name" && p["Filter.3.Value.5"] == "stopped")
    }

    @Test func discoveryUsesTheRequestedRegion() async throws {
        var options = ImportOptions()
        options.types = [.dynamoDbTable]
        options.region = "us-west-2"
        let analysis = await ImportDiscoverer(client: awsMock()).discover(options)
        #expect(analysis.region == "us-west-2")
        #expect(MockURLProtocol.requests.first?.request.url?.host == "dynamodb.us-west-2.amazonaws.com")
    }
}
