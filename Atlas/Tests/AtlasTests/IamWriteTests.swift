import Foundation
import Testing
@testable import Atlas

/// IAM query responses keyed by Action; unknown actions answer an empty `<ActionResult/>`.
private func iamMock(_ fixtures: [String: String]) -> AWSClient {
    MockURLProtocol.client { _, body in
        let action = formParams(body)["Action"] ?? ""
        let inner = fixtures[action] ?? ""
        return .init(body: "<\(action)Response><\(action)Result>\(inner)</\(action)Result></\(action)Response>")
    }
}

private var iamCalls: [[String: String]] { MockURLProtocol.requests.map { formParams($0.body) } }
private func actions() -> [String] { iamCalls.compactMap { $0["Action"] } }

extension ServiceTests {
    @Test func deleteUserRemovesDependenciesBeforeTheUser() async throws {
        let client = iamMock([
            "ListAccessKeys": "<AccessKeyMetadata><member><AccessKeyId>AKIA1</AccessKeyId></member></AccessKeyMetadata>",
            "ListGroupsForUser": "<Groups><member><GroupName>devs</GroupName></member></Groups>",
            "ListAttachedUserPolicies": "<AttachedPolicies><member><PolicyArn>arn:aws:iam::aws:policy/ReadOnlyAccess</PolicyArn></member></AttachedPolicies>",
            "ListUserPolicies": "<PolicyNames><member>inline1</member></PolicyNames>",
            "ListMFADevices": "<MFADevices><member><SerialNumber>arn:aws:iam::1:mfa/ana</SerialNumber></member></MFADevices>",
        ])
        try await IamService(client: client).deleteUser("ana")

        let a = actions()
        for step in ["DeleteAccessKey", "RemoveUserFromGroup", "DetachUserPolicy", "DeleteUserPolicy",
                     "DeactivateMFADevice", "DeleteVirtualMFADevice", "DeleteLoginProfile"] {
            let i = try #require(a.firstIndex(of: step), "missing \(step)")
            #expect(i < a.firstIndex(of: "DeleteUser")!, "\(step) must run before DeleteUser")
        }
        #expect(a.last == "DeleteUser")
        #expect(iamCalls.first { $0["Action"] == "DeleteAccessKey" }?["AccessKeyId"] == "AKIA1")
        #expect(iamCalls.first { $0["Action"] == "DetachUserPolicy" }?["PolicyArn"] == "arn:aws:iam::aws:policy/ReadOnlyAccess")
    }

    @Test func deleteUserWithoutLoginProfileStillDeletes() async throws {
        let client = MockURLProtocol.client { _, body in
            let action = formParams(body)["Action"] ?? ""
            if action == "DeleteLoginProfile" {
                return .init(status: 404, body: "<ErrorResponse><Error><Code>NoSuchEntity</Code><Message>none</Message></Error></ErrorResponse>")
            }
            return .init(body: "<\(action)Response><\(action)Result/></\(action)Response>")
        }
        try await IamService(client: client).deleteUser("bot")
        #expect(actions().last == "DeleteUser")
    }

    @Test func createUserSetsConsoleGroupsTagsAndKey() async throws {
        let client = iamMock([
            "CreateAccessKey": "<AccessKey><AccessKeyId>AKIANEW</AccessKeyId><SecretAccessKey>s3cret</SecretAccessKey></AccessKey>",
        ])
        var o = CreateUserOptions()
        o.userName = "ana"
        o.consoleAccess = true
        o.password = "Passw0rd!"
        o.permissions = .groups
        o.groupNames = ["devs", "ops"]
        o.tags = [(key: "team", value: "platform")]
        o.createAccessKey = true
        let created = try await IamService(client: client).createUser(o)

        #expect(created.accessKey?.secret == "s3cret")
        let create = try #require(iamCalls.first { $0["Action"] == "CreateUser" })
        #expect(create["Tags.member.1.Key"] == "team" && create["Tags.member.1.Value"] == "platform")
        #expect(iamCalls.first { $0["Action"] == "CreateLoginProfile" }?["PasswordResetRequired"] == "true")
        #expect(Set(iamCalls.filter { $0["Action"] == "AddUserToGroup" }.compactMap { $0["GroupName"] }) == ["devs", "ops"])
        #expect(actions().first == "CreateUser")
    }

    @Test func createUserCopiesPermissionsFromAnotherUser() async throws {
        let client = iamMock([
            "ListGroupsForUser": "<Groups><member><GroupName>admins</GroupName></member></Groups>",
            "ListAttachedUserPolicies": "<AttachedPolicies><member><PolicyArn>arn:p1</PolicyArn></member></AttachedPolicies>",
        ])
        var o = CreateUserOptions()
        o.userName = "copy"
        o.permissions = .copy
        o.copyFromUser = "ana"
        _ = try await IamService(client: client).createUser(o)
        #expect(iamCalls.first { $0["Action"] == "ListGroupsForUser" }?["UserName"] == "ana")
        #expect(iamCalls.first { $0["Action"] == "AddUserToGroup" }?["GroupName"] == "admins")
        #expect(iamCalls.first { $0["Action"] == "AttachUserPolicy" }?["PolicyArn"] == "arn:p1")
    }

    @Test func deletePolicyDetachesAndRemovesOldVersions() async throws {
        let client = iamMock([
            "ListEntitiesForPolicy": "<PolicyRoles><member><RoleName>app</RoleName></member></PolicyRoles>",
            "ListPolicyVersions": """
            <Versions><member><VersionId>v2</VersionId><IsDefaultVersion>true</IsDefaultVersion></member>\
            <member><VersionId>v1</VersionId><IsDefaultVersion>false</IsDefaultVersion></member></Versions>
            """,
        ])
        try await IamService(client: client).deletePolicy("arn:aws:iam::1:policy/p")
        #expect(iamCalls.first { $0["Action"] == "DetachRolePolicy" }?["RoleName"] == "app")
        #expect(iamCalls.filter { $0["Action"] == "DeletePolicyVersion" }.map { $0["VersionId"] } == ["v1"])
        #expect(actions().last == "DeletePolicy")
    }

    @Test func userTagsReplaceRemovesDroppedKeys() async throws {
        let client = iamMock([:])
        try await IamService(client: client).setUserTags("ana", old: ["team", "old"], new: [(key: "team", value: "x")])
        #expect(iamCalls.first { $0["Action"] == "UntagUser" }?["TagKeys.member.1"] == "old")
        #expect(iamCalls.first { $0["Action"] == "TagUser" }?["Tags.member.1.Value"] == "x")
    }
}
