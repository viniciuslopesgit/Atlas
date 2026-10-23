import Foundation

/// The AWS resource types Atlas can discover and turn into Terraform `import {}` blocks (same set as Atlas 1.0.1).
enum AwsResourceType: String, CaseIterable, Codable, Sendable, Identifiable {
    case ec2Instance, autoScalingGroup, launchTemplate
    case vpc, subnet, securityGroup, routeTable, internetGateway, natGateway, loadBalancer, targetGroup
    case s3Bucket
    case rdsInstance, rdsCluster, dynamoDbTable, elastiCacheCluster
    case lambdaFunction, apiGatewayRestApi
    case ecsCluster, ecsService, ecrRepository, eksCluster
    case sqsQueue, snsTopic
    case iamRole, iamUser, iamGroup, iamPolicy
    case kmsKey, secretsManagerSecret, acmCertificate
    case route53HostedZone
    case cloudWatchLogGroup, cloudWatchAlarm

    enum Category: String, CaseIterable, Sendable {
        case compute = "Compute", networking = "Networking", storage = "Storage", database = "Database"
        case serverless = "Serverless", containers = "Containers", messaging = "Messaging", iam = "IAM"
        case security = "Security", dns = "DNS", monitoring = "Monitoring"
    }

    var id: String { rawValue }

    var category: Category {
        switch self {
        case .ec2Instance, .autoScalingGroup, .launchTemplate: .compute
        case .vpc, .subnet, .securityGroup, .routeTable, .internetGateway, .natGateway, .loadBalancer, .targetGroup: .networking
        case .s3Bucket: .storage
        case .rdsInstance, .rdsCluster, .dynamoDbTable, .elastiCacheCluster: .database
        case .lambdaFunction, .apiGatewayRestApi: .serverless
        case .ecsCluster, .ecsService, .ecrRepository, .eksCluster: .containers
        case .sqsQueue, .snsTopic: .messaging
        case .iamRole, .iamUser, .iamGroup, .iamPolicy: .iam
        case .kmsKey, .secretsManagerSecret, .acmCertificate: .security
        case .route53HostedZone: .dns
        case .cloudWatchLogGroup, .cloudWatchAlarm: .monitoring
        }
    }

    var title: String {
        switch self {
        case .ec2Instance: "EC2 instances"
        case .autoScalingGroup: "Auto Scaling groups"
        case .launchTemplate: "Launch templates"
        case .vpc: "VPCs"
        case .subnet: "Subnets"
        case .securityGroup: "Security groups"
        case .routeTable: "Route tables"
        case .internetGateway: "Internet gateways"
        case .natGateway: "NAT gateways"
        case .loadBalancer: "Load balancers"
        case .targetGroup: "Target groups"
        case .s3Bucket: "S3 buckets"
        case .rdsInstance: "RDS instances"
        case .rdsCluster: "RDS clusters"
        case .dynamoDbTable: "DynamoDB tables"
        case .elastiCacheCluster: "ElastiCache clusters"
        case .lambdaFunction: "Lambda functions"
        case .apiGatewayRestApi: "API Gateway REST APIs"
        case .ecsCluster: "ECS clusters"
        case .ecsService: "ECS services"
        case .ecrRepository: "ECR repositories"
        case .eksCluster: "EKS clusters"
        case .sqsQueue: "SQS queues"
        case .snsTopic: "SNS topics"
        case .iamRole: "IAM roles"
        case .iamUser: "IAM users"
        case .iamGroup: "IAM groups"
        case .iamPolicy: "IAM policies (customer-managed)"
        case .kmsKey: "KMS keys"
        case .secretsManagerSecret: "Secrets Manager secrets"
        case .acmCertificate: "ACM certificates"
        case .route53HostedZone: "Route 53 hosted zones"
        case .cloudWatchLogGroup: "CloudWatch log groups"
        case .cloudWatchAlarm: "CloudWatch alarms"
        }
    }

    var terraformType: String {
        switch self {
        case .ec2Instance: "aws_instance"
        case .autoScalingGroup: "aws_autoscaling_group"
        case .launchTemplate: "aws_launch_template"
        case .vpc: "aws_vpc"
        case .subnet: "aws_subnet"
        case .securityGroup: "aws_security_group"
        case .routeTable: "aws_route_table"
        case .internetGateway: "aws_internet_gateway"
        case .natGateway: "aws_nat_gateway"
        case .loadBalancer: "aws_lb"
        case .targetGroup: "aws_lb_target_group"
        case .s3Bucket: "aws_s3_bucket"
        case .rdsInstance: "aws_db_instance"
        case .rdsCluster: "aws_rds_cluster"
        case .dynamoDbTable: "aws_dynamodb_table"
        case .elastiCacheCluster: "aws_elasticache_cluster"
        case .lambdaFunction: "aws_lambda_function"
        case .apiGatewayRestApi: "aws_api_gateway_rest_api"
        case .ecsCluster: "aws_ecs_cluster"
        case .ecsService: "aws_ecs_service"
        case .ecrRepository: "aws_ecr_repository"
        case .eksCluster: "aws_eks_cluster"
        case .sqsQueue: "aws_sqs_queue"
        case .snsTopic: "aws_sns_topic"
        case .iamRole: "aws_iam_role"
        case .iamUser: "aws_iam_user"
        case .iamGroup: "aws_iam_group"
        case .iamPolicy: "aws_iam_policy"
        case .kmsKey: "aws_kms_key"
        case .secretsManagerSecret: "aws_secretsmanager_secret"
        case .acmCertificate: "aws_acm_certificate"
        case .route53HostedZone: "aws_route53_zone"
        case .cloudWatchLogGroup: "aws_cloudwatch_log_group"
        case .cloudWatchAlarm: "aws_cloudwatch_metric_alarm"
        }
    }

