import Foundation

// MARK: - Accounts & regions

struct AwsAccount: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var accessKeyId: String
    var defaultRegion: String = "us-east-1"
    var createdAt: Date = Date()
    var isActive: Bool = false
}

struct RegionItem: Identifiable, Hashable {
    let code: String
    let display: String
    var id: String { code }

    static let all: [RegionItem] = [
        .init(code: "us-east-1", display: "US East (N. Virginia)"),
        .init(code: "us-east-2", display: "US East (Ohio)"),
        .init(code: "us-west-1", display: "US West (N. California)"),
        .init(code: "us-west-2", display: "US West (Oregon)"),
        .init(code: "ca-central-1", display: "Canada (Central)"),
        .init(code: "eu-west-1", display: "Europe (Ireland)"),
        .init(code: "eu-west-2", display: "Europe (London)"),
        .init(code: "eu-west-3", display: "Europe (Paris)"),
        .init(code: "eu-central-1", display: "Europe (Frankfurt)"),
        .init(code: "eu-north-1", display: "Europe (Stockholm)"),
        .init(code: "ap-southeast-1", display: "Asia Pacific (Singapore)"),
        .init(code: "ap-southeast-2", display: "Asia Pacific (Sydney)"),
        .init(code: "ap-northeast-1", display: "Asia Pacific (Tokyo)"),
        .init(code: "ap-northeast-2", display: "Asia Pacific (Seoul)"),
        .init(code: "ap-south-1", display: "Asia Pacific (Mumbai)"),
        .init(code: "sa-east-1", display: "South America (São Paulo)"),
    ]

    static func displayName(_ code: String) -> String { all.first { $0.code == code }?.display ?? code }
}

// MARK: - EC2

struct Ec2Instance: Identifiable, Hashable {
    var id: String { instanceId }

    // Core
    var instanceId = ""
    var name = ""
    var instanceType = ""
    var state = ""
    var publicIpAddress = "—"
    var privateIpAddress = "—"
    var region = ""
    var launchTime: Date?

    // Summary
    var ipv6Address = "—"
    var publicDnsName = "—"
    var privateDnsName = "—"
    var vpcId = "—"
    var subnetId = "—"
    var iamInstanceProfileName = "—"
    var iamInstanceProfileArn = ""
    var metadataHttpTokens = "—"
    var instanceArn = ""
    var autoScalingGroupName = "—"
    var ownerId = "—"
    var reservationId = "—"

    // Details
    var imageId = "—"
    var monitoringState = "—"
    var platformDetails = "—"
    var keyName = "—"
    var virtualizationType = "—"
    var lifecycle = "normal"
    var usageOperation = "—"
    var bootMode = "—"
    var currentInstanceBootMode = "—"
    var amiLaunchIndex = 0
    var stateTransitionReason = "—"
    var stateReasonMessage = "—"
    var hibernationEnabled = false

    // Placement
    var availabilityZone = "—"
    var placementGroup = "—"
    var placementGroupId = "—"
    var tenancy = "—"
    var hostId = "—"
    var affinity = "—"
    var partitionNumber: Int?
    var vCpuCount = 0

    // Capacity reservation
    var capacityReservationId = "—"
    var capacityReservationPreference = "—"

    var tags: [String: String] = [:]
}

struct MetricPoint: Identifiable, Hashable {
    let timestamp: Date
    let value: Double
    var id: Date { timestamp }
}

struct Ec2InstanceMetrics {
    var cpu: [MetricPoint] = []
    var networkIn: [MetricPoint] = []
    var networkOut: [MetricPoint] = []
    var diskWrite: [MetricPoint] = []
}

struct VpcInfo: Identifiable, Hashable {
    let vpcId: String
    let cidrBlock: String
    let isDefault: Bool
    let name: String
    var id: String { vpcId }
    var display: String { "\(vpcId)\(name.isEmpty ? "" : " (\(name))") — \(cidrBlock)\(isDefault ? " · default" : "")" }
}

