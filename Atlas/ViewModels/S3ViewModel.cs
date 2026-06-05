using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Infrastructure.Logging;
using Atlas.Models;
using Atlas.Services;
using Atlas.Services.AWS;
using Microsoft.Win32;
using System.Collections.ObjectModel;
using System.Linq;

namespace Atlas.ViewModels;

public partial class S3ViewModel : AsyncViewModel
{
    private readonly IS3Service _s3;
    private readonly IAccountService _accounts;
    private readonly IDialogService _dialog;
    private readonly ILicenseService _license;
    private readonly IUpgradeService _upgrade;

    [ObservableProperty] private ObservableCollection<S3BucketModel> _buckets = [];
    [ObservableProperty] private ObservableCollection<S3ObjectModel> _objects = [];
    [ObservableProperty] private string _bucketFilterText = string.Empty;

    private List<S3BucketModel> _allBuckets = [];
    [ObservableProperty] private S3BucketModel? _selectedBucket;
    [ObservableProperty] private S3ObjectModel? _selectedObject;
    [ObservableProperty] private string? _statusMessage;
    [ObservableProperty] private int _uploadProgress;
    [ObservableProperty] private bool _isTransferring;
    [ObservableProperty] private string _prefix = string.Empty;

    // ── Breadcrumb navigation ─────────────────────────────────────
    [ObservableProperty] private ObservableCollection<BreadcrumbItem> _breadcrumbs = [];
    [ObservableProperty] private bool _canNavigateUp;

    public record BreadcrumbItem(string Label, string Prefix);

    // ── Bucket multi-selection ────────────────────────────────────
    [ObservableProperty] private int  _selectedBucketCount;
    [ObservableProperty] private bool _hasBucketSelection;
    [ObservableProperty] private bool _areAllBucketsSelected;

    public List<S3BucketModel> SelectedBuckets { get; } = [];

    public void UpdateBucketSelection(System.Collections.IList items)
    {
        SelectedBuckets.Clear();
        foreach (S3BucketModel item in items)
            SelectedBuckets.Add(item);

        SelectedBucketCount    = SelectedBuckets.Count;
        HasBucketSelection     = SelectedBucketCount > 0;
        AreAllBucketsSelected  = Buckets.Count > 0 && SelectedBucketCount == Buckets.Count;
        SelectedBucket         = SelectedBucketCount == 1 ? SelectedBuckets[0] : null;

        DeleteBucketCommand.NotifyCanExecuteChanged();
    }

    // ── Object multi-selection ────────────────────────────────────
    [ObservableProperty] private int  _selectedObjectCount;
    [ObservableProperty] private bool _hasObjectSelection;
    [ObservableProperty] private bool _areAllObjectsSelected;

    public List<S3ObjectModel> SelectedObjects { get; } = [];

    public void UpdateObjectSelection(System.Collections.IList items)
    {
        SelectedObjects.Clear();
        foreach (S3ObjectModel item in items)
            SelectedObjects.Add(item);

        SelectedObjectCount   = SelectedObjects.Count;
        HasObjectSelection    = SelectedObjectCount > 0;
        AreAllObjectsSelected = Objects.Count > 0 && SelectedObjectCount == Objects.Count;
        SelectedObject        = SelectedObjectCount == 1 ? SelectedObjects[0] : null;

        DownloadFileCommand.NotifyCanExecuteChanged();
        // Also used for toolbar Download button
        OnPropertyChanged(nameof(SelectedObject));
    }

    public bool HasActiveAccount => _accounts.ActiveAccount != null;

    // ── Create-bucket dialog ──────────────────────────────────────
    [ObservableProperty] private bool   _isCreateBucketOpen;
    [ObservableProperty] private bool   _isCreatingBucket;

    // General
    [ObservableProperty] private string _newBucketName      = string.Empty;
    [ObservableProperty] private string _newBucketRegion    = "us-east-1";
    [ObservableProperty] private string _newBucketType      = "GeneralPurpose";
    [ObservableProperty] private string _newBucketNamespace = "AccountRegional";

    // Object Ownership
    [ObservableProperty] private bool _newBucketAclsEnabled = false;

    // Block Public Access
    [ObservableProperty] private bool _newBucketBlockAll                   = true;
    [ObservableProperty] private bool _newBucketBlockPublicAclNew          = true;
    [ObservableProperty] private bool _newBucketBlockPublicAclAny          = true;
    [ObservableProperty] private bool _newBucketBlockPublicPolicyNew       = true;
    [ObservableProperty] private bool _newBucketBlockPublicPolicyCrossAcct = true;

