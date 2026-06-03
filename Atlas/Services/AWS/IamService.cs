using Amazon.IdentityManagement;
using Amazon.IdentityManagement.Model;
using Atlas.Infrastructure;
using Atlas.Models;
using System.Text.Json;

namespace Atlas.Services.AWS;

public sealed class IamService : IIamService
{
    private readonly IAwsSessionFactory _session;
    private readonly AwsClientFactory   _clients;

    public IamService(IAwsSessionFactory session, AwsClientFactory clients)
    {
        _session = session;
        _clients = clients;
    }

    static string D(string? v) => string.IsNullOrWhiteSpace(v) ? "—" : v;

    private AmazonIdentityManagementServiceClient Iam() =>
        _clients.GetIam(_session.GetCredentials());

    // ── Fast list calls (no per-item enrichment) ─────────────────────────────

    public async Task<IReadOnlyList<IamUserModel>> GetUsersAsync(CancellationToken ct = default)
    {
        var client = Iam();
        var users  = new List<IamUserModel>();
        string? marker = null;
        do
        {
            var resp = await client.ListUsersAsync(new ListUsersRequest { Marker = marker }, ct);
            foreach (var u in resp.Users)
                users.Add(new IamUserModel
                {
                    UserName         = u.UserName,
                    UserId           = u.UserId,
                    Arn              = u.Arn,
                    Path             = D(u.Path),
                    CreateDate       = u.CreateDate,
                    PasswordLastUsed = u.PasswordLastUsed == default ? null : u.PasswordLastUsed,
                });
            marker = resp.IsTruncated ? resp.Marker : null;
        }
        while (marker != null);
        return users;
    }

    public async Task<IReadOnlyList<IamRoleModel>> GetRolesAsync(CancellationToken ct = default)
    {
        var client = Iam();
        var roles  = new List<IamRoleModel>();
        string? marker = null;
        do
        {
            var resp = await client.ListRolesAsync(new ListRolesRequest { Marker = marker }, ct);
            foreach (var r in resp.Roles)
                roles.Add(new IamRoleModel
                {
                    RoleName           = r.RoleName,
                    RoleId             = r.RoleId,
                    Arn                = r.Arn,
                    Path               = D(r.Path),
                    Description        = D(r.Description),
                    CreateDate         = r.CreateDate,
                    MaxSessionDuration = r.MaxSessionDuration,
                    TrustedEntities    = ParseTrustedEntities(r.AssumeRolePolicyDocument),
                });
            marker = resp.IsTruncated ? resp.Marker : null;
        }
        while (marker != null);
        return roles;
    }

    public async Task<IReadOnlyList<IamGroupModel>> GetGroupsAsync(CancellationToken ct = default)
    {
        var client = Iam();
        var groups = new List<IamGroupModel>();
        string? marker = null;
        do
        {
            var resp = await client.ListGroupsAsync(new ListGroupsRequest { Marker = marker }, ct);
            foreach (var g in resp.Groups)
                groups.Add(new IamGroupModel
                {
                    GroupName  = g.GroupName,
                    GroupId    = g.GroupId,
                    Arn        = g.Arn,
                    Path       = D(g.Path),
                    CreateDate = g.CreateDate,
                });
            marker = resp.IsTruncated ? resp.Marker : null;
        }
        while (marker != null);
        return groups;
    }

    public async Task<IReadOnlyList<IamPolicyModel>> GetPoliciesAsync(CancellationToken ct = default)
    {
        var client   = Iam();
        var policies = new List<IamPolicyModel>();
        string? marker = null;
        do
        {
            var resp = await client.ListPoliciesAsync(new ListPoliciesRequest
            {
                Scope  = PolicyScopeType.Local,
                Marker = marker
            }, ct);
            foreach (var p in resp.Policies)
                policies.Add(new IamPolicyModel
                {
                    PolicyName       = p.PolicyName,
                    PolicyId         = p.PolicyId,
                    Arn              = p.Arn,
                    Path             = D(p.Path),
                    Description      = D(p.Description),
                    CreateDate       = p.CreateDate,
                    UpdateDate       = p.UpdateDate,
                    AttachmentCount  = p.AttachmentCount,
                    DefaultVersionId = D(p.DefaultVersionId),
                    IsAttachable     = p.IsAttachable,
                    Scope            = "Local",
                });
            marker = resp.IsTruncated ? resp.Marker : null;
        }
        while (marker != null);
        return policies;
    }

    // ── On-demand enrichment ─────────────────────────────────────────────────

