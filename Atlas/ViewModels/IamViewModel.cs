using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Infrastructure.Logging;
using Atlas.Models;
using Atlas.Services;
using Atlas.Services.AWS;
using Atlas.Views;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using System.Windows.Data;

namespace Atlas.ViewModels;

public enum IamTab { Users, Roles, Groups, Policies }

public partial class IamViewModel : AsyncViewModel
{
    private readonly IIamService     _iam;
    private readonly IAccountService _accounts;
    private readonly IDialogService  _dialog;

    protected override int StalenessSeconds => 300;

    // Backing stores — never replaced after construction
    private readonly ObservableCollection<IamUserModel>   _usersSource    = [];
    private readonly ObservableCollection<IamRoleModel>   _rolesSource    = [];
    private readonly ObservableCollection<IamGroupModel>  _groupsSource   = [];
    private readonly ObservableCollection<IamPolicyModel> _policiesSource = [];

    public ICollectionView UsersView    { get; }
    public ICollectionView RolesView    { get; }
    public ICollectionView GroupsView   { get; }
    public ICollectionView PoliciesView { get; }

    private readonly HashSet<string>    _enrichedUsers  = [];
    private readonly HashSet<string>    _enrichedRoles  = [];
    private readonly HashSet<string>    _enrichedGroups = [];
    private readonly object             _enrichLock     = new();
    private CancellationTokenSource?    _enrichCts;
    private CancellationTokenSource?    _enrichRoleCts;
    private CancellationTokenSource?    _enrichGroupCts;

    // ── Per-tab selection lists (populated by code-behind) ────────────────
    public List<IamUserModel>   SelectedUserItems   { get; } = [];
    public List<IamRoleModel>   SelectedRoleItems   { get; } = [];
    public List<IamGroupModel>  SelectedGroupItems  { get; } = [];
    public List<IamPolicyModel> SelectedPolicyItems { get; } = [];

    [ObservableProperty] private IamTab _activeTab = IamTab.Users;
    [ObservableProperty] private string _filterText = string.Empty;

    // Single selected item for detail panel (only when count == 1)
    [ObservableProperty] private IamUserModel?   _selectedUser;
    [ObservableProperty] private IamRoleModel?   _selectedRole;
    [ObservableProperty] private IamGroupModel?  _selectedGroup;
    [ObservableProperty] private IamPolicyModel? _selectedPolicy;

    // Selection counts per tab
    [ObservableProperty] private int  _selectedUserCount;
    [ObservableProperty] private int  _selectedRoleCount;
    [ObservableProperty] private int  _selectedGroupCount;
    [ObservableProperty] private int  _selectedPolicyCount;

    // Header checkbox state per tab
    [ObservableProperty] private bool _areAllUsersSelected;
    [ObservableProperty] private bool _areAllRolesSelected;
    [ObservableProperty] private bool _areAllGroupsSelected;
    [ObservableProperty] private bool _areAllPoliciesSelected;

    [ObservableProperty] private bool _isEnriching;
    [ObservableProperty] private bool _isDeleting;

    // ── User detail tab ───────────────────────────────────────────────────
    [ObservableProperty] private string _selectedDetailTab = "Permissions";
    [ObservableProperty] private string? _selectedPolicyInDetail;
    [ObservableProperty] private string? _selectedGroupInDetail;
    [ObservableProperty] private bool _isTagEditing;

    // Tag edit staging
    [ObservableProperty] private string _newTagKey   = string.Empty;
    [ObservableProperty] private string _newTagValue = string.Empty;

    // Policy add staging
    [ObservableProperty] private string _addPolicyArn = string.Empty;

    // Group add staging
    [ObservableProperty] private string _addGroupName = string.Empty;

    public ObservableCollection<AccessKeyInfo> SelectedUserAccessKeys { get; } = [];
    public ObservableCollection<IamTagModel>   SelectedUserTags       { get; } = [];

