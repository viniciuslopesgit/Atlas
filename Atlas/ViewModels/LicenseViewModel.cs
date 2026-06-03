using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Models;
using Atlas.Services;

namespace Atlas.ViewModels;

public partial class LicenseViewModel : ObservableObject
{
    private readonly ILicenseService _license;

    [ObservableProperty] private string  _licenseKey    = string.Empty;
    [ObservableProperty] private string? _errorMessage;
    [ObservableProperty] private bool    _isActivating;
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

    partial void OnLicenseKeyChanged(string value) => ErrorMessage = null;

    [RelayCommand]
    private async Task ActivateAsync()
    {
        ErrorMessage = null;

        if (string.IsNullOrWhiteSpace(LicenseKey))
        {
            ErrorMessage = "Please enter your license key.";
            return;
        }

        IsActivating = true;

        var result = await _license.ActivateAsync(LicenseKey.Trim());

        IsActivating = false;

        if (!result.Success)
        {
            ErrorMessage = result.ErrorMessage;
            return;
        }

        ActivationSucceeded?.Invoke(this, EventArgs.Empty);
    }
}
