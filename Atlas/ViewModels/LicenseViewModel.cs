using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Infrastructure;
using Atlas.Models;
using Atlas.Services;

namespace Atlas.ViewModels;

public partial class LicenseViewModel : ObservableObject
{
    private readonly ILicenseService _license;

    [ObservableProperty] private string  _licenseKey      = string.Empty;
    [ObservableProperty] private string? _errorMessage;
    [ObservableProperty] private bool    _isActivating;
    [ObservableProperty] private bool    _isFixingFirewall;
    [ObservableProperty] private bool    _isFirewallError;
    [ObservableProperty] private bool    _isExpiredMode;
    [ObservableProperty] private string? _expiredBanner;

    public event EventHandler? ActivationSucceeded;

    public LicenseViewModel(ILicenseService license)
    {
        _license = license;

        var current = license.CurrentLicense;
        if (current is { IsValid: false })
        {
            IsExpiredMode = true;
            ExpiredBanner = current.Type == LicenseType.Annual
                ? $"Your {current.PlanName} license expired on {current.ExpiryDate!.Value:dd MMM yyyy}. Please enter a new key to continue."
                : "Your license is no longer valid. Please enter a new key to continue.";
        }
    }

    partial void OnLicenseKeyChanged(string value)
    {
        ErrorMessage    = null;
        IsFirewallError = false;
    }

    [RelayCommand]
    private async Task ActivateAsync()
    {
        ErrorMessage    = null;
        IsFirewallError = false;

        if (string.IsNullOrWhiteSpace(LicenseKey))
        {
            ErrorMessage = "Please enter your license key.";
            return;
        }

        IsActivating = true;
        var result   = await _license.ActivateAsync(LicenseKey.Trim());
        IsActivating = false;

        if (!result.Success)
        {
            IsFirewallError = result.IsFirewallError;
            ErrorMessage    = result.ErrorMessage;
            return;
        }

        ActivationSucceeded?.Invoke(this, EventArgs.Empty);
    }

    [RelayCommand]
    private async Task FixFirewallAsync()
    {
        IsFixingFirewall = true;
        ErrorMessage     = null;
        IsFirewallError  = false;

        var added = await Task.Run(FirewallHelper.TryAddOutboundRuleElevated);

        if (!added)
        {
            IsFixingFirewall = false;
            IsFirewallError  = true;
            ErrorMessage     = "Could not update the firewall rule. " +
                               "Please run Atlas as Administrator, or add an outbound rule for Atlas.exe in Windows Defender Firewall manually.";
            return;
        }

        // Rule added — retry activation with the same key
        IsFixingFirewall = false;
        await ActivateAsync();
    }
}