struct SubnetInfo: Identifiable, Hashable {
    let subnetId: String
    let vpcId: String
    let availabilityZone: String
    let cidrBlock: String
    let isDefault: Bool
    let name: String
    var id: String { subnetId }
    var display: String { "\(subnetId) · \(availabilityZone) · \(cidrBlock)\(name.isEmpty ? "" : " (\(name))")" }
}

struct KeyPairSummary: Identifiable, Hashable {
    let keyPairId: String
    let keyName: String
    let keyType: String
    var id: String { keyName }
}

struct SecurityGroupSummary: Identifiable, Hashable {
    let groupId: String
    let groupName: String
    let vpcId: String
    var id: String { groupId }
}

struct LaunchInstanceOptions {
    var name = ""
    var amiId = ""
    var instanceType = "t3.micro"
    var count = 1
    var keyPairName = ""
    var vpcId = ""
    var subnetId = ""
    var autoAssignPublicIp = true
    var createNewSecurityGroup = true
    var newSecurityGroupName = ""
    var existingSecurityGroupId = ""
    var allowSsh = true
    var allowHttp = false
    var allowHttps = false
    var rootVolumeSize = 8
    var rootVolumeType = "gp3"
    var iamInstanceProfile = ""
    var userData = ""
    var detailedMonitoring = false
    var terminationProtection = false
    var imdsv2Required = true
    var shutdownBehavior = "stop"
}

// MARK: - S3

struct S3Bucket: Identifiable, Hashable {
    let name: String
    let creationDate: Date?
    var region: String = ""
    var id: String { name }
}

struct S3Object: Identifiable, Hashable {
    var key: String
    var sizeBytes: Int64 = 0
    var lastModified: Date?
    var storageClass = ""
    var eTag = ""
    var isFolder = false

    var id: String { key }

    var displayName: String {
        key.split(separator: "/").last.map(String.init) ?? key
    }

    var fileType: String {
        if isFolder { return "Folder" }
        let ext = (displayName as NSString).pathExtension
        return ext.isEmpty ? "File" : "\(ext.uppercased()) File"
    }

    var displaySize: String { isFolder ? "" : ByteFormat.string(sizeBytes) }
}

struct CreateBucketOptions {
    enum Encryption: String, CaseIterable, Identifiable {
        case sseS3 = "SSE-S3", sseKms = "SSE-KMS"
        var id: String { rawValue }
    }

    var bucketName = ""
    var region = "us-east-1"
    var blockAllPublicAccess = true
    var versioningEnabled = false
    var encryption: Encryption = .sseS3
    var kmsKeyArn = ""
    var bucketKeyEnabled = true
    var tags: [(String, String)] = []
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        switch bytes {
        case 0: "0 B"
        case ..<1024: "\(bytes) B"
        case ..<(1024 * 1024): String(format: "%.1f KB", Double(bytes) / 1024)
        case ..<(1024 * 1024 * 1024): String(format: "%.1f MB", Double(bytes) / 1_048_576)
        default: String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
        }
    }
}

// MARK: - IAM

struct AccessKeyInfo: Identifiable, Hashable {
    var accessKeyId: String
    var status: String
    var createDate: Date?
    var lastUsedDate: Date?
    var lastUsedRegion = ""
    var lastUsedService = ""
    var id: String { accessKeyId }
    var isActive: Bool { status == "Active" }
}

struct IamUser: Identifiable, Hashable {
    var userName: String
    var userId: String
    var arn: String
    var path: String
    var createDate: Date?
    var passwordLastUsed: Date?
    var id: String { userName }
}

struct IamUserDetail {
    var groups: [String] = []
    var attachedPolicies: [(name: String, arn: String)] = []
    var inlinePolicies: [String] = []
    var accessKeys: [AccessKeyInfo] = []
    var tags: [(key: String, value: String)] = []
}

