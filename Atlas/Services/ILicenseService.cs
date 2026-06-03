using Atlas.Models;

namespace Atlas.Services;

public interface ILicenseService
{
    /// <summary>License loaded from disk at startup (may be null or expired).</summary>
    LicenseInfo? CurrentLicense { get; }

    /// <summary>True when a valid (non-expired, non-revoked) license is present — i.e. the Pro tier is unlocked.</summary>
    bool IsPro { get; }

    /// <summary>Raised whenever the Pro entitlement may have changed (activation, revocation, refresh).</summary>
    event EventHandler? ProStatusChanged;

    /// <summary>
    /// Calls the LemonSqueezy Activate endpoint, stores the result locally and
    /// returns a result object describing success or failure.
    /// </summary>
    Task<LicenseActivationResult> ActivateAsync(string licenseKey);

    /// <summary>
    /// Re-validates the stored license against the LemonSqueezy Validate endpoint,
    /// refreshing the expiry/status held locally. Returns failure if there is no
    /// stored license or the server rejects it.
    /// </summary>
    Task<LicenseActivationResult> RefreshAsync();
}
