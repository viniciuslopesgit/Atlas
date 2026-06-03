namespace Atlas.Models;

public enum LicenseType { Annual, Lifetime }

public sealed class LicenseInfo
{
    public string      Key            { get; set; } = "";
    public string      InstanceId     { get; set; } = "";   // LemonSqueezy instance ID (for revalidation)
    public LicenseType Type           { get; set; }
    public string      VariantName    { get; set; } = "";   // e.g. "Annual", "Lifetime" from LS
    public DateTime    ActivationDate { get; set; }
    public DateTime?   ExpiryDate     { get; set; }         // null = Lifetime
    public bool        IsRevoked      { get; set; }         // set when LS validate returns valid=false

    /// <summary>
    /// Friendly plan name. Uses the LemonSqueezy variant name when it is meaningful;
    /// falls back to the type-derived label ("Annual"/"Lifetime") when the store
    /// returns the placeholder "Default" (single-variant products).
    /// </summary>
    public string PlanName =>
        !string.IsNullOrWhiteSpace(VariantName) &&
        !VariantName.Equals("Default", StringComparison.OrdinalIgnoreCase)
            ? VariantName
            : Type == LicenseType.Lifetime ? "Lifetime" : "Annual";

    public bool IsValid =>
        !IsRevoked &&
        (Type == LicenseType.Lifetime ||
         (ExpiryDate.HasValue && ExpiryDate.Value > DateTime.UtcNow));

    public int DaysRemaining =>
        ExpiryDate.HasValue
            ? Math.Max(0, (int)(ExpiryDate.Value - DateTime.UtcNow).TotalDays)
            : int.MaxValue;
}