    public async Task EnrichUserAsync(IamUserModel user, CancellationToken ct = default)
    {
        var client = Iam();
        var tasks = new[]
        {
            SafeAsync(async () =>
            {
                var r = await client.ListGroupsForUserAsync(
                    new ListGroupsForUserRequest { UserName = user.UserName }, ct);
                user.Groups = r.Groups.Select(g => g.GroupName).ToList();
            }),
            SafeAsync(async () =>
            {
                var r = await client.ListAttachedUserPoliciesAsync(
                    new ListAttachedUserPoliciesRequest { UserName = user.UserName }, ct);
                user.AttachedPolicyRefs = r.AttachedPolicies.Select(p => (p.PolicyName, p.PolicyArn)).ToList();
                user.AttachedPolicies   = user.AttachedPolicyRefs.Select(p => p.Name).ToList();
            }),
            SafeAsync(async () =>
            {
                var r = await client.ListUserPoliciesAsync(
                    new ListUserPoliciesRequest { UserName = user.UserName }, ct);
                user.InlinePolicies = r.PolicyNames.ToList();
            }),
            SafeAsync(async () =>
            {
                user.AccessKeys = await ListAccessKeysAsync(user.UserName, ct);
                user.AccessKeyCount = user.AccessKeys.Count;
            }),
            SafeAsync(async () =>
            {
                user.Tags = await ListUserTagsAsync(user.UserName, ct);
            }),
        };
        await Task.WhenAll(tasks);
    }

    // ── Access key management ────────────────────────────────────────────────

    public async Task<List<AccessKeyInfo>> ListAccessKeysAsync(string userName, CancellationToken ct = default)
    {
        var client = Iam();
        var resp   = await client.ListAccessKeysAsync(new ListAccessKeysRequest { UserName = userName }, ct);

        // Fetch last-used for all keys in parallel (5-second timeout per key)
        var tasks = resp.AccessKeyMetadata.Select(async meta =>
        {
            var info = new AccessKeyInfo
            {
                AccessKeyId = meta.AccessKeyId,
                Status      = meta.Status?.Value ?? "Unknown",
                CreateDate  = meta.CreateDate,
            };
            try
            {
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(TimeSpan.FromSeconds(5));
                var lu = await client.GetAccessKeyLastUsedAsync(
                    new GetAccessKeyLastUsedRequest { AccessKeyId = meta.AccessKeyId }, cts.Token);
                var lau = lu.AccessKeyLastUsed;
                info.LastUsedDate    = lau.LastUsedDate == default ? null : lau.LastUsedDate;
                info.LastUsedRegion  = lau.Region       ?? string.Empty;
                info.LastUsedService = lau.ServiceName  ?? string.Empty;
            }
            catch { /* best-effort — last-used is non-critical */ }
            return info;
        });

        return [.. await Task.WhenAll(tasks)];
    }

    public async Task<(string AccessKeyId, string SecretAccessKey)> CreateAccessKeyAsync(string userName, CancellationToken ct = default)
    {
        var client = Iam();
        var resp   = await client.CreateAccessKeyAsync(new CreateAccessKeyRequest { UserName = userName }, ct);
        return (resp.AccessKey.AccessKeyId, resp.AccessKey.SecretAccessKey);
    }

    public async Task DeleteAccessKeyAsync(string userName, string accessKeyId, CancellationToken ct = default)
    {
        var client = Iam();
        await client.DeleteAccessKeyAsync(new DeleteAccessKeyRequest { UserName = userName, AccessKeyId = accessKeyId }, ct);
    }

    public async Task UpdateAccessKeyStatusAsync(string userName, string accessKeyId, bool active, CancellationToken ct = default)
    {
        var client = Iam();
        await client.UpdateAccessKeyAsync(new UpdateAccessKeyRequest
        {
            UserName    = userName,
            AccessKeyId = accessKeyId,
            Status      = active ? Amazon.IdentityManagement.StatusType.Active : Amazon.IdentityManagement.StatusType.Inactive,
        }, ct);
    }

    // ── Policy management for user ───────────────────────────────────────────

    public async Task AttachUserPolicyAsync(string userName, string policyArn, CancellationToken ct = default)
    {
        var client = Iam();
        await client.AttachUserPolicyAsync(new AttachUserPolicyRequest { UserName = userName, PolicyArn = policyArn }, ct);
    }