    /// Discovery honours tag filters only for these types (EC2-family filters and S3 bucket tagging).
    var supportsTagFilters: Bool {
        switch self {
        case .ec2Instance, .launchTemplate, .vpc, .subnet, .securityGroup, .routeTable, .internetGateway,
             .natGateway, .s3Bucket: true
        default: false
        }
    }
}

struct TagFilter: Hashable, Codable, Sendable {
    var key: String
    /// nil matches any value of the key.
    var value: String?
}

struct ImportOptions: Sendable {
    /// nil uses the client's region.
    var region: String?
    var types: [AwsResourceType] = AwsResourceType.allCases
    var tagFilters: [TagFilter] = []
    var maxPerType = 200
    var includeTerminated = false
    var includeAwsManaged = false
    /// Restricts EC2 instance discovery to these ids (used to adopt instances Atlas just launched).
    var instanceIds: [String] = []
}

enum ImportConfidence: String, Sendable, Comparable {
    case high, medium, low

    static func < (a: Self, b: Self) -> Bool {
        let order: [Self] = [.high, .medium, .low]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

/// Atlas templates for resources whose HCL can be written without `-generate-config-out`.
enum SuggestedHcl: Sendable {
    case ec2(Ec2InstanceHcl)
    case s3(S3BucketHcl)
    case securityGroup(SecurityGroupHcl)
}

struct DiscoveredResource: Identifiable, Sendable {
    let type: AwsResourceType
    let awsId: String
    let name: String
    let region: String
    var tags: [String: String] = [:]
    var tfName: String
    let importId: String
    var confidence: ImportConfidence = .high
    var notes: [String] = []
    var hcl: SuggestedHcl?

    var id: String { "\(type.rawValue):\(awsId)" }
    var terraformType: String { type.terraformType }
    var address: String { "\(terraformType).\(tfName)" }
}

struct ImportAnalysis: Sendable {
    var region: String
    var resources: [DiscoveredResource] = []
    var partialErrors: [AwsResourceType: String] = [:]
    var duration: TimeInterval = 0

    var countByType: [AwsResourceType: Int] { resources.reduce(into: [:]) { $0[$1.type, default: 0] += 1 } }
    var needsReview: [DiscoveredResource] { resources.filter { $0.confidence == .low } }
}

// MARK: - Pure helpers (names, collisions, import blocks)

enum ImportDiscovery {
    /// Terraform-safe name: lowercase, `[a-z0-9_]`, no repeated or edge underscores, never starting with a digit.
    static func tfName(_ preferred: String, fallback: String) -> String {
        let raw = preferred.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : preferred
        var out = ""
        for c in raw.lowercased() {
            let ok = ("a"..."z").contains(c) || ("0"..."9").contains(c)
            if ok { out.append(c) } else if out.last != "_" { out.append("_") }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if let f = out.first, f.isNumber { out = "r_" + out }
        return out.isEmpty ? "resource" : out
    }

    /// Builds a resource; anything without a human name is only medium confidence.
    static func resource(_ type: AwsResourceType, awsId: String, name: String, tfName: String, importId: String,
                         region: String, tags: [String: String] = [:], notes: [String] = [],
                         hcl: SuggestedHcl? = nil, confidence: ImportConfidence = .high) -> DiscoveredResource {
        DiscoveredResource(type: type, awsId: awsId, name: name, region: region, tags: tags, tfName: tfName,
                           importId: importId, confidence: name.isEmpty ? .medium : confidence, notes: notes, hcl: hcl)
    }

    /// Dedupes by AWS id, orders by type then name and makes every Terraform address unique
    /// by appending the last 8 alphanumerics of the AWS id on a collision.
    static func resolve(_ found: [DiscoveredResource]) -> [DiscoveredResource] {
        var seen = Set<String>()
        let order = Dictionary(uniqueKeysWithValues: AwsResourceType.allCases.enumerated().map { ($1, $0) })
        let deduped = found.filter { seen.insert($0.awsId.lowercased()).inserted }
            .sorted { (order[$0.type]!, $0.name.lowercased()) < (order[$1.type]!, $1.name.lowercased()) }

        var used = Set<String>()
        return deduped.map { r in
            var r = r
            if !used.insert(r.address.lowercased()).inserted {
                let alnum = String(r.awsId.lowercased().filter { $0.isLetter || $0.isNumber })
                r.tfName += "_" + String(alnum.suffix(8))
                r.notes.append("Name disambiguated from collision with another \(r.terraformType)")
                used.insert(r.address.lowercased())
            }
            return r
        }
    }

    /// `imports.tf` content with Terraform 1.5+ `import {}` blocks; without the header for appending.
    static func importBlocks(_ resources: [DiscoveredResource], header: Bool = true) -> String {
        var out = !header ? "" : """
        # ──────────────────────────────────────────────────────────────────
        # Import blocks generated by Atlas · Terraform 1.5+ syntax
        # Run: terraform plan -generate-config-out=generated_resources.tf
        # ──────────────────────────────────────────────────────────────────


        """
        func comment(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
        for r in resources {
            out += "# \(r.type.title)  \(comment(r.awsId))\n"
            if !r.name.isEmpty { out += "# Name: \(comment(r.name))\n" }
            if !r.notes.isEmpty { out += "# Note: \(comment(r.notes.joined(separator: " | ")))\n" }
            out += "import {\n  to = \(r.address)\n  id = \(HclGenerator.quote(r.importId))\n}\n\n"
        }
        return out
    }

    /// Atlas-template HCL for the resources that have one, keyed by file name (the splitter's layout).
    /// Everything else is left to `terraform plan -generate-config-out`.
    static func suggestedFiles(_ resources: [DiscoveredResource]) -> [String: String] {
        var files: [String: [String]] = [:]
        for r in resources {
            switch r.hcl {
            case .ec2(let m): files["ec2.tf", default: []].append(HclGenerator.ec2Instance(m))
            case .s3(let m): files["s3.tf", default: []].append(HclGenerator.s3Bucket(m))
            case .securityGroup(let m): files["security_groups.tf", default: []].append(HclGenerator.securityGroup(m))
            case nil: break
            }
        }
        return files.mapValues { $0.joined(separator: "\n") }
    }
}

// MARK: - Discovery

/// Lists existing AWS resources, each type independently: a type that fails is reported in `partialErrors`.
struct ImportDiscoverer: Sendable {
    let client: AWSClient

    func discover(_ options: ImportOptions, progress: (@Sendable (String) -> Void)? = nil) async -> ImportAnalysis {
        let start = Date()
        let region = options.region.flatMap { $0.isEmpty ? nil : $0 } ?? client.region
        let regional = region == client.region ? client
            : AWSClient(credentials: client.credentials, region: region, session: client.session)
        let worker = Worker(client: regional, options: options)

        var analysis = ImportAnalysis(region: region)
        var found: [DiscoveredResource] = []
        await withTaskGroup(of: (AwsResourceType, Result<[DiscoveredResource], Error>).self) { group in
            for type in Set(options.types) {
                group.addTask {
                    progress?("Discovering \(type.title.lowercased())…")
                    do { return (type, .success(try await worker.discover(type))) } catch { return (type, .failure(error)) }
                }
            }
            for await (type, result) in group {
                switch result {
                case .success(let list):
                    found += list
                    progress?("\(type.title): \(list.count)")
                case .failure(let error):
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    analysis.partialErrors[type] = message
                    progress?("\(type.title): \(message)")
                }
            }
        }
        analysis.resources = ImportDiscovery.resolve(found)
        analysis.duration = Date().timeIntervalSince(start)
        return analysis
    }
}

private struct Worker: Sendable {
    let client: AWSClient
    let options: ImportOptions
    var region: String { client.region }
    var max: Int { Swift.max(1, options.maxPerType) }

    private func make(_ type: AwsResourceType, _ awsId: String, _ name: String, tf: String, importId: String,
                      region: String? = nil, tags: [String: String] = [:], notes: [String] = [],
                      hcl: SuggestedHcl? = nil, confidence: ImportConfidence = .high) -> DiscoveredResource {
        ImportDiscovery.resource(type, awsId: awsId, name: name, tfName: tf, importId: importId, region: region ?? self.region,
                                 tags: tags, notes: notes, hcl: hcl, confidence: confidence)
    }

    private func name(_ preferred: String, _ fallback: String) -> String { ImportDiscovery.tfName(preferred, fallback: fallback) }

    func discover(_ type: AwsResourceType) async throws -> [DiscoveredResource] {
        switch type {
        case .ec2Instance: try await ec2Instances()
        case .autoScalingGroup: try await autoScalingGroups()
        case .launchTemplate: try await ec2List("DescribeLaunchTemplates", "launchTemplates") { n, tags in
            let id = n.str("launchTemplateId"), ltName = n.str("launchTemplateName")
            return make(.launchTemplate, id, ltName, tf: name(ltName, id), importId: id, tags: tags)
        }
        case .vpc: try await ec2List("DescribeVpcs", "vpcSet") { n, tags in
            let id = n.str("vpcId"), isDefault = n.bool("isDefault")
            if isDefault && !options.includeAwsManaged { return nil }
            let tagName = tags["Name"] ?? ""
            return make(.vpc, id, tagName, tf: name(tagName, id), importId: id, tags: tags,
                        notes: (isDefault ? ["Default VPC."] : []) + ["CIDR: \(n.str("cidrBlock"))"])
        }
        case .subnet: try await ec2List("DescribeSubnets", "subnetSet") { n, tags in
            if n.bool("defaultForAz") && !options.includeAwsManaged { return nil }
            let id = n.str("subnetId"), tagName = tags["Name"] ?? ""
            return make(.subnet, id, tagName, tf: name(tagName, id), importId: id, tags: tags,
                        notes: ["AZ: \(n.str("availabilityZone"))", "CIDR: \(n.str("cidrBlock"))"])
        }
        case .securityGroup: try await ec2List("DescribeSecurityGroups", "securityGroupInfo", maxResults: 1000) { n, tags in
            securityGroup(n, tags)
        }
        case .routeTable: try await ec2List("DescribeRouteTables", "routeTableSet", maxResults: 100) { n, tags in
            if n.list("associationSet").contains(where: { $0.bool("main") }) && !options.includeAwsManaged { return nil }
            let id = n.str("routeTableId"), tagName = tags["Name"] ?? ""
            return make(.routeTable, id, tagName, tf: name(tagName, id), importId: id, tags: tags)
        }
        case .internetGateway: try await ec2List("DescribeInternetGateways", "internetGatewaySet", maxResults: 1000) { n, tags in
            let id = n.str("internetGatewayId"), tagName = tags["Name"] ?? ""
            return make(.internetGateway, id, tagName, tf: name(tagName, id), importId: id, tags: tags)
        }
        case .natGateway: try await ec2List("DescribeNatGateways", "natGatewaySet", maxResults: 1000) { n, tags in
            if ["deleted", "deleting", "failed"].contains(n.str("state")) { return nil }
            let id = n.str("natGatewayId"), tagName = tags["Name"] ?? ""
            return make(.natGateway, id, tagName, tf: name(tagName, id), importId: id, tags: tags)
        }
        case .loadBalancer: try await queryList(.elbv2, "DescribeLoadBalancers", ["PageSize": "400"], list: "LoadBalancers",
                                                token: ("Marker", "NextMarker")) { n in
            let arn = n.str("LoadBalancerArn"), lbName = n.str("LoadBalancerName")
            return make(.loadBalancer, arn, lbName, tf: name(lbName, arn), importId: arn,
                        notes: ["Type: \(n.str("Type"))", "Scheme: \(n.str("Scheme"))"])
        }
        case .targetGroup: try await queryList(.elbv2, "DescribeTargetGroups", ["PageSize": "400"], list: "TargetGroups",
                                               token: ("Marker", "NextMarker")) { n in
            let arn = n.str("TargetGroupArn"), tgName = n.str("TargetGroupName")
            return make(.targetGroup, arn, tgName, tf: name(tgName, arn), importId: arn)
        }
        case .s3Bucket: try await s3Buckets()
        case .rdsInstance: try await queryList(.rds, "DescribeDBInstances", ["MaxRecords": "100"], list: "DBInstances",
                                               item: "DBInstance", token: ("Marker", "Marker")) { n in
            let id = n.str("DBInstanceIdentifier")
            return make(.rdsInstance, id, id, tf: name(id, id), importId: id,
                        notes: ["Engine: \(n.str("Engine")) \(n.str("EngineVersion"))", "Class: \(n.str("DBInstanceClass"))",
                                "Status: \(n.str("DBInstanceStatus"))"])
        }
        case .rdsCluster: try await queryList(.rds, "DescribeDBClusters", ["MaxRecords": "100"], list: "DBClusters",
                                              item: "DBCluster", token: ("Marker", "Marker")) { n in
            let id = n.str("DBClusterIdentifier")
            return make(.rdsCluster, id, id, tf: name(id, id), importId: id,
                        notes: ["Engine: \(n.str("Engine")) \(n.str("EngineVersion"))", "Status: \(n.str("Status"))"])
        }
        case .elastiCacheCluster: try await queryList(.elastiCache, "DescribeCacheClusters", ["MaxRecords": "100"],
                                                      list: "CacheClusters", item: "CacheCluster", token: ("Marker", "Marker")) { n in
            let id = n.str("CacheClusterId")
            return make(.elastiCacheCluster, id, id, tf: name(id, id), importId: id,
                        notes: ["Engine: \(n.str("Engine")) \(n.str("EngineVersion"))", "Node type: \(n.str("CacheNodeType"))"])
        }
        case .snsTopic: try await queryList(.sns, "ListTopics", [:], list: "Topics", token: ("NextToken", "NextToken")) { n in
            let arn = n.str("TopicArn"), topic = arn.components(separatedBy: ":").last ?? arn
            return make(.snsTopic, arn, topic, tf: name(topic, topic), importId: arn)
        }
        case .cloudWatchAlarm: try await queryList(.cloudWatch, "DescribeAlarms", ["MaxRecords": "100"], list: "MetricAlarms",
                                                   token: ("NextToken", "NextToken")) { n in
            let alarm = n.str("AlarmName")
            return make(.cloudWatchAlarm, n.str("AlarmArn"), alarm, tf: name(alarm, n.str("AlarmArn")), importId: alarm)
        }
        case .iamRole: try await iamList("ListRoles", "Roles") { n in
            let role = n.str("RoleName")
            let managed = n.str("Path").hasPrefix("/aws-service-role/") || role.hasPrefix("AWSServiceRoleFor")
            if managed && !options.includeAwsManaged { return nil }
            return make(.iamRole, n.str("RoleId"), role, tf: name(role, role), importId: role, region: "global",
                        notes: managed ? ["AWS-managed service-linked role — import with caution."] : [],
                        confidence: managed ? .low : .high)
        }
        case .iamUser: try await iamList("ListUsers", "Users") { n in
            let user = n.str("UserName")
            return make(.iamUser, n.str("UserId"), user, tf: name(user, user), importId: user, region: "global",
                        notes: n.str("PasswordLastUsed").isEmpty ? ["User has never logged in via console."] : [])
        }
        case .iamGroup: try await iamList("ListGroups", "Groups") { n in
            let group = n.str("GroupName")
            return make(.iamGroup, n.str("GroupId"), group, tf: name(group, group), importId: group, region: "global")
        }
        case .iamPolicy: try await iamList("ListPolicies", "Policies", ["Scope": "Local"]) { n in
            let policy = n.str("PolicyName")
            return make(.iamPolicy, n.str("PolicyId"), policy, tf: name(policy, policy), importId: n.str("Arn"), region: "global")
        }
        case .dynamoDbTable: try await dynamoTables()
        case .lambdaFunction: try await lambdaFunctions()
        case .apiGatewayRestApi: try await restApis()
        case .ecsCluster: try await ecsClusters()
        case .ecsService: try await ecsServices()
        case .ecrRepository: try await jsonList(service: "ecr", host: "api.ecr.\(region).amazonaws.com",
                                                target: "AmazonEC2ContainerRegistry_V20150921.DescribeRepositories",
                                                body: ["maxResults": 1000], list: "repositories", token: ("nextToken", "nextToken")) { r in
            let repo = r.string("repositoryName")
            return make(.ecrRepository, r.string("repositoryArn"), repo, tf: name(repo, repo), importId: repo)
        }
        case .eksCluster: try await eksClusters()
        case .sqsQueue: try await sqsQueues()
        case .kmsKey: try await kmsKeys()
        case .secretsManagerSecret: try await jsonList(service: "secretsmanager", target: "secretsmanager.ListSecrets",
                                                       body: ["MaxResults": 100], list: "SecretList",
                                                       token: ("NextToken", "NextToken")) { s in
            let secret = s.string("Name"), arn = s.string("ARN")
            return make(.secretsManagerSecret, arn, secret, tf: name(secret, arn), importId: arn)
        }
        case .acmCertificate: try await jsonList(service: "acm", target: "CertificateManager.ListCertificates",
                                                 body: ["MaxItems": 100], list: "CertificateSummaryList",
                                                 token: ("NextToken", "NextToken")) { c in
            let domain = c.string("DomainName"), arn = c.string("CertificateArn")
            let pretty = domain.replacingOccurrences(of: "*.", with: "wildcard_").replacingOccurrences(of: ".", with: "_")
            return make(.acmCertificate, arn, domain, tf: name(pretty, arn), importId: arn)
        }
        case .route53HostedZone: try await hostedZones()
        case .cloudWatchLogGroup: try await jsonList(service: "logs", target: "Logs_20140328.DescribeLogGroups",
                                                     body: ["limit": 50], list: "logGroups", token: ("nextToken", "nextToken")) { g in
            let group = g.string("logGroupName")
            let pretty = group.replacingOccurrences(of: "/", with: "_")
            return make(.cloudWatchLogGroup, group, group, tf: name(pretty, group), importId: group)
        }
        }
    }

    // MARK: Pagination

    /// Calls `page` with the previous token until there is no next token or the type's limit is reached.
    private func paginate(_ list: inout [DiscoveredResource],
                          _ page: (String?, inout [DiscoveredResource]) async throws -> String?) async throws {
        var token: String?
        repeat {
            token = try await page(token, &list)
            if token?.isEmpty == true { token = nil }
        } while token != nil && list.count < max
        if list.count > max { list.removeLast(list.count - max) }
    }

    private func queryList(_ service: QueryService, _ action: String, _ params: [String: String], list path: String,
                           item: String = "member", token: (param: String, field: String),
                           _ map: (XNode) -> DiscoveredResource?) async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        try await paginate(&out) { next, out in
            var p = params
            if let next { p[token.param] = next }
            let result = try await client.query(service, action, p)["\(action)Result"]
            out += result?.list(path, item: item).compactMap(map) ?? []
            return result?.str(token.field)
        }
        return out
    }

    private func iamList(_ action: String, _ path: String, _ params: [String: String] = [:],
                         _ map: (XNode) -> DiscoveredResource?) async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        try await paginate(&out) { next, out in
            var p = params
            if let next { p["Marker"] = next }
            let result = try await client.query(.iam, action, p)["\(action)Result"]
            out += result?.list(path, item: "member").compactMap(map) ?? []
            return result?.bool("IsTruncated") == true ? result?.str("Marker") : nil
        }
        return out
    }

    private func jsonList(service: String, host: String? = nil, target: String, body: [String: Any], version: String = "1.1",
                          list key: String, token: (param: String, field: String),
                          _ map: ([String: Any]) -> DiscoveredResource?) async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        try await paginate(&out) { next, out in
            var b = body
            if let next { b[token.param] = next }
            let r = try await client.json(host: host ?? "\(service).\(region).amazonaws.com", signingName: service,
                                          signingRegion: region, target: target, body: b, version: version)
            out += r.array(key).compactMap(map)
            return r[token.field] as? String
        }
        return out
    }

    // MARK: EC2 family

    private static func tags(_ n: XNode) -> [String: String] {
        Dictionary(n.list("tagSet").map { ($0.str("key"), $0.str("value")) }, uniquingKeysWith: { a, _ in a })
    }

    /// `Filter.N` parameters for the tag filters plus any extra filters.
    private func ec2Filters(_ extra: [(String, [String])] = []) -> [String: String] {
        let tagFilters = options.tagFilters.map { f in
            f.value.map { ("tag:\(f.key)", [$0]) } ?? ("tag-key", [f.key])
        }
        var p: [String: String] = [:]
        for (i, f) in (tagFilters + extra).enumerated() {
            p["Filter.\(i + 1).Name"] = f.0
            for (j, v) in f.1.enumerated() { p["Filter.\(i + 1).Value.\(j + 1)"] = v }
        }
        return p
    }

    private func ec2List(_ action: String, _ path: String, maxResults: Int? = nil,
                         _ map: (XNode, [String: String]) -> DiscoveredResource?) async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        try await paginate(&out) { next, out in
            var p = ec2Filters()
            if let maxResults { p["MaxResults"] = String(maxResults) }
            if let next { p["NextToken"] = next }
            let xml = try await client.query(.ec2, action, p)
            out += xml.list(path).compactMap { map($0, Self.tags($0)) }
            return xml.str("nextToken")
        }
        return out
    }

