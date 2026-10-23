import Foundation

struct IamService {
    let client: AWSClient

    private static func d(_ v: String) -> String { v.isEmpty ? "—" : v }

    /// Runs a paged IAM list call (Marker / IsTruncated).
    private func paged(_ action: String, _ params: [String: String] = [:], page: (XNode) -> Void) async throws {
        try await client.queryPaged(.iam, action, params, tokenParam: "Marker", tokenPath: { xml in
            let result = xml.children.first { $0.name.hasSuffix("Result") }
            return result?.bool("IsTruncated") == true ? result?.str("Marker") : nil
        }, page: page)
    }

    private static func result(_ xml: XNode, _ action: String) -> XNode? { xml["\(action)Result"] }

    func users() async throws -> [IamUser] {
        var users: [IamUser] = []
        try await paged("ListUsers") { xml in
            for u in Self.result(xml, "ListUsers")?.list("Users", item: "member") ?? [] {
                users.append(IamUser(userName: u.str("UserName"), userId: u.str("UserId"), arn: u.str("Arn"),
                                     path: Self.d(u.str("Path")), createDate: u.date("CreateDate"),
                                     passwordLastUsed: u.date("PasswordLastUsed")))
            }
        }
        return users
    }

    func roles() async throws -> [IamRole] {
        var roles: [IamRole] = []
        try await paged("ListRoles") { xml in
            for r in Self.result(xml, "ListRoles")?.list("Roles", item: "member") ?? [] {
                roles.append(IamRole(roleName: r.str("RoleName"), roleId: r.str("RoleId"), arn: r.str("Arn"),
                                     path: Self.d(r.str("Path")), description: Self.d(r.str("Description")),
                                     createDate: r.date("CreateDate"),
                                     maxSessionDuration: r.int("MaxSessionDuration") ?? 3600,
                                     trustedEntities: Self.trustedEntities(r.str("AssumeRolePolicyDocument"))))
            }
        }
        return roles
    }

    func groups() async throws -> [IamGroup] {
        var groups: [IamGroup] = []
        try await paged("ListGroups") { xml in
            for g in Self.result(xml, "ListGroups")?.list("Groups", item: "member") ?? [] {
                groups.append(IamGroup(groupName: g.str("GroupName"), groupId: g.str("GroupId"), arn: g.str("Arn"),
                                       path: Self.d(g.str("Path")), createDate: g.date("CreateDate")))
            }
        }
        return groups
    }

    /// Customer-managed policies only (Scope=Local), matching the Windows app.
    func policies() async throws -> [IamPolicy] {
        var policies: [IamPolicy] = []
        try await paged("ListPolicies", ["Scope": "Local"]) { xml in
            for p in Self.result(xml, "ListPolicies")?.list("Policies", item: "member") ?? [] {
                policies.append(IamPolicy(policyName: p.str("PolicyName"), policyId: p.str("PolicyId"),
                                          arn: p.str("Arn"), path: Self.d(p.str("Path")),
                                          description: Self.d(p.str("Description")),
                                          createDate: p.date("CreateDate"), updateDate: p.date("UpdateDate"),
                                          attachmentCount: p.int("AttachmentCount") ?? 0,
                                          defaultVersionId: p.str("DefaultVersionId")))
            }
        }
        return policies
    }