    public async Task DetachUserPolicyAsync(string userName, string policyArn, CancellationToken ct = default)
    {
        var client = Iam();
        await client.DetachUserPolicyAsync(new DetachUserPolicyRequest { UserName = userName, PolicyArn = policyArn }, ct);
    }

    // ── Group membership for user ────────────────────────────────────────────

    public async Task AddUserToGroupAsync(string userName, string groupName, CancellationToken ct = default)
    {
        var client = Iam();
        await client.AddUserToGroupAsync(new AddUserToGroupRequest { UserName = userName, GroupName = groupName }, ct);
    }

    public async Task RemoveUserFromGroupAsync(string userName, string groupName, CancellationToken ct = default)
    {
        var client = Iam();
        await client.RemoveUserFromGroupAsync(new RemoveUserFromGroupRequest { UserName = userName, GroupName = groupName }, ct);
    }

    // ── Tags ────────────────────────────────────────────────────────────────

    public async Task<List<IamTagModel>> ListUserTagsAsync(string userName, CancellationToken ct = default)
    {
        var client = Iam();
        var resp   = await client.ListUserTagsAsync(new ListUserTagsRequest { UserName = userName }, ct);
        return resp.Tags.Select(t => new IamTagModel { Key = t.Key, Value = t.Value }).ToList();
    }

    public async Task PutUserTagsAsync(string userName, Dictionary<string, string> tags, CancellationToken ct = default)
    {
        var client = Iam();
        var awsTags = tags.Select(kvp => new Amazon.IdentityManagement.Model.Tag { Key = kvp.Key, Value = kvp.Value }).ToList();
        await client.TagUserAsync(new Amazon.IdentityManagement.Model.TagUserRequest { UserName = userName, Tags = awsTags }, ct);
    }

    public async Task RemoveUserTagsAsync(string userName, List<string> tagKeys, CancellationToken ct = default)
    {
        var client = Iam();
        await client.UntagUserAsync(new Amazon.IdentityManagement.Model.UntagUserRequest { UserName = userName, TagKeys = tagKeys }, ct);
    }

    public async Task EnrichRoleAsync(IamRoleModel role, CancellationToken ct = default)
    {
        var client = Iam();
        await Task.WhenAll(
            SafeAsync(async () =>
            {
                var r = await client.ListAttachedRolePoliciesAsync(
                    new ListAttachedRolePoliciesRequest { RoleName = role.RoleName }, ct);
                role.AttachedPolicies = r.AttachedPolicies.Select(p => p.PolicyName).ToList();
            }),
            SafeAsync(async () =>
            {
                var r = await client.ListRolePoliciesAsync(
                    new ListRolePoliciesRequest { RoleName = role.RoleName }, ct);
                role.InlinePolicies = r.PolicyNames.ToList();
            })
        );
    }

    public async Task EnrichGroupAsync(IamGroupModel group, CancellationToken ct = default)
    {
        var client = Iam();
        await Task.WhenAll(
            SafeAsync(async () =>
            {
                var r = await client.GetGroupAsync(
                    new GetGroupRequest { GroupName = group.GroupName }, ct);
                group.UserCount = r.Users.Count;
            }),
            SafeAsync(async () =>
            {
                var r = await client.ListAttachedGroupPoliciesAsync(
                    new ListAttachedGroupPoliciesRequest { GroupName = group.GroupName }, ct);
                group.AttachedPolicies = r.AttachedPolicies.Select(p => p.PolicyName).ToList();
            }),
            SafeAsync(async () =>
            {
                var r = await client.ListGroupPoliciesAsync(
                    new ListGroupPoliciesRequest { GroupName = group.GroupName }, ct);
                group.InlinePolicies = r.PolicyNames.ToList();
            })
        );
    }

    // ── Create operations ────────────────────────────────────────────────────

