import Foundation

struct SecurityAuditService {
    let client: AWSClient

    func run() async -> SecurityAuditResult {
        let iam = IamService(client: client)

        async let report = iam.credentialReport()
        async let policy = checkPasswordPolicy(iam)
        async let summary = checkAccountSummary(iam)
        async let imds = checkImdsV1()
        async let s3 = checkS3PublicAccess()

        var findings: [SecurityFinding] = []
        if let csv = await report {
            let rows = Self.rows(csv)
            findings.append(Self.rootKeys(rows))
            findings.append(Self.inactiveUsers(rows))
            findings.append(Self.keyRotation(rows))
        } else {
            findings.append(SecurityFinding(title: "Root access keys",
                                            description: "Could not retrieve credential report. Verify IAM permissions.",
                                            severity: .warning))
            findings += await checkInactiveUsersFallback(iam)
        }
        findings += await policy
        findings += await summary
        findings += await imds
        findings += await s3
        return SecurityAuditResult(findings: findings.sorted { $0.severity > $1.severity })
    }

    // MARK: Credential report

    private static func rows(_ csv: String) -> [[String]] {
        csv.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces).components(separatedBy: ",") }
    }

    private static let cutoff = Date().addingTimeInterval(-90 * 86400)

    private static func rootKeys(_ rows: [[String]]) -> SecurityFinding {
        guard let root = rows.first(where: { $0.count >= 14 && $0[0].contains("<root_account>") }) else {
            return SecurityFinding(title: "Root access keys", description: "Root account row not found in credential report.",
                                   severity: .warning)
        }
        let k1 = root[8] == "true", k2 = root[13] == "true"
        return k1 || k2
            ? SecurityFinding(title: "Root access keys active",
                              description: "Active root account access keys found. These grant unrestricted access — disable them immediately.",
                              severity: .critical, affectedCount: (k1 ? 1 : 0) + (k2 ? 1 : 0))
            : SecurityFinding(title: "Root access keys", description: "No active root account access keys detected.", severity: .ok)
    }

    private static func inactiveUsers(_ rows: [[String]]) -> SecurityFinding {
        let inactive = rows.filter { cols in
            guard cols.count >= 5, !cols[0].isEmpty, !cols[0].contains("<root_account>"), cols[3] == "true" else { return false }
            let last = cols[4]
            if ["no_information", "N/A", "not_supported"].contains(last) { return true }
            return AWSDate.parse(last).map { $0 < cutoff } ?? false
        }.count
        return inactive > 0
            ? SecurityFinding(title: "Inactive IAM users",
                              description: "\(inactive) user(s) with console access haven't logged in for 90+ days.",
                              severity: .warning, affectedCount: inactive)
            : SecurityFinding(title: "IAM user activity",
                              description: "All IAM users with console access have recent activity.", severity: .ok)
    }

    private static func keyRotation(_ rows: [[String]]) -> SecurityFinding {
        func stale(_ active: String, _ rotated: String) -> Bool {
            guard active == "true", !["N/A", "not_supported", ""].contains(rotated) else { return false }
            return AWSDate.parse(rotated).map { $0 < cutoff } ?? false
        }
        var count = 0
        for cols in rows where cols.count >= 15 && !cols[0].isEmpty && !cols[0].contains("<root_account>") {
            if stale(cols[8], cols[9]) { count += 1 }
            if stale(cols[13], cols[14]) { count += 1 }
        }
        return count > 0
            ? SecurityFinding(title: "Access keys not rotated",
                              description: "\(count) active access key(s) have not been rotated in 90+ days. Rotate them to limit exposure from credential leaks.",
                              severity: .warning, affectedCount: count)
            : SecurityFinding(title: "Access key rotation",
                              description: "All active access keys have been rotated within the last 90 days.", severity: .ok)
    }

    // MARK: Account checks

    private func checkPasswordPolicy(_ iam: IamService) async -> [SecurityFinding] {
        do {
            guard let p = try await iam.passwordPolicy() else { return [] }
            var issues: [String] = []
            let minLen = p.int("MinimumPasswordLength") ?? 0
            if minLen < 14 { issues.append("min length is \(minLen) (< 14)") }
            if !p.bool("RequireNumbers") { issues.append("numbers not required") }
            if !p.bool("RequireSymbols") { issues.append("symbols not required") }
            if !p.bool("RequireUppercaseCharacters") { issues.append("uppercase not required") }
            let maxAge = p.int("MaxPasswordAge") ?? 0
            if maxAge == 0 || maxAge > 90 { issues.append("no 90-day rotation") }
            if (p.int("PasswordReusePrevention") ?? 0) < 5 { issues.append("reuse prevention < 5") }
            return [issues.isEmpty
                ? SecurityFinding(title: "Password policy", description: "A strong IAM password policy is configured.", severity: .ok)
                : SecurityFinding(title: "Weak password policy", description: "Policy issues: \(issues.joined(separator: ", ")).",
                                  severity: .warning)]
        } catch let e as AWSError where e.code == "NoSuchEntity" {
            return [SecurityFinding(title: "No password policy",
                                    description: "No IAM password policy is configured. Users may set any password.",
                                    severity: .critical)]
        } catch {
            return []
        }
    }

    private func checkAccountSummary(_ iam: IamService) async -> [SecurityFinding] {
        guard let s = try? await iam.accountSummary() else { return [] }
        var findings = [s["AccountMFAEnabled"] == 1
            ? SecurityFinding(title: "Root MFA", description: "MFA is enabled on the root account.", severity: .ok)
            : SecurityFinding(title: "Root MFA disabled",
                              description: "MFA is NOT enabled on the root account. Enable it immediately.", severity: .critical)]
        let users = s["Users"] ?? 0
        let mfa = s["MFADevicesInUse"] ?? 0
        if users > 0 {
            let pct = Int((Double(mfa) / Double(users) * 100).rounded())
            findings.append(pct >= 80
                ? SecurityFinding(title: "MFA coverage", description: "\(mfa)/\(users) users have MFA enabled (\(pct)%).",
                                  severity: .ok, affectedCount: mfa)
                : SecurityFinding(title: "Low MFA coverage",
                                  description: "Only \(mfa)/\(users) users have MFA (\(pct)%). Enable MFA for all users.",
                                  severity: .warning, affectedCount: users - mfa))
        }
        return findings
    }

    private func checkImdsV1() async -> [SecurityFinding] {
        guard let instances = try? await Ec2Service(client: client).instances() else { return [] }
        let v1 = instances.filter { $0.state != "terminated" && $0.metadataHttpTokens != "required" && $0.metadataHttpTokens != "—" }
        return [v1.isEmpty
            ? SecurityFinding(title: "IMDSv2 enforced", description: "All EC2 instances require IMDSv2 (HttpTokens = required).",
                              severity: .ok)
            : SecurityFinding(title: "IMDSv1 enabled on EC2",
                              description: "\(v1.count) instance(s) still allow IMDSv1 (HttpTokens = optional). Set HttpTokens to 'required' to enforce IMDSv2 and prevent SSRF-based credential theft.",
                              severity: .warning, affectedCount: v1.count)]
    }

    private func checkS3PublicAccess() async -> [SecurityFinding] {
        let s3 = S3Service(client: client)
        guard let all = try? await s3.buckets(), !all.isEmpty else { return [] }
        let checked = Array(all.prefix(30))
        let publicNames = await withTaskGroup(of: String?.self) { group in
            for b in checked { group.addTask { await s3.isPubliclyAccessible(b.name) ? b.name : nil } }
            var names: [String] = []
            for await n in group { if let n { names.append(n) } }
            return names.sorted()
        }
        let suffix = all.count > 30 ? " (checked \(checked.count) of \(all.count))" : ""
        return [publicNames.isEmpty
            ? SecurityFinding(title: "S3 Block Public Access",
                              description: "All checked S3 buckets have Block Public Access enabled\(suffix).", severity: .ok)
            : SecurityFinding(title: "S3 buckets publicly accessible",
                              description: "\(publicNames.count) bucket(s) are missing Block Public Access\(suffix): \(publicNames.prefix(5).joined(separator: ", "))\(publicNames.count > 5 ? "…" : "").",
                              severity: .critical, affectedCount: publicNames.count)]
    }

    private func checkInactiveUsersFallback(_ iam: IamService) async -> [SecurityFinding] {
        guard let users = try? await iam.users() else { return [] }
        let inactive = users.filter { ($0.passwordLastUsed ?? .distantPast) < Self.cutoff }.count
        return [inactive > 0
            ? SecurityFinding(title: "Inactive IAM users", description: "\(inactive) user(s) have not logged in for 90+ days.",
                              severity: .warning, affectedCount: inactive)
            : SecurityFinding(title: "IAM user activity", description: "All IAM users have recent activity.", severity: .ok)]
    }
}

