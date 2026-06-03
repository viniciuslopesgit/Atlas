using Atlas.Models;

namespace Atlas.Services.AWS;

public interface IIamService
{
    // Fast: one paginated call per entity type
    Task<IReadOnlyList<IamUserModel>>   GetUsersAsync(CancellationToken ct = default);
    Task<IReadOnlyList<IamRoleModel>>   GetRolesAsync(CancellationToken ct = default);
    Task<IReadOnlyList<IamGroupModel>>  GetGroupsAsync(CancellationToken ct = default);
    Task<IReadOnlyList<IamPolicyModel>> GetPoliciesAsync(CancellationToken ct = default);

    // On-demand enrichment (called only when an item is selected)
    Task EnrichUserAsync(IamUserModel user, CancellationToken ct = default);
    Task EnrichRoleAsync(IamRoleModel role, CancellationToken ct = default);
    Task EnrichGroupAsync(IamGroupModel group, CancellationToken ct = default);

    // Create
    Task<IamUserModel> CreateUserAsync(CreateUserOptions options, CancellationToken ct = default);

    // Destructive operations (detach/clean prerequisites, then delete)
    Task DeleteUsersAsync(IReadOnlyList<IamUserModel> users, CancellationToken ct = default);
    Task DeleteRolesAsync(IReadOnlyList<IamRoleModel> roles, CancellationToken ct = default);
    Task DeleteGroupsAsync(IReadOnlyList<IamGroupModel> groups, CancellationToken ct = default);
    Task DeletePoliciesAsync(IReadOnlyList<IamPolicyModel> policies, CancellationToken ct = default);

    // Access key management
    Task<List<AccessKeyInfo>> ListAccessKeysAsync(string userName, CancellationToken ct = default);
    Task<(string AccessKeyId, string SecretAccessKey)> CreateAccessKeyAsync(string userName, CancellationToken ct = default);
    Task DeleteAccessKeyAsync(string userName, string accessKeyId, CancellationToken ct = default);
    Task UpdateAccessKeyStatusAsync(string userName, string accessKeyId, bool active, CancellationToken ct = default);

    // Policy management for user
    Task AttachUserPolicyAsync(string userName, string policyArn, CancellationToken ct = default);
    Task DetachUserPolicyAsync(string userName, string policyArn, CancellationToken ct = default);

    // Group membership for user
    Task AddUserToGroupAsync(string userName, string groupName, CancellationToken ct = default);
    Task RemoveUserFromGroupAsync(string userName, string groupName, CancellationToken ct = default);

    // Tags
    Task<List<IamTagModel>> ListUserTagsAsync(string userName, CancellationToken ct = default);
    Task PutUserTagsAsync(string userName, Dictionary<string, string> tags, CancellationToken ct = default);
    Task RemoveUserTagsAsync(string userName, List<string> tagKeys, CancellationToken ct = default);
}