    public async Task<IamUserModel> CreateUserAsync(CreateUserOptions options, CancellationToken ct = default)
    {
        var client = Iam();
        var resp = await client.CreateUserAsync(new CreateUserRequest { UserName = options.UserName }, ct);
        var u    = resp.User;

        if (options.ConsoleAccess && !string.IsNullOrEmpty(options.Password))
            await client.CreateLoginProfileAsync(new CreateLoginProfileRequest
            {
                UserName              = options.UserName,
                Password              = options.Password,
                PasswordResetRequired = options.RequirePasswordReset,
            }, ct);

        switch (options.PermissionMode)
        {
            case CreateUserPermissionMode.AddToGroup:
                await Task.WhenAll(options.GroupNames.Select(g =>
                    client.AddUserToGroupAsync(new AddUserToGroupRequest { UserName = options.UserName, GroupName = g }, ct)));
                break;

            case CreateUserPermissionMode.AttachPolicies:
                await Task.WhenAll(options.PolicyArns.Select(arn =>
                    client.AttachUserPolicyAsync(new AttachUserPolicyRequest { UserName = options.UserName, PolicyArn = arn }, ct)));
                break;

            case CreateUserPermissionMode.CopyPermissions when options.CopyFromUser != null:
                var fromGroups   = await client.ListGroupsForUserAsync(new ListGroupsForUserRequest { UserName = options.CopyFromUser }, ct);
                var fromPolicies = await client.ListAttachedUserPoliciesAsync(new ListAttachedUserPoliciesRequest { UserName = options.CopyFromUser }, ct);
                await Task.WhenAll(
                    Task.WhenAll(fromGroups.Groups.Select(g =>
                        client.AddUserToGroupAsync(new AddUserToGroupRequest { UserName = options.UserName, GroupName = g.GroupName }, ct))),
                    Task.WhenAll(fromPolicies.AttachedPolicies.Select(p =>
                        client.AttachUserPolicyAsync(new AttachUserPolicyRequest { UserName = options.UserName, PolicyArn = p.PolicyArn }, ct)))
                );
                break;
        }

        return new IamUserModel
        {
            UserName   = u.UserName,
            UserId     = u.UserId,
            Arn        = u.Arn,
            Path       = D(u.Path),
            CreateDate = u.CreateDate,
        };
    }

    // ── Delete operations ────────────────────────────────────────────────────

    public async Task DeleteUsersAsync(IReadOnlyList<IamUserModel> users, CancellationToken ct = default)
    {
        var client = Iam();
        await Task.WhenAll(users.Select(u => DeleteUserAsync(client, u, ct)));
    }

    private static async Task DeleteUserAsync(AmazonIdentityManagementServiceClient client, IamUserModel user, CancellationToken ct)
    {
        var name = user.UserName;

        // Fetch all prerequisite lists in parallel
        var keysTask        = client.ListAccessKeysAsync(new ListAccessKeysRequest { UserName = name }, ct);
        var groupsTask      = client.ListGroupsForUserAsync(new ListGroupsForUserRequest { UserName = name }, ct);
        var attachedTask    = client.ListAttachedUserPoliciesAsync(new ListAttachedUserPoliciesRequest { UserName = name }, ct);
        var inlineTask      = client.ListUserPoliciesAsync(new ListUserPoliciesRequest { UserName = name }, ct);
        var mfaTask         = client.ListMFADevicesAsync(new ListMFADevicesRequest { UserName = name }, ct);
        var certsTask       = client.ListSigningCertificatesAsync(new ListSigningCertificatesRequest { UserName = name }, ct);
        var sshTask         = client.ListSSHPublicKeysAsync(new ListSSHPublicKeysRequest { UserName = name }, ct);
        var svcCredsTask    = client.ListServiceSpecificCredentialsAsync(new ListServiceSpecificCredentialsRequest { UserName = name }, ct);

        await Task.WhenAll(keysTask, groupsTask, attachedTask, inlineTask, mfaTask, certsTask, sshTask, svcCredsTask);

        var deletions = new List<Task>();

        // Access keys
        deletions.AddRange((await keysTask).AccessKeyMetadata.Select(k =>
            client.DeleteAccessKeyAsync(new DeleteAccessKeyRequest { UserName = name, AccessKeyId = k.AccessKeyId }, ct)));

        // Group memberships
        deletions.AddRange((await groupsTask).Groups.Select(g =>
            client.RemoveUserFromGroupAsync(new RemoveUserFromGroupRequest { UserName = name, GroupName = g.GroupName }, ct)));

        // Managed policies
        deletions.AddRange((await attachedTask).AttachedPolicies.Select(p =>
            client.DetachUserPolicyAsync(new DetachUserPolicyRequest { UserName = name, PolicyArn = p.PolicyArn }, ct)));

        // Inline policies
        deletions.AddRange((await inlineTask).PolicyNames.Select(p =>
            client.DeleteUserPolicyAsync(new DeleteUserPolicyRequest { UserName = name, PolicyName = p }, ct)));

        // MFA devices — deactivate first, then delete virtual ones
        foreach (var mfa in (await mfaTask).MFADevices)
        {
            deletions.Add(DeactivateAndDeleteMfaAsync(client, name, mfa.SerialNumber, ct));
        }

        // Signing certificates
        deletions.AddRange((await certsTask).Certificates.Select(c =>
            client.DeleteSigningCertificateAsync(new DeleteSigningCertificateRequest { UserName = name, CertificateId = c.CertificateId }, ct)));

        // SSH public keys
        deletions.AddRange((await sshTask).SSHPublicKeys.Select(k =>
            client.DeleteSSHPublicKeyAsync(new DeleteSSHPublicKeyRequest { UserName = name, SSHPublicKeyId = k.SSHPublicKeyId }, ct)));

        // Service-specific credentials
        deletions.AddRange((await svcCredsTask).ServiceSpecificCredentials.Select(c =>
            client.DeleteServiceSpecificCredentialAsync(new DeleteServiceSpecificCredentialRequest { UserName = name, ServiceSpecificCredentialId = c.ServiceSpecificCredentialId }, ct)));

        await Task.WhenAll(deletions);

        // Delete console login profile (best-effort — NoSuchEntityException if user has none)
        try { await client.DeleteLoginProfileAsync(new DeleteLoginProfileRequest { UserName = name }, ct); }
        catch { /* user may not have a login profile */ }

        await client.DeleteUserAsync(new DeleteUserRequest { UserName = name }, ct);
    }