    public bool IsUsersTab    => ActiveTab == IamTab.Users;
    public bool IsRolesTab    => ActiveTab == IamTab.Roles;
    public bool IsGroupsTab   => ActiveTab == IamTab.Groups;
    public bool IsPoliciesTab => ActiveTab == IamTab.Policies;

    public bool HasUserSelection   => SelectedUserCount   > 0;
    public bool HasRoleSelection   => SelectedRoleCount   > 0;
    public bool HasGroupSelection  => SelectedGroupCount  > 0;
    public bool HasPolicySelection => SelectedPolicyCount > 0;

    // Drives the resize panel column
    public bool HasSelection =>
        HasUserSelection || HasRoleSelection ||
        HasGroupSelection || HasPolicySelection;

    // Cached counts — refreshed in RefreshViews() to avoid iterating the view on every binding read
    private int _usersCount;
    private int _rolesCount;
    private int _groupsCount;
    private int _policiesCount;

    public int CurrentCount => ActiveTab switch
    {
        IamTab.Users    => _usersCount,
        IamTab.Roles    => _rolesCount,
        IamTab.Groups   => _groupsCount,
        IamTab.Policies => _policiesCount,
        _               => 0
    };

    public string CurrentTabLabel => ActiveTab switch
    {
        IamTab.Users    => "users",
        IamTab.Roles    => "roles",
        IamTab.Groups   => "groups",
        IamTab.Policies => "policies",
        _               => "items"
    };

    public IamViewModel(IIamService iam, IAccountService accounts, IDialogService dialog)
    {
        _iam      = iam;
        _accounts = accounts;
        _dialog   = dialog;

        UsersView    = CollectionViewSource.GetDefaultView(_usersSource);
        RolesView    = CollectionViewSource.GetDefaultView(_rolesSource);
        GroupsView   = CollectionViewSource.GetDefaultView(_groupsSource);
        PoliciesView = CollectionViewSource.GetDefaultView(_policiesSource);

        UsersView.Filter    = o => MatchesUser(o as IamUserModel);
        RolesView.Filter    = o => MatchesRole(o as IamRoleModel);
        GroupsView.Filter   = o => MatchesGroup(o as IamGroupModel);
        PoliciesView.Filter = o => MatchesPolicy(o as IamPolicyModel);

        _accounts.ActiveAccountChanged += OnAccountChanged;
    }

    private void OnAccountChanged(object? s, EventArgs e)
    {
        // Cancel and dispose any in-flight enrichment before clearing the tracking sets
        _enrichCts?.Cancel();
        _enrichCts?.Dispose();
        _enrichCts = null;

        _enrichRoleCts?.Cancel();
        _enrichRoleCts?.Dispose();
        _enrichRoleCts = null;

        _enrichGroupCts?.Cancel();
        _enrichGroupCts?.Dispose();
        _enrichGroupCts = null;

        IsEnriching = false;

        lock (_enrichLock)
        {
            _enrichedUsers.Clear();
            _enrichedRoles.Clear();
            _enrichedGroups.Clear();
        }

        _ = LoadAsync(force: true);
    }

    [RelayCommand]
    private void SwitchTab(IamTab tab)
    {
        if (ActiveTab == tab) return;

        // Cancel any in-flight enrichment from the outgoing tab so it cannot
        // set IsEnriching = false and corrupt the incoming tab's loading state.
        _enrichCts?.Cancel();
        _enrichCts?.Dispose();
        _enrichCts = null;
        _enrichRoleCts?.Cancel();
        _enrichRoleCts?.Dispose();
        _enrichRoleCts = null;
        _enrichGroupCts?.Cancel();
        _enrichGroupCts?.Dispose();
        _enrichGroupCts = null;
        IsEnriching = false;

        ActiveTab  = tab;
        FilterText = string.Empty;
        RefreshViews();
    }