    /// Extracts principals from a URL-encoded trust policy document.
    static func trustedEntities(_ encoded: String) -> String {
        let decoded = encoded.removingPercentEncoding ?? encoded
        guard let data = decoded.data(using: .utf8),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "—" }
        let statements: [[String: Any]] = (doc["Statement"] as? [[String: Any]])
            ?? ((doc["Statement"] as? [String: Any]).map { [$0] } ?? [])
        var entities: [String] = []
        for s in statements {
            guard let principal = s["Principal"] else { continue }
            if let p = principal as? String { entities.append(p); continue }
            for (_, v) in (principal as? [String: Any]) ?? [:] {
                if let one = v as? String { entities.append(one) }
                if let many = v as? [String] { entities += many }
            }
        }
        return entities.isEmpty ? "—" : entities.joined(separator: ", ")
    }

    // MARK: Detail

    func userDetail(_ userName: String) async -> IamUserDetail {
        let p = ["UserName": userName]
        async let groups = try? client.query(.iam, "ListGroupsForUser", p)
        async let attached = try? client.query(.iam, "ListAttachedUserPolicies", p)
        async let inline = try? client.query(.iam, "ListUserPolicies", p)
        async let tags = try? client.query(.iam, "ListUserTags", p)
        async let keys = try? accessKeys(userName)

        var d = IamUserDetail()
        d.groups = await groups?.list("ListGroupsForUserResult/Groups", item: "member").map { $0.str("GroupName") } ?? []
        d.attachedPolicies = await attached?.list("ListAttachedUserPoliciesResult/AttachedPolicies", item: "member")
            .map { (name: $0.str("PolicyName"), arn: $0.str("PolicyArn")) } ?? []
        d.inlinePolicies = await inline?.list("ListUserPoliciesResult/PolicyNames", item: "member").map(\.text) ?? []
        d.tags = await tags?.list("ListUserTagsResult/Tags", item: "member")
            .map { (key: $0.str("Key"), value: $0.str("Value")) } ?? []
        d.accessKeys = await keys ?? []
        return d
    }

    func accessKeys(_ userName: String) async throws -> [AccessKeyInfo] {
        let xml = try await client.query(.iam, "ListAccessKeys", ["UserName": userName])
        var keys = xml.list("ListAccessKeysResult/AccessKeyMetadata", item: "member").map {
            AccessKeyInfo(accessKeyId: $0.str("AccessKeyId"), status: $0.str("Status"), createDate: $0.date("CreateDate"))
        }
        for i in keys.indices {
            if let lu = try? await client.query(.iam, "GetAccessKeyLastUsed", ["AccessKeyId": keys[i].accessKeyId]) {
                let n = lu.path("GetAccessKeyLastUsedResult/AccessKeyLastUsed")
                keys[i].lastUsedDate = n?.date("LastUsedDate")
                keys[i].lastUsedRegion = n?.str("Region") ?? ""
                keys[i].lastUsedService = n?.str("ServiceName") ?? ""
            }
        }
        return keys
    }

    func roleDetail(_ roleName: String) async -> IamEntityDetail {
        let p = ["RoleName": roleName]
        async let attached = try? client.query(.iam, "ListAttachedRolePolicies", p)
        async let inline = try? client.query(.iam, "ListRolePolicies", p)
        var d = IamEntityDetail()
        d.attachedPolicies = await attached?.list("ListAttachedRolePoliciesResult/AttachedPolicies", item: "member")
            .map { $0.str("PolicyName") } ?? []
        d.inlinePolicies = await inline?.list("ListRolePoliciesResult/PolicyNames", item: "member").map(\.text) ?? []
        return d
    }

    func groupDetail(_ groupName: String) async -> IamEntityDetail {
        let p = ["GroupName": groupName]
        async let group = try? client.query(.iam, "GetGroup", p)
        async let attached = try? client.query(.iam, "ListAttachedGroupPolicies", p)
        async let inline = try? client.query(.iam, "ListGroupPolicies", p)
        var d = IamEntityDetail()
        d.members = await group?.list("GetGroupResult/Users", item: "member").map { $0.str("UserName") } ?? []
        d.attachedPolicies = await attached?.list("ListAttachedGroupPoliciesResult/AttachedPolicies", item: "member")
            .map { $0.str("PolicyName") } ?? []
        d.inlinePolicies = await inline?.list("ListGroupPoliciesResult/PolicyNames", item: "member").map(\.text) ?? []
        return d
    }

    /// Returns the default version's document, pretty-printed.
    func policyDocument(arn: String, versionId: String) async throws -> String {
        let xml = try await client.query(.iam, "GetPolicyVersion", ["PolicyArn": arn, "VersionId": versionId])
        let raw = xml.str("GetPolicyVersionResult/PolicyVersion/Document")
        let decoded = raw.removingPercentEncoding ?? raw
        if let data = decoded.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: pretty, as: UTF8.self)
        }
        return decoded
    }

    // MARK: Access key management

    func createAccessKey(_ userName: String) async throws -> (id: String, secret: String) {
        let xml = try await client.query(.iam, "CreateAccessKey", ["UserName": userName])
        let k = xml.path("CreateAccessKeyResult/AccessKey")
        return (k?.str("AccessKeyId") ?? "", k?.str("SecretAccessKey") ?? "")
    }

    func setAccessKey(_ userName: String, _ keyId: String, active: Bool) async throws {
        _ = try await client.query(.iam, "UpdateAccessKey",
                                   ["UserName": userName, "AccessKeyId": keyId, "Status": active ? "Active" : "Inactive"])
    }

    func deleteAccessKey(_ userName: String, _ keyId: String) async throws {
        _ = try await client.query(.iam, "DeleteAccessKey", ["UserName": userName, "AccessKeyId": keyId])
    }

    // MARK: Account-level (security audit)

    func credentialReport() async -> String? {
        guard (try? await client.query(.iam, "GenerateCredentialReport")) != nil else { return nil }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            do {
                let xml = try await client.query(.iam, "GetCredentialReport")
                let content = xml.str("GetCredentialReportResult/Content")
                guard let data = Data(base64Encoded: content) else { return nil }
                return String(decoding: data, as: UTF8.self)
            } catch let e as AWSError where ["ReportInProgress", "ReportNotPresent"].contains(e.code) {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return nil
            }
        }
        return nil
    }

    func passwordPolicy() async throws -> XNode? {
        try await client.query(.iam, "GetAccountPasswordPolicy").path("GetAccountPasswordPolicyResult/PasswordPolicy")
    }

    func accountSummary() async throws -> [String: Int] {
        let xml = try await client.query(.iam, "GetAccountSummary")
        var map: [String: Int] = [:]
        for e in xml.list("GetAccountSummaryResult/SummaryMap", item: "entry") {
            map[e.str("key")] = e.int("value") ?? 0
        }
        return map
    }
}

struct StsService {
    let client: AWSClient

    struct Identity { let account: String; let arn: String; let userId: String }

    func callerIdentity() async throws -> Identity {
        let xml = try await client.query(.sts, "GetCallerIdentity")
        let r = xml.path("GetCallerIdentityResult")
        return Identity(account: r?.str("Account") ?? "", arn: r?.str("Arn") ?? "", userId: r?.str("UserId") ?? "")
    }
}