    private static async Task DeactivateAndDeleteMfaAsync(AmazonIdentityManagementServiceClient client, string userName, string serial, CancellationToken ct)
    {
        await client.DeactivateMFADeviceAsync(new DeactivateMFADeviceRequest { UserName = userName, SerialNumber = serial }, ct);
        // Virtual MFA devices have an ARN (arn:aws:iam::...) — hardware tokens have a serial like GAKT...
        if (serial.StartsWith("arn:", StringComparison.OrdinalIgnoreCase))
            await client.DeleteVirtualMFADeviceAsync(new DeleteVirtualMFADeviceRequest { SerialNumber = serial }, ct);
    }

    public async Task DeleteRolesAsync(IReadOnlyList<IamRoleModel> roles, CancellationToken ct = default)
    {
        var client = Iam();
        await Task.WhenAll(roles.Select(r => DeleteRoleAsync(client, r, ct)));
    }

    private static async Task DeleteRoleAsync(AmazonIdentityManagementServiceClient client, IamRoleModel role, CancellationToken ct)
    {
        var name = role.RoleName;

        // 1. Detach managed policies
        var attached = await client.ListAttachedRolePoliciesAsync(new ListAttachedRolePoliciesRequest { RoleName = name }, ct);
        await Task.WhenAll(attached.AttachedPolicies.Select(p =>
            client.DetachRolePolicyAsync(new DetachRolePolicyRequest { RoleName = name, PolicyArn = p.PolicyArn }, ct)));

        // 2. Delete inline policies
        var inline = await client.ListRolePoliciesAsync(new ListRolePoliciesRequest { RoleName = name }, ct);
        await Task.WhenAll(inline.PolicyNames.Select(p =>
            client.DeleteRolePolicyAsync(new DeleteRolePolicyRequest { RoleName = name, PolicyName = p }, ct)));

        // 3. Remove from instance profiles
        var profiles = await client.ListInstanceProfilesForRoleAsync(new ListInstanceProfilesForRoleRequest { RoleName = name }, ct);
        await Task.WhenAll(profiles.InstanceProfiles.Select(ip =>
            client.RemoveRoleFromInstanceProfileAsync(new RemoveRoleFromInstanceProfileRequest { RoleName = name, InstanceProfileName = ip.InstanceProfileName }, ct)));

        await client.DeleteRoleAsync(new DeleteRoleRequest { RoleName = name }, ct);
    }

    public async Task DeleteGroupsAsync(IReadOnlyList<IamGroupModel> groups, CancellationToken ct = default)
    {
        var client = Iam();
        await Task.WhenAll(groups.Select(g => DeleteGroupAsync(client, g, ct)));
    }