    [RelayCommand]
    public async Task LoadAsync(bool force = false)
    {
        if (_accounts.ActiveAccount == null) return;
        if (IsLoading) return;
        if (!force && !IsDataStale) return;

        var ct = BeginLoad();
        try
        {
            var usersTask    = _iam.GetUsersAsync(ct);
            var rolesTask    = _iam.GetRolesAsync(ct);
            var groupsTask   = _iam.GetGroupsAsync(ct);
            var policiesTask = _iam.GetPoliciesAsync(ct);

            await Task.WhenAll(usersTask, rolesTask, groupsTask, policiesTask);

            ReplaceAll(_usersSource,    await usersTask);
            ReplaceAll(_rolesSource,    await rolesTask);
            ReplaceAll(_groupsSource,   await groupsTask);
            ReplaceAll(_policiesSource, await policiesTask);

            lock (_enrichLock)
            {
                _enrichedUsers.Clear();
                _enrichedRoles.Clear();
                _enrichedGroups.Clear();
            }

            RefreshViews();
            EndLoad();
        }
        catch (Exception ex)
        {
            HandleError("IamViewModel.LoadAsync", ex);
        }
    }

    // ── Create ────────────────────────────────────────────────────────────

    [RelayCommand]
    private async Task CreateUserAsync()
    {
        var dialog = new CreateUserDialog(
            _groupsSource.ToList(),
            _policiesSource.ToList())
        {
            Owner = Application.Current.MainWindow
        };

        dialog.ShowDialog();
        if (!dialog.Confirmed || dialog.Result == null) return;

        try
        {
            var newUser = await _iam.CreateUserAsync(dialog.Result);
            _usersSource.Add(newUser);
            RefreshViews();
        }
        catch (Exception ex)
        {
            HandleError("IamViewModel.CreateUserAsync", ex);
        }
    }

    // ── Delete ────────────────────────────────────────────────────────────

    [RelayCommand]
    private async Task DeleteSelectedAsync()
    {
        if (IsDeleting) return;

        (string kind, int count) = ActiveTab switch
        {
            IamTab.Users    => ("user",   SelectedUserCount),
            IamTab.Roles    => ("role",   SelectedRoleCount),
            IamTab.Groups   => ("group",  SelectedGroupCount),
            IamTab.Policies => ("policy", SelectedPolicyCount),
            _               => ("item",   0)
        };

        if (count == 0) return;

        var noun = count == 1 ? kind : kind + "s";
        var list = ActiveTab switch
        {
            IamTab.Users    => string.Join("\n", SelectedUserItems.Select(u => $"• {u.UserName}")),
            IamTab.Roles    => string.Join("\n", SelectedRoleItems.Select(r => $"• {r.RoleName}")),
            IamTab.Groups   => string.Join("\n", SelectedGroupItems.Select(g => $"• {g.GroupName}")),
            IamTab.Policies => string.Join("\n", SelectedPolicyItems.Select(p => $"• {p.PolicyName}")),
            _               => string.Empty
        };

        if (!_dialog.Confirm(
                $"Delete {noun}",
                $"Permanently delete {count} {noun}? This action cannot be undone.\n\n{list}",
                DialogKind.Danger))
            return;

        IsDeleting = true;
        try
        {
            switch (ActiveTab)
            {
                case IamTab.Users:
                    var users = SelectedUserItems.ToList();
                    await _iam.DeleteUsersAsync(users);
                    foreach (var u in users) { _usersSource.Remove(u); lock (_enrichLock) _enrichedUsers.Remove(u.UserId); }
                    break;

                case IamTab.Roles:
                    var roles = SelectedRoleItems.ToList();
                    await _iam.DeleteRolesAsync(roles);
                    foreach (var r in roles) { _rolesSource.Remove(r); lock (_enrichLock) _enrichedRoles.Remove(r.RoleId); }
                    break;

                case IamTab.Groups:
                    var groups = SelectedGroupItems.ToList();
                    await _iam.DeleteGroupsAsync(groups);
                    foreach (var g in groups) { _groupsSource.Remove(g); lock (_enrichLock) _enrichedGroups.Remove(g.GroupId); }
                    break;

                case IamTab.Policies:
                    var policies = SelectedPolicyItems.ToList();
                    await _iam.DeletePoliciesAsync(policies);
                    foreach (var p in policies) _policiesSource.Remove(p);
                    break;
            }

            RefreshViews();
        }
        catch (Exception ex)
        {
            HandleError("IamViewModel.DeleteSelectedAsync", ex);
        }
        finally
        {
            IsDeleting = false;
        }
    }