    // Versioning
    [ObservableProperty] private bool _newBucketVersioningEnabled = false;

    // Encryption
    [ObservableProperty] private string _newBucketEncryption    = "SSE_S3";
    [ObservableProperty] private bool   _newBucketKeyEnabled    = true;

    // Tags
    [ObservableProperty] private ObservableCollection<BucketTagModel> _newBucketTags = [];

    private bool _syncingBlockAll;

    partial void OnNewBucketBlockAllChanged(bool value)
    {
        if (_syncingBlockAll) return;
        _syncingBlockAll = true;
        NewBucketBlockPublicAclNew          = value;
        NewBucketBlockPublicAclAny          = value;
        NewBucketBlockPublicPolicyNew       = value;
        NewBucketBlockPublicPolicyCrossAcct = value;
        _syncingBlockAll = false;
    }

    private void SyncBlockAllFromSub()
    {
        if (_syncingBlockAll) return;
        _syncingBlockAll = true;
        NewBucketBlockAll = NewBucketBlockPublicAclNew
                         && NewBucketBlockPublicAclAny
                         && NewBucketBlockPublicPolicyNew
                         && NewBucketBlockPublicPolicyCrossAcct;
        _syncingBlockAll = false;
    }

    partial void OnNewBucketBlockPublicAclNewChanged(bool value)          => SyncBlockAllFromSub();
    partial void OnNewBucketBlockPublicAclAnyChanged(bool value)          => SyncBlockAllFromSub();
    partial void OnNewBucketBlockPublicPolicyNewChanged(bool value)       => SyncBlockAllFromSub();
    partial void OnNewBucketBlockPublicPolicyCrossAcctChanged(bool value) => SyncBlockAllFromSub();

    public record AwsRegionItem(string Code, string Label);

    public static IReadOnlyList<AwsRegionItem> AwsRegions { get; } =
    [
        new("us-east-1",      "US East (N. Virginia)"),
        new("us-east-2",      "US East (Ohio)"),
        new("us-west-1",      "US West (N. California)"),
        new("us-west-2",      "US West (Oregon)"),
        new("ca-central-1",   "Canada (Central)"),
        new("eu-west-1",      "Europe (Ireland)"),
        new("eu-west-2",      "Europe (London)"),
        new("eu-west-3",      "Europe (Paris)"),
        new("eu-central-1",   "Europe (Frankfurt)"),
        new("eu-north-1",     "Europe (Stockholm)"),
        new("eu-south-1",     "Europe (Milan)"),
        new("ap-northeast-1", "Asia Pacific (Tokyo)"),
        new("ap-northeast-2", "Asia Pacific (Seoul)"),
        new("ap-southeast-1", "Asia Pacific (Singapore)"),
        new("ap-southeast-2", "Asia Pacific (Sydney)"),
        new("ap-south-1",     "Asia Pacific (Mumbai)"),
        new("sa-east-1",      "South America (São Paulo)"),
        new("af-south-1",     "Africa (Cape Town)"),
        new("me-south-1",     "Middle East (Bahrain)"),
    ];

    public string SelectedBucketSizeText
    {
        get
        {
            if (SelectedBucket == null || Objects.Count == 0) return string.Empty;
            var bytes = Objects.Sum(o => o.SizeBytes);
            return FormatBytes(bytes);
        }
    }

    public bool HasSelectedBucketStats => SelectedBucket != null && Objects.Count > 0;

    private static string FormatBytes(long bytes) => bytes switch
    {
        < 1024L                  => $"{bytes} B",
        < 1024L * 1024           => $"{bytes / 1024.0:F1} KB",
        < 1024L * 1024 * 1024    => $"{bytes / (1024.0 * 1024):F1} MB",
        < 1024L * 1024 * 1024 * 1024 => $"{bytes / (1024.0 * 1024 * 1024):F2} GB",
        _ => $"{bytes / (1024.0 * 1024 * 1024 * 1024):F2} TB"
    };

    public S3ViewModel(IS3Service s3, IAccountService accounts, IDialogService dialog,
                       ILicenseService license, IUpgradeService upgrade)
    {
        _s3 = s3;
        _accounts = accounts;
        _dialog = dialog;
        _license = license;
        _upgrade = upgrade;
        _accounts.ActiveAccountChanged += OnAccountChanged;
    }

    private bool EnsureBulkBucketAllowed()
    {
        if (_license.IsPro || SelectedBuckets.Count <= 1) return true;
        _upgrade.Prompt("Bulk delete of multiple S3 buckets is a Pro feature. " +
                        "On Free you can delete one bucket at a time.");
        return false;
    }