    private func ec2Instances() async throws -> [DiscoveredResource] {
        let states = options.includeTerminated ? []
            : [("instance-state-name", ["pending", "running", "shutting-down", "stopping", "stopped"])]
        var instances: [XNode] = []
        var token: String?
        repeat {
            var p = ec2Filters(states)
            if options.instanceIds.isEmpty {
                p["MaxResults"] = String(min(Swift.max(max, 5), 1000))
            } else {
                for (n, id) in options.instanceIds.enumerated() { p["InstanceId.\(n + 1)"] = id }
            }
            if let token { p["NextToken"] = token }
            let xml = try await client.query(.ec2, "DescribeInstances", p)
            for res in xml.list("reservationSet") { instances += res.list("instancesSet") }
            token = xml.str("nextToken").isEmpty ? nil : xml.str("nextToken")
        } while token != nil && instances.count < max
        instances = Array(instances.prefix(max))

        let roots = await rootVolumes(instances)
        return instances.map { i in
            let id = i.str("instanceId"), tags = Self.tags(i), tagName = tags["Name"] ?? ""
            let tf = name(tagName, id)
            var m = Ec2InstanceHcl()
            m.resourceName = tf
            m.amiId = i.str("imageId")
            m.instanceType = i.str("instanceType")
            m.subnetId = i.str("subnetId").nilIfEmpty
            m.keyName = i.str("keyName").nilIfEmpty
            m.associatePublicIp = !i.str("ipAddress").isEmpty
            m.securityGroupIds = i.list("groupSet").map { $0.str("groupId") }
            m.iamInstanceProfile = i.str("iamInstanceProfile/arn").components(separatedBy: "/").last?.nilIfEmpty
            m.monitoring = i.str("monitoring/state") == "enabled"
            if let root = roots[id] {
                if root.size > 0 { m.rootVolumeGb = root.size }
                if !root.type.isEmpty { m.rootVolumeType = root.type }
            }
            m.nameTag = tagName.nilIfEmpty
            m.tags = tags.filter { $0.key != "Name" }.sorted { $0.key < $1.key }.map { HclTag(key: $0.key, value: $0.value) }

            var notes: [String] = []
            if i.str("instanceState/name") == "stopped" { notes.append("Instance is currently stopped.") }
            if i.str("keyName").isEmpty { notes.append("No key pair — SSH via SSM only.") }
            if i.str("iamInstanceProfile/arn").isEmpty { notes.append("No IAM instance profile.") }
            if i.str("metadataOptions/httpTokens") == "optional" { notes.append("IMDSv1 enabled (IMDSv2 recommended).") }
            return make(.ec2Instance, id, tagName, tf: tf, importId: id, tags: tags, notes: notes, hcl: .ec2(m))
        }
    }