    private static async Task DeleteGroupAsync(AmazonIdentityManagementServiceClient client, IamGroupModel group, CancellationToken ct)
    {
        var name = group.GroupName;

        // 1. Remove all users
        var members = await client.GetGroupAsync(new GetGroupRequest { GroupName = name }, ct);
        await Task.WhenAll(members.Users.Select(u =>
            client.RemoveUserFromGroupAsync(new RemoveUserFromGroupRequest { GroupName = name, UserName = u.UserName }, ct)));

        // 2. Detach managed policies
        var attached = await client.ListAttachedGroupPoliciesAsync(new ListAttachedGroupPoliciesRequest { GroupName = name }, ct);
        await Task.WhenAll(attached.AttachedPolicies.Select(p =>
            client.DetachGroupPolicyAsync(new DetachGroupPolicyRequest { GroupName = name, PolicyArn = p.PolicyArn }, ct)));

        // 3. Delete inline policies
        var inline = await client.ListGroupPoliciesAsync(new ListGroupPoliciesRequest { GroupName = name }, ct);
        await Task.WhenAll(inline.PolicyNames.Select(p =>
            client.DeleteGroupPolicyAsync(new DeleteGroupPolicyRequest { GroupName = name, PolicyName = p }, ct)));

        await client.DeleteGroupAsync(new DeleteGroupRequest { GroupName = name }, ct);
    }

    public async Task DeletePoliciesAsync(IReadOnlyList<IamPolicyModel> policies, CancellationToken ct = default)
    {
        var client = Iam();
        await Task.WhenAll(policies.Select(p => DeletePolicyAsync(client, p, ct)));
    }

    private static async Task DeletePolicyAsync(AmazonIdentityManagementServiceClient client, IamPolicyModel policy, CancellationToken ct)
    {
        var arn = policy.Arn;

        // 1. Detach from all entities
        var entities = await client.ListEntitiesForPolicyAsync(new ListEntitiesForPolicyRequest { PolicyArn = arn }, ct);
        var detachTasks = new List<Task>();
        detachTasks.AddRange(entities.PolicyUsers.Select(u =>
            client.DetachUserPolicyAsync(new DetachUserPolicyRequest { UserName = u.UserName, PolicyArn = arn }, ct)));
        detachTasks.AddRange(entities.PolicyRoles.Select(r =>
            client.DetachRolePolicyAsync(new DetachRolePolicyRequest { RoleName = r.RoleName, PolicyArn = arn }, ct)));
        detachTasks.AddRange(entities.PolicyGroups.Select(g =>
            client.DetachGroupPolicyAsync(new DetachGroupPolicyRequest { GroupName = g.GroupName, PolicyArn = arn }, ct)));
        await Task.WhenAll(detachTasks);

        // 2. Delete all non-default versions
        var versions = await client.ListPolicyVersionsAsync(new ListPolicyVersionsRequest { PolicyArn = arn }, ct);
        await Task.WhenAll(versions.Versions
            .Where(v => !v.IsDefaultVersion)
            .Select(v => client.DeletePolicyVersionAsync(new DeletePolicyVersionRequest { PolicyArn = arn, VersionId = v.VersionId }, ct)));

        await client.DeletePolicyAsync(new DeletePolicyRequest { PolicyArn = arn }, ct);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private static async Task SafeAsync(Func<Task> action)
    {
        try { await action(); }
        catch (OperationCanceledException) { throw; } // propagate — let callers handle cancellation
        catch { /* swallow other errors — enrichment is best-effort */ }
    }

    private static string ParseTrustedEntities(string? policyDoc)
    {
        if (string.IsNullOrEmpty(policyDoc)) return "—";
        try
        {
            var decoded = Uri.UnescapeDataString(policyDoc);
            using var doc = JsonDocument.Parse(decoded);

            var entities = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            if (doc.RootElement.TryGetProperty("Statement", out var statements))
            {
                foreach (var stmt in statements.EnumerateArray())
                {
                    if (!stmt.TryGetProperty("Principal", out var principal)) continue;

                    ExtractPrincipals(principal, entities);
                }
            }

            return entities.Count > 0 ? string.Join(", ", entities) : "—";
        }
        catch { return "—"; }
    }

    private static void ExtractPrincipals(JsonElement principal, HashSet<string> entities)
    {
        // Principal can be "*", a string, or an object with "Service"/"AWS"/"Federated" keys
        if (principal.ValueKind == JsonValueKind.String)
        {
            entities.Add(principal.GetString()!);
            return;
        }

        if (principal.ValueKind != JsonValueKind.Object) return;

        foreach (var key in new[] { "Service", "AWS", "Federated" })
        {
            if (!principal.TryGetProperty(key, out var value)) continue;

            if (value.ValueKind == JsonValueKind.String)
                entities.Add(value.GetString()!);
            else if (value.ValueKind == JsonValueKind.Array)
                foreach (var item in value.EnumerateArray())
                    if (item.ValueKind == JsonValueKind.String)
                        entities.Add(item.GetString()!);
        }
    }
}