    private void OnAccountChanged(object? s, EventArgs e)
    {
        OnPropertyChanged(nameof(HasActiveAccount));
        Buckets.Clear();
        Objects.Clear();
        _ = LoadAsync(force: true);
    }

    [RelayCommand]
    public async Task LoadAsync(bool force = false)
    {
        if (_accounts.ActiveAccount == null) return;
        if (!force && !IsDataStale) return;

        var ct = BeginLoad();
        try
        {
            _allBuckets = (await _s3.GetBucketsAsync(ct)).ToList();
            ApplyBucketFilter();
            Objects.Clear();
            EndLoad();
        }
        catch (Exception ex)
        {
            HandleError("S3ViewModel.LoadAsync", ex);
        }
    }

    partial void OnBucketFilterTextChanged(string value) => ApplyBucketFilter();

    private void ApplyBucketFilter()
    {
        var filtered = string.IsNullOrWhiteSpace(BucketFilterText)
            ? _allBuckets
            : _allBuckets.Where(b => b.Name.Contains(BucketFilterText, StringComparison.OrdinalIgnoreCase));

        Buckets = new ObservableCollection<S3BucketModel>(filtered);
    }

    partial void OnSelectedBucketChanged(S3BucketModel? value)
    {
        OnPropertyChanged(nameof(SelectedBucketSizeText));
        OnPropertyChanged(nameof(HasSelectedBucketStats));
        if (value == null) return;

        // Reset navigation to bucket root
        Prefix      = string.Empty;
        Breadcrumbs = [new BreadcrumbItem(value.Name, string.Empty)];
        CanNavigateUp = false;
        _ = LoadObjectsAsync(value.Name);
    }

    private async Task LoadObjectsAsync(string bucketName)
    {
        var ct = BeginLoad();
        Objects.Clear();
        try
        {
            var objects = await _s3.GetObjectsAsync(bucketName, Prefix, ct);
            Objects = new ObservableCollection<S3ObjectModel>(objects);
            OnPropertyChanged(nameof(SelectedBucketSizeText));
            OnPropertyChanged(nameof(HasSelectedBucketStats));
            EndLoad();
        }
        catch (Exception ex)
        {
            HandleError($"S3ViewModel.LoadObjectsAsync (bucket: {bucketName})", ex);
        }
    }

    [RelayCommand]
    private void EnterFolder(S3ObjectModel? item)
    {
        if (item?.IsFolder != true || SelectedBucket == null) return;
        Prefix = item.Key;
        Breadcrumbs.Add(new BreadcrumbItem(item.DisplayName, item.Key));
        CanNavigateUp = true;
        _ = LoadObjectsAsync(SelectedBucket.Name);
    }

    partial void OnCanNavigateUpChanged(bool value) => NavigateUpCommand.NotifyCanExecuteChanged();

    [RelayCommand(CanExecute = nameof(CanNavigateUp))]
    private void NavigateUp()
    {
        if (Breadcrumbs.Count <= 1 || SelectedBucket == null) return;
        Breadcrumbs.RemoveAt(Breadcrumbs.Count - 1);
        var parent = Breadcrumbs[^1];
        Prefix        = parent.Prefix;
        CanNavigateUp = Breadcrumbs.Count > 1;
        _ = LoadObjectsAsync(SelectedBucket.Name);
    }

    [RelayCommand]
    private void NavigateToBreadcrumb(BreadcrumbItem item)
    {
        if (SelectedBucket == null) return;
        var idx = Breadcrumbs.IndexOf(item);
        if (idx < 0) return;
        while (Breadcrumbs.Count > idx + 1)
            Breadcrumbs.RemoveAt(Breadcrumbs.Count - 1);
        Prefix        = item.Prefix;
        CanNavigateUp = Breadcrumbs.Count > 1;
        _ = LoadObjectsAsync(SelectedBucket.Name);
    }

    [RelayCommand]
    private void OpenCreateBucket()
    {
        NewBucketName               = string.Empty;
        NewBucketRegion             = _accounts.ActiveAccount?.DefaultRegion ?? "eu-west-1";
        NewBucketType               = "GeneralPurpose";
        NewBucketNamespace          = "AccountRegional";
        NewBucketAclsEnabled        = false;
        NewBucketBlockAll           = true;   // cascades to sub-items via OnNewBucketBlockAllChanged
        NewBucketVersioningEnabled  = false;
        NewBucketEncryption         = "SSE_S3";
        NewBucketKeyEnabled         = true;
        NewBucketTags               = [];
        ErrorMessage                = null;
        IsCreateBucketOpen          = true;
    }