    /// Live root volume size and type, so the suggested HCL never tries to shrink an EBS volume. Best effort.
    private func rootVolumes(_ instances: [XNode]) async -> [String: (size: Int, type: String)] {
        var volumeToInstance: [String: String] = [:]
        for i in instances {
            let root = i.str("rootDeviceName")
            if let v = i.list("blockDeviceMappingSet").first(where: { $0.str("deviceName") == root })?.str("ebs/volumeId"),
               !v.isEmpty { volumeToInstance[v] = i.str("instanceId") }
        }
        var out: [String: (Int, String)] = [:]
        let ids = Array(volumeToInstance.keys).sorted()
        for start in stride(from: 0, to: ids.count, by: 200) {
            var p: [String: String] = [:]
            for (n, v) in ids[start..<min(start + 200, ids.count)].enumerated() { p["VolumeId.\(n + 1)"] = v }
            guard let xml = try? await client.query(.ec2, "DescribeVolumes", p) else { return out }
            for v in xml.list("volumeSet") {
                if let instance = volumeToInstance[v.str("volumeId")] { out[instance] = (v.int("size") ?? 0, v.str("volumeType")) }
            }
        }
        return out
    }

    private func securityGroup(_ n: XNode, _ tags: [String: String]) -> DiscoveredResource? {
        let id = n.str("groupId"), groupName = n.str("groupName")
        if groupName == "default" && !options.includeAwsManaged { return nil }
        let display = tags["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? groupName
        let tf = name(display, id)

        var skipped = 0
        func rules(_ path: String) -> [SecurityGroupHcl.Rule] {
            n.list(path).compactMap { p in
                let v4 = p.list("ipRanges"), v6 = p.list("ipv6Ranges")
                let cidrs = v4.map { $0.str("cidrIp") } + v6.map { $0.str("cidrIpv6") }
                // Rules that only reference other groups or prefix lists have no CIDR: never widen them to 0.0.0.0/0.
                guard !cidrs.isEmpty else { skipped += 1; return nil }
                let proto = p.str("ipProtocol")
                return SecurityGroupHcl.Rule(description: (v4 + v6).first?.str("description") ?? "",
                                             fromPort: p.int("fromPort") ?? 0, toPort: p.int("toPort") ?? 0,
                                             proto: proto, cidrBlocks: cidrs)
            }
        }
        var m = SecurityGroupHcl()
        m.resourceName = tf
        m.name = groupName
        m.description = n.str("groupDescription")
        m.vpcId = n.str("vpcId").nilIfEmpty
        m.ingress = rules("ipPermissions")
        m.egress = rules("ipPermissionsEgress")
        m.tags = tags.sorted { $0.key < $1.key }.map { HclTag(key: $0.key, value: $0.value) }
        let notes = skipped > 0 ? ["\(skipped) rule(s) reference other security groups or prefix lists and are left to Terraform's generated config."] : []
        return make(.securityGroup, id, display, tf: tf, importId: id, tags: tags, notes: notes, hcl: .securityGroup(m))
    }

    private func autoScalingGroups() async throws -> [DiscoveredResource] {
        try await queryList(.autoScaling, "DescribeAutoScalingGroups", ["MaxRecords": "100"], list: "AutoScalingGroups",
                            token: ("NextToken", "NextToken")) { g in
            let asg = g.str("AutoScalingGroupName")
            let tags = Dictionary(g.list("Tags", item: "member").map { ($0.str("Key"), $0.str("Value")) }, uniquingKeysWith: { a, _ in a })
            return make(.autoScalingGroup, asg, asg, tf: name(asg, asg), importId: asg, tags: tags)
        }
    }

    // MARK: S3

    private func s3Buckets() async throws -> [DiscoveredResource] {
        let (data, _) = try await client.s3(method: "GET", bucket: nil)
        let buckets = XNode.parse(data)?.list("Buckets", item: "Bucket").map { $0.str("Name") } ?? []
        var out: [DiscoveredResource] = []
        for bucket in buckets where out.count < max {
            var tags: [String: String] = [:]
            if !options.tagFilters.isEmpty {
                do {
                    let (tagData, _) = try await client.s3(method: "GET", bucket: bucket, query: [("tagging", "")])
                    let set = XNode.parse(tagData)?.list("TagSet", item: "Tag") ?? []
                    tags = Dictionary(set.map { ($0.str("Key"), $0.str("Value")) }, uniquingKeysWith: { a, _ in a })
                } catch let e as AWSError where e.code == "NoSuchTagSet" { continue }
                if !matches(tags) { continue }
            }
            let tf = name(bucket, bucket)
            // Import mode: a minimal model with only the real tags. Sub-resources (public access block,
            // encryption) would create drift when they don't match the bucket's actual configuration.
            var m = S3BucketHcl()
            m.resourceName = tf
            m.bucketName = bucket
            m.blockPublicAcls = false
            m.blockPublicPolicy = false
            m.ignorePublicAcls = false
            m.restrictPublicBuckets = false
            m.serverSideEncryption = false
            m.tags = tags.sorted { $0.key < $1.key }.map { HclTag(key: $0.key, value: $0.value) }
            out.append(make(.s3Bucket, bucket, bucket, tf: tf, importId: bucket, tags: tags, hcl: .s3(m)))
        }
        return out
    }

    private func matches(_ tags: [String: String]) -> Bool {
        options.tagFilters.allSatisfy { f in
            guard let v = tags.first(where: { $0.key.caseInsensitiveCompare(f.key) == .orderedSame })?.value else { return false }
            return f.value.map { v.caseInsensitiveCompare($0) == .orderedSame } ?? true
        }
    }

    // MARK: JSON services

    private func dynamoTables() async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        try await paginate(&out) { next, out in
            var body: [String: Any] = ["Limit": 100]
            if let next { body["ExclusiveStartTableName"] = next }
            let r = try await client.json(host: "dynamodb.\(region).amazonaws.com", signingName: "dynamodb", signingRegion: region,
                                          target: "DynamoDB_20120810.ListTables", body: body, version: "1.0")
            out += r.strings("TableNames").map { make(.dynamoDbTable, $0, $0, tf: name($0, $0), importId: $0) }
            return r["LastEvaluatedTableName"] as? String
        }
        return out
    }

