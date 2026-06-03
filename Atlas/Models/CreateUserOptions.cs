namespace Atlas.Models;

public enum CreateUserPermissionMode { None, AddToGroup, CopyPermissions, AttachPolicies }

public class CreateUserOptions
{
    public string UserName { get; set; } = string.Empty;

    // Console access
    public bool   ConsoleAccess          { get; set; }
    public string Password               { get; set; } = string.Empty;
    public bool   RequirePasswordReset   { get; set; } = true;

    // Permissions
    public CreateUserPermissionMode PermissionMode { get; set; } = CreateUserPermissionMode.None;
    public List<string> GroupNames  { get; set; } = [];   // AddToGroup
    public List<string> PolicyArns  { get; set; } = [];   // AttachPolicies
    public string?      CopyFromUser { get; set; }        // CopyPermissions
}