    [RelayCommand]
    private void CancelCreateBucket() => IsCreateBucketOpen = false;

    [RelayCommand(CanExecute = nameof(CanDeleteBucket))]
    private async Task DeleteBucket()
    {
        if (SelectedBuckets.Count == 0) return;
        if (!EnsureBulkBucketAllowed()) return;

        var names = string.Join("\n", SelectedBuckets.Select(b => $"• {b.Name}"));
        if (!_dialog.Confirm(
                "Delete buckets",
                $"Permanently delete {SelectedBuckets.Count} bucket(s) and ALL their contents? This cannot be undone.\n\n{names}",
                DialogKind.Danger))
            return;

        var toDelete = SelectedBuckets.ToList();
        var ct = BeginLoad();
        ErrorMessage = null;
        try
        {
            await Task.WhenAll(toDelete.Select(b => _s3.DeleteBucketAsync(b.Name, ct)));
            await LoadAsync(force: true);
        }
        catch (Exception ex)
        {
            FileLogger.Error("S3ViewModel.DeleteBucket failed", ex);
            ErrorMessage = $"Delete failed: {ex.Message}";
            EndLoad(false);
        }
    }

    private bool CanDeleteBucket() => SelectedBuckets.Count > 0;

    [RelayCommand]
    private void AddTag() => NewBucketTags.Add(new BucketTagModel());

    [RelayCommand]
    private void RemoveTag(BucketTagModel tag) => NewBucketTags.Remove(tag);

    [RelayCommand(CanExecute = nameof(CanCreateBucket))]
    private async Task CreateBucket()
    {
        if (string.IsNullOrWhiteSpace(NewBucketName)) return;

        IsCreatingBucket = true;
        ErrorMessage     = null;
        try
        {
            var opts = new CreateBucketOptions
            {
                BucketName      = NewBucketName.Trim(),
                Region          = NewBucketRegion,
                BucketType      = NewBucketType == "Directory"
                                  ? BucketTypeOption.Directory
                                  : BucketTypeOption.GeneralPurpose,
                BucketNamespace = NewBucketNamespace == "Global"
                                  ? BucketNamespaceOption.Global
                                  : BucketNamespaceOption.AccountRegional,
                AclsEnabled              = NewBucketAclsEnabled,
                BlockNewAcls             = NewBucketBlockPublicAclNew,
                BlockExistingAcls        = NewBucketBlockPublicAclAny,
                BlockNewPublicPolicies   = NewBucketBlockPublicPolicyNew,
                BlockCrossAccount        = NewBucketBlockPublicPolicyCrossAcct,
                VersioningEnabled        = NewBucketVersioningEnabled,
                Encryption               = NewBucketEncryption switch
                {
                    "SSE_KMS"  => BucketEncryptionType.SSE_KMS,
                    "DSSE_KMS" => BucketEncryptionType.DSSE_KMS,
                    _          => BucketEncryptionType.SSE_S3
                },
                BucketKeyEnabled = NewBucketKeyEnabled,
                Tags = NewBucketTags
                           .Where(t => !string.IsNullOrWhiteSpace(t.Key))
                           .ToDictionary(t => t.Key.Trim(), t => t.Value.Trim())
            };

            await _s3.CreateBucketAsync(opts);
            IsCreateBucketOpen = false;
            await LoadAsync(force: true);
        }
        catch (Exception ex)
        {
            ErrorMessage = $"Failed to create bucket: {ex.Message}";
        }
        finally
        {
            IsCreatingBucket = false;
        }
    }

    private bool CanCreateBucket() => !string.IsNullOrWhiteSpace(NewBucketName) && !IsCreatingBucket;

    partial void OnNewBucketNameChanged(string value)  => CreateBucketCommand.NotifyCanExecuteChanged();
    partial void OnIsCreatingBucketChanged(bool value) => CreateBucketCommand.NotifyCanExecuteChanged();

