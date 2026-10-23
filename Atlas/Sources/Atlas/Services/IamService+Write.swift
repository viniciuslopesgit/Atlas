import Foundation

struct CreateUserOptions {
    enum Permissions: String, CaseIterable, Identifiable {
        case none = "No permissions", groups = "Add to groups", copy = "Copy from user", policies = "Attach policies"
        var id: String { rawValue }
    }

    var userName = ""
    var path = "/"
    var consoleAccess = false
    var password = ""
    var requirePasswordReset = true
    var permissions: Permissions = .none
    var groupNames: [String] = []
    var policyArns: [String] = []
    var copyFromUser = ""
    var tags: [(key: String, value: String)] = []
    var createAccessKey = false
}

/// Result of creating a user; the secret is only available here.
struct CreatedUser {
    let userName: String
    var accessKey: (id: String, secret: String)?
}

/// A managed policy that can be attached (AWS-managed or customer-managed).
struct AttachablePolicy: Identifiable, Hashable {
    let name: String
    let arn: String
    let isAWSManaged: Bool
    var id: String { arn }
}

extension IamService {
    private func call(_ action: String, _ params: [String: String]) async throws {
        _ = try await client.query(.iam, action, params)
    }

    /// Runs the operations concurrently and rethrows the first failure.
    private func all(_ ops: [@Sendable () async throws -> Void]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for op in ops { group.addTask { try await op() } }
            try await group.waitForAll()
        }
    }

    private func names(_ action: String, _ params: [String: String], list: String, field: String?) async throws -> [String] {
        var out: [String] = []
        try await client.queryPaged(.iam, action, params, tokenParam: "Marker", tokenPath: { xml in
            let r = xml["\(action)Result"]
            return r?.bool("IsTruncated") == true ? r?.str("Marker") : nil
        }, page: { xml in
            for n in xml.list("\(action)Result/\(list)", item: "member") { out.append(field.map { n.str($0) } ?? n.text) }
        })
        return out
    }

    // MARK: Users

    func createUser(_ o: CreateUserOptions) async throws -> CreatedUser {
        var p = ["UserName": o.userName]
        if !o.path.isEmpty, o.path != "/" { p["Path"] = o.path }
        for (i, t) in o.tags.enumerated() {
            p["Tags.member.\(i + 1).Key"] = t.key
            p["Tags.member.\(i + 1).Value"] = t.value
        }
        try await call("CreateUser", p)
        let name = o.userName

        if o.consoleAccess {
            try await call("CreateLoginProfile", ["UserName": name, "Password": o.password,
                                                  "PasswordResetRequired": o.requirePasswordReset ? "true" : "false"])
        }

        var groups: [String] = []
        var policies: [String] = []
        switch o.permissions {
        case .none: break
        case .groups: groups = o.groupNames
        case .policies: policies = o.policyArns
        case .copy:
            groups = try await names("ListGroupsForUser", ["UserName": o.copyFromUser], list: "Groups", field: "GroupName")
            policies = try await names("ListAttachedUserPolicies", ["UserName": o.copyFromUser],
                                       list: "AttachedPolicies", field: "PolicyArn")
        }
        try await all(groups.map { g in { @Sendable in try await call("AddUserToGroup", ["UserName": name, "GroupName": g]) } }
                      + policies.map { a in { @Sendable in try await call("AttachUserPolicy", ["UserName": name, "PolicyArn": a]) } })

        var created = CreatedUser(userName: name)
        if o.createAccessKey { created.accessKey = try await createAccessKey(name) }
        return created
    }

    /// Deletes a user and everything that blocks DeleteUser, in the same order as Atlas 1.0.1.
    func deleteUser(_ name: String) async throws {
        let u = ["UserName": name]
        async let keys = names("ListAccessKeys", u, list: "AccessKeyMetadata", field: "AccessKeyId")
        async let groups = names("ListGroupsForUser", u, list: "Groups", field: "GroupName")
        async let attached = names("ListAttachedUserPolicies", u, list: "AttachedPolicies", field: "PolicyArn")
        async let inline = names("ListUserPolicies", u, list: "PolicyNames", field: nil)
        async let mfa = names("ListMFADevices", u, list: "MFADevices", field: "SerialNumber")
        async let certs = names("ListSigningCertificates", u, list: "Certificates", field: "CertificateId")
        async let ssh = names("ListSSHPublicKeys", u, list: "SSHPublicKeys", field: "SSHPublicKeyId")
        async let svc = client.query(.iam, "ListServiceSpecificCredentials", u)

        let svcIds = try await svc.list("ListServiceSpecificCredentialsResult/ServiceSpecificCredentials", item: "member")
            .map { $0.str("ServiceSpecificCredentialId") }
        var ops: [@Sendable () async throws -> Void] = []
        ops += try await keys.map { k in { @Sendable in try await call("DeleteAccessKey", ["UserName": name, "AccessKeyId": k]) } }
        ops += try await groups.map { g in { @Sendable in try await call("RemoveUserFromGroup", ["UserName": name, "GroupName": g]) } }
        ops += try await attached.map { a in { @Sendable in try await call("DetachUserPolicy", ["UserName": name, "PolicyArn": a]) } }
        ops += try await inline.map { p in { @Sendable in try await call("DeleteUserPolicy", ["UserName": name, "PolicyName": p]) } }
        ops += try await mfa.map { serial in { @Sendable in
            try await call("DeactivateMFADevice", ["UserName": name, "SerialNumber": serial])
            // Virtual devices have an ARN; hardware tokens a plain serial.
            if serial.hasPrefix("arn:") { try await call("DeleteVirtualMFADevice", ["SerialNumber": serial]) }
        } }
        ops += try await certs.map { c in { @Sendable in try await call("DeleteSigningCertificate", ["UserName": name, "CertificateId": c]) } }
        ops += try await ssh.map { k in { @Sendable in try await call("DeleteSSHPublicKey", ["UserName": name, "SSHPublicKeyId": k]) } }
        ops += svcIds.map { c in { @Sendable in try await call("DeleteServiceSpecificCredential",
                                                  ["UserName": name, "ServiceSpecificCredentialId": c]) } }
        try await all(ops)

        do { try await call("DeleteLoginProfile", u) } catch let e as AWSError where e.code == "NoSuchEntity" {}
        try await call("DeleteUser", u)
    }

    func addUserToGroup(_ user: String, _ group: String) async throws {
        try await call("AddUserToGroup", ["UserName": user, "GroupName": group])
    }

    func removeUserFromGroup(_ user: String, _ group: String) async throws {
        try await call("RemoveUserFromGroup", ["UserName": user, "GroupName": group])
    }

    func attachUserPolicy(_ user: String, _ arn: String) async throws {
        try await call("AttachUserPolicy", ["UserName": user, "PolicyArn": arn])
    }

    func detachUserPolicy(_ user: String, _ arn: String) async throws {
        try await call("DetachUserPolicy", ["UserName": user, "PolicyArn": arn])
    }

    /// Replaces the user's tags: removes keys that are gone, then puts the new set.
    func setUserTags(_ user: String, old: [String], new: [(key: String, value: String)]) async throws {
        let removed = Set(old).subtracting(new.map(\.key))
        if !removed.isEmpty {
            var p = ["UserName": user]
            for (i, k) in removed.sorted().enumerated() { p["TagKeys.member.\(i + 1)"] = k }
            try await call("UntagUser", p)
        }
        if !new.isEmpty {
            var p = ["UserName": user]
            for (i, t) in new.enumerated() {
                p["Tags.member.\(i + 1).Key"] = t.key
                p["Tags.member.\(i + 1).Value"] = t.value
            }
            try await call("TagUser", p)
        }
    }

    // MARK: Roles, groups, policies

    func deleteRole(_ name: String) async throws {
        let r = ["RoleName": name]
        async let attached = names("ListAttachedRolePolicies", r, list: "AttachedPolicies", field: "PolicyArn")
        async let inline = names("ListRolePolicies", r, list: "PolicyNames", field: nil)
        async let profiles = names("ListInstanceProfilesForRole", r, list: "InstanceProfiles", field: "InstanceProfileName")
        var ops: [@Sendable () async throws -> Void] = []
        ops += try await attached.map { a in { @Sendable in try await call("DetachRolePolicy", ["RoleName": name, "PolicyArn": a]) } }
        ops += try await inline.map { p in { @Sendable in try await call("DeleteRolePolicy", ["RoleName": name, "PolicyName": p]) } }
        ops += try await profiles.map { ip in { @Sendable in
            try await call("RemoveRoleFromInstanceProfile", ["RoleName": name, "InstanceProfileName": ip])
        } }
        try await all(ops)
        try await call("DeleteRole", r)
    }

    func deleteGroup(_ name: String) async throws {
        let g = ["GroupName": name]
        async let members = names("GetGroup", g, list: "Users", field: "UserName")
        async let attached = names("ListAttachedGroupPolicies", g, list: "AttachedPolicies", field: "PolicyArn")
        async let inline = names("ListGroupPolicies", g, list: "PolicyNames", field: nil)
        var ops: [@Sendable () async throws -> Void] = []
        ops += try await members.map { u in { @Sendable in try await call("RemoveUserFromGroup", ["GroupName": name, "UserName": u]) } }
        ops += try await attached.map { a in { @Sendable in try await call("DetachGroupPolicy", ["GroupName": name, "PolicyArn": a]) } }
        ops += try await inline.map { p in { @Sendable in try await call("DeleteGroupPolicy", ["GroupName": name, "PolicyName": p]) } }
        try await all(ops)
        try await call("DeleteGroup", g)
    }

    /// Detaches the policy everywhere and removes non-default versions before DeletePolicy.
    func deletePolicy(_ arn: String) async throws {
        let p = ["PolicyArn": arn]
        let entities = try await client.query(.iam, "ListEntitiesForPolicy", p).path("ListEntitiesForPolicyResult")
        var ops: [@Sendable () async throws -> Void] = []
        for u in entities?.list("PolicyUsers", item: "member").map({ $0.str("UserName") }) ?? [] {
            ops.append { @Sendable in try await call("DetachUserPolicy", ["UserName": u, "PolicyArn": arn]) }
        }
        for r in entities?.list("PolicyRoles", item: "member").map({ $0.str("RoleName") }) ?? [] {
            ops.append { @Sendable in try await call("DetachRolePolicy", ["RoleName": r, "PolicyArn": arn]) }
        }
        for g in entities?.list("PolicyGroups", item: "member").map({ $0.str("GroupName") }) ?? [] {
            ops.append { @Sendable in try await call("DetachGroupPolicy", ["GroupName": g, "PolicyArn": arn]) }
        }
        try await all(ops)

        let versions = try await client.query(.iam, "ListPolicyVersions", p)
            .list("ListPolicyVersionsResult/Versions", item: "member")
            .filter { !$0.bool("IsDefaultVersion") }
            .map { $0.str("VersionId") }
        try await all(versions.map { v in { @Sendable in try await call("DeletePolicyVersion", ["PolicyArn": arn, "VersionId": v]) } })
        try await call("DeletePolicy", p)
    }

    /// Every attachable managed policy (AWS-managed and customer-managed), for the attach pickers.
    func attachablePolicies() async throws -> [AttachablePolicy] {
        var out: [AttachablePolicy] = []
        try await client.queryPaged(.iam, "ListPolicies", ["Scope": "All", "OnlyAttached": "false"], tokenParam: "Marker",
                                    tokenPath: { xml in
            let r = xml["ListPoliciesResult"]
            return r?.bool("IsTruncated") == true ? r?.str("Marker") : nil
        }, page: { xml in
            for p in xml.list("ListPoliciesResult/Policies", item: "member") {
                let arn = p.str("Arn")
                out.append(AttachablePolicy(name: p.str("PolicyName"), arn: arn, isAWSManaged: arn.contains(":aws:policy/")))
            }
        })
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