    // ── Selection updates (called from code-behind) ───────────────────────

    public void UpdateUserSelection(System.Collections.IList items)
    {
        SelectedUserItems.Clear();
        foreach (IamUserModel item in items) SelectedUserItems.Add(item);

        SelectedUserCount      = SelectedUserItems.Count;
        AreAllUsersSelected    = _usersSource.Count > 0 && SelectedUserCount == UsersView.Cast<object>().Count();
        SelectedUser           = SelectedUserCount == 1 ? SelectedUserItems[0] : null;

        OnPropertyChanged(nameof(HasUserSelection));
        OnPropertyChanged(nameof(HasSelection));
    }

    public void UpdateRoleSelection(System.Collections.IList items)
    {
        SelectedRoleItems.Clear();
        foreach (IamRoleModel item in items) SelectedRoleItems.Add(item);

        SelectedRoleCount      = SelectedRoleItems.Count;
        AreAllRolesSelected    = _rolesSource.Count > 0 && SelectedRoleCount == RolesView.Cast<object>().Count();
        SelectedRole           = SelectedRoleCount == 1 ? SelectedRoleItems[0] : null;

        OnPropertyChanged(nameof(HasRoleSelection));
        OnPropertyChanged(nameof(HasSelection));
    }

    public void UpdateGroupSelection(System.Collections.IList items)
    {
        SelectedGroupItems.Clear();
        foreach (IamGroupModel item in items) SelectedGroupItems.Add(item);

        SelectedGroupCount     = SelectedGroupItems.Count;
        AreAllGroupsSelected   = _groupsSource.Count > 0 && SelectedGroupCount == GroupsView.Cast<object>().Count();
        SelectedGroup          = SelectedGroupCount == 1 ? SelectedGroupItems[0] : null;

        OnPropertyChanged(nameof(HasGroupSelection));
        OnPropertyChanged(nameof(HasSelection));
    }

    public void UpdatePolicySelection(System.Collections.IList items)
    {
        SelectedPolicyItems.Clear();
        foreach (IamPolicyModel item in items) SelectedPolicyItems.Add(item);

        SelectedPolicyCount    = SelectedPolicyItems.Count;
        AreAllPoliciesSelected = _policiesSource.Count > 0 && SelectedPolicyCount == PoliciesView.Cast<object>().Count();
        SelectedPolicy         = SelectedPolicyCount == 1 ? SelectedPolicyItems[0] : null;

        OnPropertyChanged(nameof(HasPolicySelection));
        OnPropertyChanged(nameof(HasSelection));
    }

    // ── On-demand enrichment ──────────────────────────────────────────────

    async partial void OnSelectedUserChanged(IamUserModel? value)
    {
        OnPropertyChanged(nameof(HasSelection));
        SelectedDetailTab      = "Permissions";
        SelectedPolicyInDetail = null;
        SelectedGroupInDetail  = null;
        IsTagEditing           = false;
        SelectedUserAccessKeys.Clear();
        SelectedUserTags.Clear();

        // Cancel in-flight enrichment and reset loading state immediately
        // (handles deselect + rapid re-selection without leaving IsEnriching = true)
        _enrichCts?.Cancel();
        _enrichCts?.Dispose();
        _enrichCts = null;
        IsEnriching = false;

        if (value == null) return;

        bool needsEnrich;
        lock (_enrichLock) needsEnrich = !_enrichedUsers.Contains(value.UserId);

        if (needsEnrich)
        {
            IsEnriching = true;
            var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            _enrichCts = cts;
            try
            {
                await _iam.EnrichUserAsync(value, cts.Token);

                // Only commit if this user is still selected
                if (SelectedUser?.UserId == value.UserId)
                {
                    lock (_enrichLock) _enrichedUsers.Add(value.UserId);
                    OnPropertyChanged(nameof(SelectedUser));
                }
            }
            catch (OperationCanceledException) { /* selection changed or timed out */ }
            catch (Exception ex) { FileLogger.Error("EnrichUser", ex); }
            finally
            {
                // Only clear loading state if we're still the active enrichment;
                // if a newer selection replaced us, it owns IsEnriching now.
                if (_enrichCts == cts)
                {
                    IsEnriching = false;
                    _enrichCts  = null;
                    cts.Dispose();
                }
            }
        }

        // Sync observable collections from the model (always on UI thread via async partial void)
        if (SelectedUser?.UserId == value.UserId)
            SyncUserDetailCollections(value);
    }