    [RelayCommand]
    private async Task UploadFile()
    {
        if (SelectedBucket == null) return;

        var dialog = new OpenFileDialog { Title = "Select file to upload", Multiselect = false };
        if (dialog.ShowDialog() != true) return;

        var key = System.IO.Path.GetFileName(dialog.FileName);
        if (!string.IsNullOrEmpty(Prefix)) key = Prefix.TrimEnd('/') + "/" + key;

        IsTransferring = true;
        UploadProgress = 0;
        StatusMessage = $"Uploading {key}…";
        ErrorMessage = null;
        try
        {
            var progress = new Progress<int>(p => UploadProgress = p);
            await _s3.UploadFileAsync(SelectedBucket.Name, key, dialog.FileName, progress);
            StatusMessage = "Upload complete.";
            await LoadObjectsAsync(SelectedBucket.Name);
        }
        catch (Exception ex)
        {
            FileLogger.Error($"S3ViewModel.UploadFile failed for key '{key}'", ex);
            ErrorMessage = $"Upload failed: {ex.Message}";
            StatusMessage = null;
        }
        finally
        {
            IsTransferring = false;
        }
    }

    [RelayCommand(CanExecute = nameof(CanDownload))]
    private async Task DownloadFile()
    {
        if (SelectedBucket == null) return;

        var selected = SelectedObjects.ToList();
        if (selected.Count == 0) return;

        // Single file (no folders) → SaveFileDialog
        if (selected.Count == 1 && !selected[0].IsFolder)
        {
            var saveDialog = new SaveFileDialog
            {
                FileName = System.IO.Path.GetFileName(selected[0].Key),
                Title    = "Save file"
            };
            if (saveDialog.ShowDialog() != true) return;

            IsTransferring = true;
            UploadProgress = 0;
            StatusMessage  = $"Downloading {selected[0].DisplayName}…";
            ErrorMessage   = null;
            try
            {
                var progress = new Progress<int>(p => UploadProgress = p);
                await _s3.DownloadFileAsync(SelectedBucket.Name, selected[0].Key, saveDialog.FileName, progress);
                StatusMessage = "Download complete.";
            }
            catch (Exception ex)
            {
                FileLogger.Error($"S3ViewModel.DownloadFile failed for '{selected[0].Key}'", ex);
                ErrorMessage  = $"Download failed: {ex.Message}";
                StatusMessage = null;
            }
            finally { IsTransferring = false; }
            return;
        }

        // Multiple items or a folder → folder picker
        var folderDialog = new OpenFolderDialog { Title = "Select destination folder" };
        if (folderDialog.ShowDialog() != true) return;

        var destRoot   = folderDialog.FolderName;
        IsTransferring = true;
        UploadProgress = 0;
        ErrorMessage   = null;

        try
        {
            // Expand folders into individual file keys
            var allFiles = new List<(string Key, string RelativePath)>();

            foreach (var item in selected)
            {
                if (!item.IsFolder)
                {
                    allFiles.Add((item.Key, System.IO.Path.GetFileName(item.Key)));
                }
                else
                {
                    // Recursively list everything under this prefix
                    StatusMessage = $"Listing {item.DisplayName}…";
                    var children = await _s3.GetAllObjectsRecursiveAsync(SelectedBucket.Name, item.Key);

                    // Strip the folder prefix so we recreate relative sub-structure
                    foreach (var child in children)
                    {
                        var relative = child.Key[item.Key.Length..].Replace('/', System.IO.Path.DirectorySeparatorChar);
                        allFiles.Add((child.Key, System.IO.Path.Combine(item.DisplayName, relative)));
                    }
                }
            }

            int completed = 0;
            int total     = allFiles.Count;

            foreach (var (key, relativePath) in allFiles)
            {
                var localPath = System.IO.Path.Combine(destRoot, relativePath);
                var localDir  = System.IO.Path.GetDirectoryName(localPath)!;
                if (!System.IO.Directory.Exists(localDir))
                    System.IO.Directory.CreateDirectory(localDir);

                StatusMessage = $"Downloading {System.IO.Path.GetFileName(key)} ({completed + 1}/{total})…";
                await _s3.DownloadFileAsync(SelectedBucket.Name, key, localPath);

                completed++;
                UploadProgress = (int)(completed * 100.0 / total);
            }

            StatusMessage = $"{total} file(s) downloaded.";
        }
        catch (Exception ex)
        {
            FileLogger.Error("S3ViewModel.DownloadFile (multi) failed", ex);
            ErrorMessage  = $"Download failed: {ex.Message}";
            StatusMessage = null;
        }
        finally { IsTransferring = false; }
    }

    private bool CanDownload() => SelectedObjects.Count > 0;

    partial void OnSelectedObjectChanged(S3ObjectModel? value)
        => DownloadFileCommand.NotifyCanExecuteChanged();

    protected override void Dispose(bool disposing)
    {
        if (disposing)
            _accounts.ActiveAccountChanged -= OnAccountChanged;
        base.Dispose(disposing);
    }
}