struct SearchService {
    let client: AWSClient

    /// Searches EC2 instances, S3 buckets and IAM users/roles in the active account/region.
    func search(_ query: String) async -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        async let instances = try? Ec2Service(client: client).instances()
        async let buckets = try? S3Service(client: client).buckets()
        async let users = try? IamService(client: client).users()
        async let roles = try? IamService(client: client).roles()

        var results: [SearchResult] = []
        for i in await instances ?? [] where [i.name, i.instanceId, i.publicIpAddress, i.privateIpAddress]
            .contains(where: { $0.lowercased().contains(q) }) {
            results.append(SearchResult(kind: .ec2, title: i.name, subtitle: "\(i.instanceId) · \(i.state) · \(i.instanceType)"))
        }
        for b in await buckets ?? [] where b.name.lowercased().contains(q) {
            results.append(SearchResult(kind: .s3, title: b.name, subtitle: b.region.isEmpty ? "S3 bucket" : b.region))
        }
        for u in await users ?? [] where u.userName.lowercased().contains(q) {
            results.append(SearchResult(kind: .iamUser, title: u.userName, subtitle: u.arn))
        }
        for r in await roles ?? [] where r.roleName.lowercased().contains(q) {
            results.append(SearchResult(kind: .iamRole, title: r.roleName, subtitle: r.arn))
        }
        return results
    }
}