    private void SyncUserDetailCollections(IamUserModel user)
    {
        // async partial void always resumes on the UI thread — no Dispatcher.Invoke needed
        SelectedUserAccessKeys.Clear();
        foreach (var k in user.AccessKeys) SelectedUserAccessKeys.Add(k);
        SelectedUserTags.Clear();
        foreach (var t in user.Tags) SelectedUserTags.Add(t);
    }

    // ── Detail-tab commands ───────────────────────────────────────────────

    [RelayCommand]
    private void SwitchDetailTab(string tab) => SelectedDetailTab = tab;

    [RelayCommand]
    private void SelectPolicyInDetail(string? name) => SelectedPolicyInDetail = name;

    [RelayCommand]
    private void SelectGroupInDetail(string? name) => SelectedGroupInDetail = name;

    [RelayCommand]
    private async Task RemovePolicyAsync(string policyName)
    {
        if (SelectedUser == null || string.IsNullOrEmpty(policyName)) return;

        // 1. Check the user's own enriched policy refs (contains all policies, including AWS-managed)
        var arn = SelectedUser.AttachedPolicyRefs
            .FirstOrDefault(r => r.Name == policyName).Arn;

        // 2. Fallback: look in the locally loaded customer-managed policies source
        if (string.IsNullOrEmpty(arn))
            arn = _policiesSource.FirstOrDefault(p => p.PolicyName == policyName)?.Arn;

        if (string.IsNullOrEmpty(arn))
        {
            _dialog.Confirm("Remove policy",
                $"Cannot find ARN for \"{policyName}\". The policy list may not have loaded fully. Try refreshing, or detach it from the AWS console.",
                DialogKind.Default);
            return;
        }

        if (!_dialog.Confirm("Remove policy", $"Detach \"{policyName}\" from user \"{SelectedUser.UserName}\"?", DialogKind.Danger))
            return;

        try
        {
            await _iam.DetachUserPolicyAsync(SelectedUser.UserName, arn);
            SelectedUser.AttachedPolicies.Remove(policyName);
            SelectedUser.AttachedPolicyRefs.RemoveAll(r => r.Name == policyName);
            SelectedPolicyInDetail = null;
            OnPropertyChanged(nameof(SelectedUser));
        }
        catch (Exception ex)
        {
            HandleError("RemovePolicy", ex);
        }
    }

    [RelayCommand]
    private async Task AddPolicyAsync()
    {
        if (SelectedUser == null) return;
        var arn = AddPolicyArn.Trim();
        if (string.IsNullOrEmpty(arn)) return;

        try
        {
            await _iam.AttachUserPolicyAsync(SelectedUser.UserName, arn);
            // Derive a display name from the ARN (last segment)
            var name = arn.Contains('/') ? arn[(arn.LastIndexOf('/') + 1)..] : arn;
            if (!SelectedUser.AttachedPolicies.Contains(name))
                SelectedUser.AttachedPolicies.Add(name);
            AddPolicyArn = string.Empty;
            OnPropertyChanged(nameof(SelectedUser));
        }
        catch (Exception ex)
        {
            HandleError("AddPolicy", ex);
        }
    }

