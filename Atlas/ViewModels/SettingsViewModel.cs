using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Infrastructure.Logging;
using Atlas.Models;
using Atlas.Services;
using System.Collections.ObjectModel;

namespace Atlas.ViewModels;

public partial class SettingsViewModel : ObservableObject
{
    private readonly IAccountService _accounts;
    private readonly IThemeService _theme;
    private readonly ILicenseService _license;
    private readonly IUpgradeService _upgrade;

    [ObservableProperty] private string _newAccountName = string.Empty;
    [ObservableProperty] private string _newAccessKeyId = string.Empty;
    [ObservableProperty] private string _newSecretKey = string.Empty;
    [ObservableProperty] private string _newRegion = "us-east-1";
    [ObservableProperty] private bool _isValidating;
    [ObservableProperty] private string? _validationMessage;
    [ObservableProperty] private bool _validationSuccess;
    [ObservableProperty] private bool _isDarkMode;

    // ── License / Subscription ────────────────────────────────────────
    [ObservableProperty] private bool    _hasLicense;
    [ObservableProperty] private bool    _isLifetime;
    [ObservableProperty] private bool    _isLicenseActive;
    [ObservableProperty] private string  _licensePlan          = "—";
    [ObservableProperty] private string  _licenseStatus        = "—";
    [ObservableProperty] private string  _licenseKeyMasked     = "—";
    [ObservableProperty] private string  _licenseActivatedDisplay = "—";
    [ObservableProperty] private string  _licenseExpiryDisplay = "—";
    [ObservableProperty] private string? _licenseDaysRemaining;
    [ObservableProperty] private bool    _isRefreshingLicense;
    [ObservableProperty] private string? _licenseRefreshMessage;
    [ObservableProperty] private bool    _licenseRefreshSuccess;

    /// <summary>True on the Free tier (no active Pro license). Drives the Upgrade CTA + account-limit note.</summary>
    [ObservableProperty] private bool    _isFree = true;

    public ObservableCollection<AwsAccount> Accounts { get; } = [];

    public string[] CommonRegions { get; } =
    [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
        "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1",
        "ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "sa-east-1"
    ];

    public SettingsViewModel(IAccountService accounts, IThemeService theme,
                             ILicenseService license, IUpgradeService upgrade)
    {
        _accounts = accounts;
        _theme = theme;
        _license = license;
        _upgrade = upgrade;
        _isDarkMode = _theme.CurrentTheme == AppTheme.Dark;
        _theme.ThemeChanged += (_, t) => IsDarkMode = t == AppTheme.Dark;
        _accounts.ActiveAccountChanged += (_, _) => RefreshAccounts();
        _license.ProStatusChanged += (_, _) => RefreshLicenseDisplay();
        RefreshAccounts();
        RefreshLicenseDisplay();
    }

    [RelayCommand]
    private void Upgrade() =>
        _upgrade.Prompt("Unlock multiple accounts, bulk actions, IAM and more with Atlas Pro.");

    partial void OnIsDarkModeChanged(bool value)
    {
        var target = value ? AppTheme.Dark : AppTheme.Light;
        if (_theme.CurrentTheme != target)
            _theme.Apply(target);
    }

    [RelayCommand]
    private async Task AddAccount()
    {
        if (string.IsNullOrWhiteSpace(NewAccountName) ||
            string.IsNullOrWhiteSpace(NewAccessKeyId) ||
            string.IsNullOrWhiteSpace(NewSecretKey)) return;

        IsValidating = true;
        ValidationMessage = "Validating credentials…";
        ValidationSuccess = false;

        bool valid;
        try
        {
            valid = await _accounts.ValidateCredentialsAsync(NewAccessKeyId, NewSecretKey, NewRegion);
        }
        catch (Exception ex)
        {
            FileLogger.Error("SettingsViewModel.AddAccount — credential validation threw", ex);
            ValidationMessage = $"Validation error: {ex.Message}";
            IsValidating = false;
            return;
        }

        if (!valid)
        {
            FileLogger.Warning("SettingsViewModel.AddAccount — credential validation failed (invalid key or secret)");
            ValidationMessage = "Invalid credentials. Check your Access Key and Secret Key.";
            IsValidating = false;
            return;
        }

        FileLogger.Info("SettingsViewModel.AddAccount — account added successfully");
        _accounts.AddAccount(NewAccountName, NewAccessKeyId, NewSecretKey, NewRegion);
        ValidationMessage = "Account added successfully.";
        ValidationSuccess = true;
        IsValidating = false;

        NewAccountName = string.Empty;
        NewAccessKeyId = string.Empty;
        NewSecretKey = string.Empty;
        RefreshAccounts();
    }

    [RelayCommand]
    private void RemoveAccount(AwsAccount account)
    {
        _accounts.RemoveAccount(account.Id);
        RefreshAccounts();
    }

    [RelayCommand]
    private void SetActive(AwsAccount account)
    {
        _accounts.SetActiveAccount(account.Id);
        RefreshAccounts();
    }

    private void RefreshAccounts()
    {
        Accounts.Clear();
        foreach (var a in _accounts.Accounts) Accounts.Add(a);
    }

    // ── License ───────────────────────────────────────────────────────

    [RelayCommand]
    private async Task RefreshLicense()
    {
        if (IsRefreshingLicense) return;

        IsRefreshingLicense    = true;
        LicenseRefreshMessage  = "Checking…";
        LicenseRefreshSuccess  = false;

        var result = await _license.RefreshAsync();

        IsRefreshingLicense = false;
        RefreshLicenseDisplay();

        if (result.Success)
        {
            LicenseRefreshSuccess = true;
            LicenseRefreshMessage = "Subscription up to date.";
        }
        else
        {
            LicenseRefreshSuccess = false;
            LicenseRefreshMessage = result.ErrorMessage;
        }
    }

    private void RefreshLicenseDisplay()
    {
        var lic = _license.CurrentLicense;
        IsFree = !_license.IsPro;

        if (lic is null)
        {
            HasLicense            = false;
            IsLifetime            = false;
            IsLicenseActive       = false;
            LicensePlan           = "Free";
            LicenseStatus         = "Free plan";
            LicenseKeyMasked      = "—";
            LicenseActivatedDisplay = "—";
            LicenseExpiryDisplay  = "—";
            LicenseDaysRemaining  = null;
            return;
        }

        HasLicense       = true;
        IsLifetime       = lic.Type == LicenseType.Lifetime;
        IsLicenseActive  = lic.IsValid;
        LicensePlan      = lic.PlanName;
        LicenseStatus    = lic.IsValid ? "Active" : lic.IsRevoked ? "Revoked" : "Expired";
        LicenseKeyMasked = MaskKey(lic.Key);
        LicenseActivatedDisplay = lic.ActivationDate.ToLocalTime().ToString("dd MMM yyyy");

        if (IsLifetime)
        {
            LicenseExpiryDisplay = "Never expires";
            LicenseDaysRemaining = null;
        }
        else
        {
            LicenseExpiryDisplay = lic.ExpiryDate!.Value.ToLocalTime().ToString("dd MMM yyyy");
            LicenseDaysRemaining = lic.IsValid
                ? $"{lic.DaysRemaining} day{(lic.DaysRemaining == 1 ? "" : "s")} remaining"
                : lic.IsRevoked ? "Revoked" : "Expired";
        }
    }

    private static string MaskKey(string key)
    {
        if (string.IsNullOrEmpty(key)) return "—";
        if (key.Length <= 8) return key;
        return $"{key[..4]}{new string('•', 12)}{key[^4..]}";
    }
}
