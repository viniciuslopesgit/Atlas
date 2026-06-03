namespace Atlas.Models;

public sealed class LicenseActivationResult
{
    public bool         Success      { get; init; }
    public string?      ErrorMessage { get; init; }
    public LicenseInfo? License      { get; init; }

    public static LicenseActivationResult Ok(LicenseInfo l)   => new() { Success = true,  License = l };
    public static LicenseActivationResult Fail(string error)  => new() { Success = false, ErrorMessage = error };
}