    [RelayCommand]
    private async Task RemoveFromGroupAsync(string groupName)
    {
        if (SelectedUser == null || string.IsNullOrEmpty(groupName)) return;

        if (!_dialog.Confirm("Remove from group", $"Remove user \"{SelectedUser.UserName}\" from group \"{groupName}\"?", DialogKind.Danger))
            return;

        try
        {
            await _iam.RemoveUserFromGroupAsync(SelectedUser.UserName, groupName);
            SelectedUser.Groups.Remove(groupName);
            SelectedGroupInDetail = null;
            OnPropertyChanged(nameof(SelectedUser));
        }
        catch (Exception ex)
        {
            HandleError("RemoveFromGroup", ex);
        }
    }

    [RelayCommand]
    private async Task AddToGroupAsync()
    {
        if (SelectedUser == null) return;
        var groupName = AddGroupName.Trim();
        if (string.IsNullOrEmpty(groupName)) return;

        try
        {
            await _iam.AddUserToGroupAsync(SelectedUser.UserName, groupName);
            if (!SelectedUser.Groups.Contains(groupName))
                SelectedUser.Groups.Add(groupName);
            AddGroupName = string.Empty;
            OnPropertyChanged(nameof(SelectedUser));
        }
        catch (Exception ex)
        {
            HandleError("AddToGroup", ex);
        }
    }