    /// ListQueues returns plain URL strings, so it has its own loop.
    private func sqsQueues() async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        try await paginate(&out) { next, out in
            var body: [String: Any] = ["MaxResults": 1000]
            if let next { body["NextToken"] = next }
            let r = try await client.json(host: "sqs.\(region).amazonaws.com", signingName: "sqs", signingRegion: region,
                                          target: "AmazonSQS.ListQueues", body: body, version: "1.0")
            out += r.strings("QueueUrls").map { url in
                let queue = url.components(separatedBy: "/").last ?? url
                return make(.sqsQueue, url, queue, tf: name(queue, queue), importId: url)
            }
            return r["NextToken"] as? String
        }
        return out
    }

    private func ecs(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await client.json(host: "ecs.\(region).amazonaws.com", signingName: "ecs", signingRegion: region,
                              target: "AmazonEC2ContainerServiceV20141113.\(action)", body: body)
    }

    private func clusterArns() async throws -> [String] {
        var arns: [String] = []
        var token: String?
        repeat {
            var body: [String: Any] = ["maxResults": 100]
            if let token { body["nextToken"] = token }
            let r = try await ecs("ListClusters", body)
            arns += r.strings("clusterArns")
            token = r["nextToken"] as? String
        } while token != nil && arns.count < max
        return arns
    }

    private func ecsClusters() async throws -> [DiscoveredResource] {
        let arns = try await clusterArns()
        var out: [DiscoveredResource] = []
        for start in stride(from: 0, to: arns.count, by: 100) where out.count < max {
            let r = try await ecs("DescribeClusters", ["clusters": Array(arns[start..<min(start + 100, arns.count)]), "include": ["TAGS"]])
            for c in r.array("clusters") where c.string("status") != "INACTIVE" && out.count < max {
                let cluster = c.string("clusterName"), arn = c.string("clusterArn")
                let tags = Dictionary(c.array("tags").map { ($0.string("key"), $0.string("value")) }, uniquingKeysWith: { a, _ in a })
                out.append(make(.ecsCluster, arn, cluster, tf: name(cluster, cluster), importId: arn, tags: tags))
            }
        }
        return out
    }

    private func ecsServices() async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        for clusterArn in try await clusterArns() where out.count < max {
            let cluster = clusterArn.components(separatedBy: "/").last ?? clusterArn
            var token: String?
            repeat {
                var body: [String: Any] = ["cluster": clusterArn, "maxResults": 100]
                if let token { body["nextToken"] = token }
                let r = try await ecs("ListServices", body)
                for arn in r.strings("serviceArns") where out.count < max {
                    let service = arn.components(separatedBy: "/").last ?? arn
                    // aws_ecs_service imports as cluster/service.
                    out.append(make(.ecsService, arn, service, tf: name("\(cluster)_\(service)", arn),
                                    importId: "\(cluster)/\(service)"))
                }
                token = r["nextToken"] as? String
            } while token != nil && out.count < max
        }
        return out
    }

    private func kmsKeys() async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        var marker: String?
        repeat {
            var body: [String: Any] = ["Limit": 100]
            if let marker { body["Marker"] = marker }
            let r = try await client.json(host: "kms.\(region).amazonaws.com", signingName: "kms", signingRegion: region,
                                          target: "TrentService.ListKeys", body: body)
            for k in r.array("Keys") where out.count < max {
                let meta = try await client.json(host: "kms.\(region).amazonaws.com", signingName: "kms", signingRegion: region,
                                                 target: "TrentService.DescribeKey", body: ["KeyId": k.string("KeyId")]).dict("KeyMetadata")
                if meta.string("KeyManager") == "AWS" || meta.string("KeyState") == "PendingDeletion" { continue }
                let keyId = meta.string("KeyId"), desc = meta.string("Description")
                out.append(make(.kmsKey, keyId, desc, tf: name(desc, keyId), importId: keyId,
                                notes: ["Usage: \(meta.string("KeyUsage"))", "State: \(meta.string("KeyState"))"]))
            }
            marker = (r["Truncated"] as? Bool) == true ? r["NextMarker"] as? String : nil
        } while marker != nil && out.count < max
        return out
    }

    // MARK: REST services

    private func lambdaFunctions() async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        try await paginate(&out) { next, out in
            var q = [("MaxItems", "50")]
            if let next { q.append(("Marker", next)) }
            let r = try await client.restJSON(method: "GET", host: "lambda.\(region).amazonaws.com", signingName: "lambda",
                                              path: "/2015-03-31/functions/", query: q)
            out += r.array("Functions").map { f in
                let fn = f.string("FunctionName")
                return make(.lambdaFunction, f.string("FunctionArn"), fn, tf: name(fn, fn), importId: fn,
                            notes: ["Runtime: \(f.string("Runtime"))", "Memory: \(Int(f.number("MemorySize")))MB"])
            }
            return r["NextMarker"] as? String
        }
        return out
    }

    private func restApis() async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        try await paginate(&out) { next, out in
            var q = [("limit", "500")]
            if let next { q.append(("position", next)) }
            let r = try await client.restJSON(method: "GET", host: "apigateway.\(region).amazonaws.com", signingName: "apigateway",
                                              path: "/restapis", query: q)
            out += r.array("item").map { api in
                let id = api.string("id"), apiName = api.string("name")
                return make(.apiGatewayRestApi, id, apiName, tf: name(apiName, id), importId: id)
            }
            return r["position"] as? String
        }
        return out
    }

    private func eksClusters() async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        try await paginate(&out) { next, out in
            var q = [("maxResults", "100")]
            if let next { q.append(("nextToken", next)) }
            let r = try await client.restJSON(method: "GET", host: "eks.\(region).amazonaws.com", signingName: "eks",
                                              path: "/clusters", query: q)
            out += r.strings("clusters").map { make(.eksCluster, $0, $0, tf: name($0, $0), importId: $0) }
            return r["nextToken"] as? String
        }
        return out
    }

    private func hostedZones() async throws -> [DiscoveredResource] {
        var out: [DiscoveredResource] = []
        try await paginate(&out) { next, out in
            var q = [("maxitems", "100")]
            if let next { q.append(("marker", next)) }
            let xml = try await client.restXML(host: "route53.amazonaws.com", signingName: "route53", signingRegion: "us-east-1",
                                               path: "/2013-04-01/hostedzone", query: q)
            out += xml.list("HostedZones", item: "HostedZone").map { z in
                let zone = z.str("Name").hasSuffix(".") ? String(z.str("Name").dropLast()) : z.str("Name")
                let id = z.str("Id").components(separatedBy: "/").last ?? z.str("Id")
                return make(.route53HostedZone, id, zone, tf: name(zone.replacingOccurrences(of: ".", with: "_"), id), importId: id,
                            region: "global", notes: [z.bool("Config/PrivateZone") ? "Private zone" : "Public zone"])
            }
            return xml.bool("IsTruncated") ? xml.str("NextMarker") : nil
        }
        return out
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