struct IamRole: Identifiable, Hashable {
    var roleName: String
    var roleId: String
    var arn: String
    var path: String
    var description: String
    var createDate: Date?
    var maxSessionDuration: Int
    var trustedEntities: String
    var id: String { roleName }
    var maxSessionDisplay: String { "\(maxSessionDuration / 3600)h \((maxSessionDuration % 3600) / 60)m" }
}

struct IamGroup: Identifiable, Hashable {
    var groupName: String
    var groupId: String
    var arn: String
    var path: String
    var createDate: Date?
    var id: String { groupName }
}

struct IamPolicy: Identifiable, Hashable {
    var policyName: String
    var policyId: String
    var arn: String
    var path: String
    var description: String
    var createDate: Date?
    var updateDate: Date?
    var attachmentCount: Int
    var defaultVersionId: String
    var id: String { arn }
}

struct IamEntityDetail {
    var attachedPolicies: [String] = []
    var inlinePolicies: [String] = []
    var members: [String] = []
}

// MARK: - CloudWatch / GuardDuty

struct CloudWatchAlarm: Identifiable, Hashable {
    let name: String
    let state: String
    let metricName: String
    let namespace: String
    let description: String
    let updatedAt: Date?
    let alarmArn: String
    var id: String { alarmArn.isEmpty ? name : alarmArn }
}

struct GuardDutyFinding: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let severity: Double
    let type: String
    let resourceType: String
    let region: String
    let accountId: String
    let updatedAt: Date?

    var severityLabel: String { severity >= 7 ? "HIGH" : severity >= 4 ? "MEDIUM" : "LOW" }
}

// MARK: - Security audit

enum FindingSeverity: Int, Comparable {
    case ok, warning, critical
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct SecurityFinding: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let description: String
    let severity: FindingSeverity
    var affectedCount: Int?
}

struct SecurityAuditResult {
    var findings: [SecurityFinding] = []
    var auditedAt = Date()
    var errorMessage: String?

    var criticalCount: Int { findings.filter { $0.severity == .critical }.count }
    var warningCount: Int { findings.filter { $0.severity == .warning }.count }
    var okCount: Int { findings.filter { $0.severity == .ok }.count }
    var summaryText: String {
        errorMessage.map { "Audit error: \($0)" }
            ?? "\(criticalCount) critical · \(warningCount) warnings · \(okCount) OK"
    }
}

// MARK: - Dashboard & billing

struct DailyCost: Identifiable, Hashable {
    let date: Date
    let amount: Double
    var id: Date { date }
}

struct ServiceCost: Identifiable, Hashable {
    let serviceName: String
    let amount: Double
    var id: String { serviceName }
}

struct DashboardSummary {
    var runningInstances = 0
    var stoppedInstances = 0
    var totalInstances = 0
    var s3BucketCount = 0
    var activeAlarms = 0

    var currentMonthCost = 0.0
    var lastMonthCost = 0.0
    var forecastedMonthCost = 0.0
    var currency = "USD"
    var dailyCosts: [DailyCost] = []
    var serviceCosts: [ServiceCost] = []

    var accountId = ""
    var accountArn = ""
    var region = ""
    var lastRefreshed = Date()
    var warnings: [String] = []
}

struct MonthlyServiceCost: Identifiable, Hashable {
    let month: Date
    let monthLabel: String
    let service: String
    let amount: Double
    var id: String { "\(monthLabel)|\(service)" }
}

struct BillingReport {
    var monthLabels: [String] = []
    var topServices: [String] = []
    var entries: [MonthlyServiceCost] = []
    var grandTotal = 0.0
    var currency = "USD"
}

// MARK: - Search

struct SearchResult: Identifiable, Hashable {
    enum Kind: String { case ec2 = "EC2", s3 = "S3", iamUser = "IAM User", iamRole = "IAM Role" }
    let kind: Kind
    let title: String
    let subtitle: String
    var id: String { "\(kind.rawValue):\(title)" }
}