    [RelayCommand]
    private async Task CreateAccessKeyAsync()
    {
        if (SelectedUser == null) return;
        if (SelectedUserAccessKeys.Count >= 2)
        {
            _dialog.Confirm("Create access key", "IAM users can have at most 2 access keys. Delete an existing key first.", DialogKind.Default);
            return;
        }

        try
        {
            var (keyId, secret) = await _iam.CreateAccessKeyAsync(SelectedUser.UserName);
            var info = new AccessKeyInfo
            {
                AccessKeyId = keyId,
                Status      = "Active",
                CreateDate  = DateTime.UtcNow,
            };
            SelectedUser.AccessKeys.Add(info);
            SelectedUserAccessKeys.Add(info);
            SelectedUser.AccessKeyCount = SelectedUserAccessKeys.Count;

            // Show the secret — only chance to see it
            MessageBox.Show(
                $"Access key created successfully.\n\nKey ID: {keyId}\nSecret: {secret}\n\nSave the secret now — it will not be shown again.",
                "Access Key Created",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            HandleError("CreateAccessKey", ex);
        }
    }

    [RelayCommand]
    private async Task DeleteAccessKeyAsync(string accessKeyId)
    {
        if (SelectedUser == null || string.IsNullOrEmpty(accessKeyId)) return;

        if (!_dialog.Confirm("Delete access key", $"Permanently delete access key {accessKeyId}?", DialogKind.Danger))
            return;

        try
        {
            await _iam.DeleteAccessKeyAsync(SelectedUser.UserName, accessKeyId);
            var item = SelectedUserAccessKeys.FirstOrDefault(k => k.AccessKeyId == accessKeyId);
            if (item != null)
            {
                SelectedUserAccessKeys.Remove(item);
                SelectedUser.AccessKeys.Remove(item);
            }
            SelectedUser.AccessKeyCount = SelectedUserAccessKeys.Count;
        }
        catch (Exception ex)
        {
            HandleError("DeleteAccessKey", ex);
        }
    }

    [RelayCommand]
    private async Task ToggleAccessKeyAsync(string accessKeyId)
    {
        if (SelectedUser == null || string.IsNullOrEmpty(accessKeyId)) return;

        var item = SelectedUserAccessKeys.FirstOrDefault(k => k.AccessKeyId == accessKeyId);
        if (item == null) return;

        var newActive = !item.IsActive;
        try
        {
            await _iam.UpdateAccessKeyStatusAsync(SelectedUser.UserName, accessKeyId, newActive);
            item.Status = newActive ? "Active" : "Inactive";
            // Refresh the list binding
            var idx = SelectedUserAccessKeys.IndexOf(item);
            SelectedUserAccessKeys.RemoveAt(idx);
            SelectedUserAccessKeys.Insert(idx, item);
        }
        catch (Exception ex)
        {
            HandleError("ToggleAccessKey", ex);
        }
    }

    [RelayCommand]
    private void StartTagEditing() => IsTagEditing = true;

    [RelayCommand]
    private void CancelTagEditing()
    {
        IsTagEditing = false;
        NewTagKey    = string.Empty;
        NewTagValue  = string.Empty;
    }

    [RelayCommand]
    private void AddTagLocally()
    {
        if (string.IsNullOrWhiteSpace(NewTagKey)) return;
        var existing = SelectedUserTags.FirstOrDefault(t => t.Key == NewTagKey);
        if (existing != null) existing.Value = NewTagValue;
        else SelectedUserTags.Add(new IamTagModel { Key = NewTagKey, Value = NewTagValue });
        NewTagKey   = string.Empty;
        NewTagValue = string.Empty;
    }

    [RelayCommand]
    private async Task SaveTagsAsync()
    {
        if (SelectedUser == null) return;
        try
        {
            var dict = SelectedUserTags.ToDictionary(t => t.Key, t => t.Value);
            await _iam.PutUserTagsAsync(SelectedUser.UserName, dict);
            SelectedUser.Tags = SelectedUserTags.ToList();
            IsTagEditing = false;
        }
        catch (Exception ex)
        {
            HandleError("SaveTags", ex);
        }
    }

    [RelayCommand]
    private async Task RemoveTagAsync(IamTagModel tag)
    {
        if (SelectedUser == null || tag == null) return;
        try
        {
            await _iam.RemoveUserTagsAsync(SelectedUser.UserName, [tag.Key]);
            SelectedUserTags.Remove(tag);
            SelectedUser.Tags.Remove(tag);
        }
        catch (Exception ex)
        {
            HandleError("RemoveTag", ex);
        }
    }

    [RelayCommand]
    private void CopyToClipboard(string? text)
    {
        if (!string.IsNullOrEmpty(text))
            Clipboard.SetText(text);
    }

    async partial void OnSelectedRoleChanged(IamRoleModel? value)
    {
        OnPropertyChanged(nameof(HasSelection));

        _enrichRoleCts?.Cancel();
        _enrichRoleCts?.Dispose();
        _enrichRoleCts = null;
        IsEnriching    = false;

        if (value == null) return;

        bool needsEnrich;
        lock (_enrichLock) needsEnrich = !_enrichedRoles.Contains(value.RoleId);
        if (!needsEnrich) return;

        IsEnriching = true;
        var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        _enrichRoleCts = cts;
        try
        {
            await _iam.EnrichRoleAsync(value, cts.Token);
            if (SelectedRole?.RoleId == value.RoleId)
            {
                lock (_enrichLock) _enrichedRoles.Add(value.RoleId);
                OnPropertyChanged(nameof(SelectedRole));
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { FileLogger.Error("EnrichRole", ex); }
        finally
        {
            if (_enrichRoleCts == cts)
            {
                IsEnriching    = false;
                _enrichRoleCts = null;
                cts.Dispose();
            }
        }
    }

    async partial void OnSelectedGroupChanged(IamGroupModel? value)
    {
        OnPropertyChanged(nameof(HasSelection));

        _enrichGroupCts?.Cancel();
        _enrichGroupCts?.Dispose();
        _enrichGroupCts = null;
        IsEnriching     = false;

        if (value == null) return;

        bool needsEnrich;
        lock (_enrichLock) needsEnrich = !_enrichedGroups.Contains(value.GroupId);
        if (!needsEnrich) return;

        IsEnriching = true;
        var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        _enrichGroupCts = cts;
        try
        {
            await _iam.EnrichGroupAsync(value, cts.Token);
            if (SelectedGroup?.GroupId == value.GroupId)
            {
                lock (_enrichLock) _enrichedGroups.Add(value.GroupId);
                OnPropertyChanged(nameof(SelectedGroup));
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { FileLogger.Error("EnrichGroup", ex); }
        finally
        {
            if (_enrichGroupCts == cts)
            {
                IsEnriching     = false;
                _enrichGroupCts = null;
                cts.Dispose();
            }
        }
    }

    partial void OnSelectedPolicyChanged(IamPolicyModel? value) =>
        OnPropertyChanged(nameof(HasSelection));

    // ── Filtering ──────────────────────────────────────────────────────────

    partial void OnFilterTextChanged(string value) => RefreshViews();

    partial void OnActiveTabChanged(IamTab value)
    {
        OnPropertyChanged(nameof(IsUsersTab));
        OnPropertyChanged(nameof(IsRolesTab));
        OnPropertyChanged(nameof(IsGroupsTab));
        OnPropertyChanged(nameof(IsPoliciesTab));
        OnPropertyChanged(nameof(CurrentTabLabel));
        OnPropertyChanged(nameof(CurrentCount));
    }

    private void RefreshViews()
    {
        UsersView.Refresh();
        RolesView.Refresh();
        GroupsView.Refresh();
        PoliciesView.Refresh();

        // Cache filtered counts so CurrentCount never iterates the view at binding time
        _usersCount    = UsersView.Cast<object>().Count();
        _rolesCount    = RolesView.Cast<object>().Count();
        _groupsCount   = GroupsView.Cast<object>().Count();
        _policiesCount = PoliciesView.Cast<object>().Count();

        OnPropertyChanged(nameof(CurrentCount));
    }

    private bool MatchesUser(IamUserModel? u)
    {
        if (u == null) return false;
        var q = FilterText;
        if (string.IsNullOrWhiteSpace(q)) return true;
        return u.UserName.Contains(q, StringComparison.OrdinalIgnoreCase)
            || u.UserId.Contains(q, StringComparison.OrdinalIgnoreCase)
            || u.Arn.Contains(q, StringComparison.OrdinalIgnoreCase);
    }

    private bool MatchesRole(IamRoleModel? r)
    {
        if (r == null) return false;
        var q = FilterText;
        if (string.IsNullOrWhiteSpace(q)) return true;
        return r.RoleName.Contains(q, StringComparison.OrdinalIgnoreCase)
            || r.RoleId.Contains(q, StringComparison.OrdinalIgnoreCase)
            || r.Arn.Contains(q, StringComparison.OrdinalIgnoreCase);
    }

    private bool MatchesGroup(IamGroupModel? g)
    {
        if (g == null) return false;
        var q = FilterText;
        if (string.IsNullOrWhiteSpace(q)) return true;
        return g.GroupName.Contains(q, StringComparison.OrdinalIgnoreCase)
            || g.GroupId.Contains(q, StringComparison.OrdinalIgnoreCase);
    }

    private bool MatchesPolicy(IamPolicyModel? p)
    {
        if (p == null) return false;
        var q = FilterText;
        if (string.IsNullOrWhiteSpace(q)) return true;
        return p.PolicyName.Contains(q, StringComparison.OrdinalIgnoreCase)
            || p.PolicyId.Contains(q, StringComparison.OrdinalIgnoreCase);
    }

    private static void ReplaceAll<T>(ObservableCollection<T> col, IEnumerable<T> items)
    {
        col.Clear();
        foreach (var item in items) col.Add(item);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _accounts.ActiveAccountChanged -= OnAccountChanged;

            _enrichCts?.Cancel();
            _enrichCts?.Dispose();
            _enrichCts = null;

            _enrichRoleCts?.Cancel();
            _enrichRoleCts?.Dispose();
            _enrichRoleCts = null;

            _enrichGroupCts?.Cancel();
            _enrichGroupCts?.Dispose();
            _enrichGroupCts = null;
        }
        base.Dispose(disposing);
    }
}
