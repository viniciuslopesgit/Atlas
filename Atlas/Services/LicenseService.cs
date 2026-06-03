using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using Atlas.Infrastructure.Logging;
using Atlas.Infrastructure.Security;
using Atlas.Models;

namespace Atlas.Services;

/// <summary>
/// Validates license keys against the LemonSqueezy API and stores the activated
/// license locally using Windows DPAPI encryption.
///
/// LemonSqueezy API reference:
///   POST https://api.lemonsqueezy.com/v1/licenses/activate
///   POST https://api.lemonsqueezy.com/v1/licenses/validate
/// </summary>
public sealed class LicenseService : ILicenseService
{
    private static readonly HttpClient Http = new()
    {
        BaseAddress = new Uri("https://api.lemonsqueezy.com/v1/licenses/"),
        Timeout     = TimeSpan.FromSeconds(15)
    };

    private readonly ICredentialProtector _protector;
    private readonly string               _licensePath;
    private LicenseInfo?                  _current;

    public LicenseService(ICredentialProtector protector)
    {
        _protector   = protector;
        var appData  = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        _licensePath = Path.Combine(appData, "Atlas", "license.dat");
        _current     = TryLoadLicense();
    }

    public LicenseInfo? CurrentLicense => _current;

    public bool IsPro => _current is { IsValid: true };

    public event EventHandler? ProStatusChanged;

    private void RaiseProStatusChanged() => ProStatusChanged?.Invoke(this, EventArgs.Empty);

    // ── Activation ────────────────────────────────────────────────────

    public async Task<LicenseActivationResult> ActivateAsync(string licenseKey)
    {
        var key          = licenseKey.Trim();
        var instanceName = $"Atlas-{Environment.MachineName}";

        var (json, ok) = await PostAsync("activate", new Dictionary<string, string>
        {
            ["license_key"]   = key,
            ["instance_name"] = instanceName
        });

        if (!ok)
            return LicenseActivationResult.Fail(json);   // json holds the friendly error here

        return ParseResponse(key, instanceId: null, successField: "activated", json);
    }

    // ── Re-validation ─────────────────────────────────────────────────

    public async Task<LicenseActivationResult> RefreshAsync()
    {
        if (_current is null || string.IsNullOrEmpty(_current.InstanceId))
            return LicenseActivationResult.Fail("No active license to refresh.");

        var (json, ok) = await PostAsync("validate", new Dictionary<string, string>
        {
            ["license_key"] = _current.Key,
            ["instance_id"] = _current.InstanceId
        });

        // Transport/network error → keep the license unchanged (offline grace)
        if (!ok)
            return LicenseActivationResult.Fail(json);

        // Server responded. If it explicitly rejects the license (valid=false),
        // revoke it locally so the app stops trusting a disabled/refunded key.
        if (IsServerRejection(json, out var serverError))
        {
            RevokeLocal();
            return LicenseActivationResult.Fail(
                MapLsError(serverError) ?? "This license is no longer valid. It may have been disabled or revoked.");
        }

        // valid=true → refresh expiry/status from the server response
        return ParseResponse(_current.Key, _current.InstanceId, successField: "valid", json);
    }

    /// <summary>True only when the server response explicitly contains "valid": false.</summary>
    private static bool IsServerRejection(string json, out string? error)
    {
        error = null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.TryGetProperty("valid", out var validProp) &&
                validProp.ValueKind is JsonValueKind.True or JsonValueKind.False &&
                !validProp.GetBoolean())
            {
                error = root.TryGetProperty("error", out var e) ? e.GetString() : null;
                return true;
            }
            return false;
        }
        catch (JsonException)
        {
            // Unreadable response is NOT a definitive rejection — keep the license.
            return false;
        }
    }

    private void RevokeLocal()
    {
        if (_current is null) return;
        _current.IsRevoked = true;
        SaveLicense(_current);
        FileLogger.Warning("LicenseService — license revoked: server validation returned valid=false");
        RaiseProStatusChanged();
    }

    // ── HTTP helper ───────────────────────────────────────────────────

    /// <summary>Returns (payload, true) on HTTP success or (friendlyError, false) on transport error.</summary>
    private static async Task<(string body, bool ok)> PostAsync(string path, Dictionary<string, string> form)
    {
        try
        {
            var response = await Http.PostAsync(path, new FormUrlEncodedContent(form));
            var body     = await response.Content.ReadAsStringAsync();
            // Log only the HTTP status — never the body (it contains the license key in plain text)
            FileLogger.Info($"LicenseService — {path} HTTP {(int)response.StatusCode}");
            // LemonSqueezy returns the activated/valid flag in-body even on 400, so we still parse it
            return (body, true);
        }
        catch (Exception ex)
        {
            FileLogger.Error($"LicenseService — {path} HTTP error", ex);
            return ("Could not reach the activation server. Check your internet connection and try again.", false);
        }
    }

    // ── Response parsing ──────────────────────────────────────────────

    private LicenseActivationResult ParseResponse(string key, string? instanceId, string successField, string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root      = doc.RootElement;

            var success = root.TryGetProperty(successField, out var flag) && flag.GetBoolean();
            if (!success)
            {
                var lsError = root.TryGetProperty("error", out var errProp) ? errProp.GetString() : null;
                return LicenseActivationResult.Fail(
                    MapLsError(lsError) ?? "License validation failed. Please check your key.");
            }

            // Resolve instance ID (activate returns one; validate reuses the stored one)
            var resolvedInstanceId = instanceId;
            if (resolvedInstanceId is null &&
                root.TryGetProperty("instance", out var instEl) &&
                instEl.TryGetProperty("id", out var instIdEl))
                resolvedInstanceId = instIdEl.GetString();

            if (string.IsNullOrEmpty(resolvedInstanceId))
                return LicenseActivationResult.Fail("Activation server returned an unexpected response.");

            // Expiry — null means Lifetime
            DateTime? expiryDate = null;
            if (root.TryGetProperty("license_key", out var lkEl) &&
                lkEl.TryGetProperty("expires_at", out var expEl) &&
                expEl.ValueKind != JsonValueKind.Null)
            {
                var expStr = expEl.GetString();
                if (expStr is not null &&
                    DateTime.TryParse(expStr, null, DateTimeStyles.RoundtripKind, out var parsed))
                    expiryDate = parsed.ToUniversalTime();
            }

            // Variant name from meta (e.g. "Annual", "Lifetime")
            var variantName = "";
            if (root.TryGetProperty("meta", out var metaEl) &&
                metaEl.TryGetProperty("variant_name", out var variantEl))
                variantName = variantEl.GetString() ?? "";

            var type    = expiryDate.HasValue ? LicenseType.Annual : LicenseType.Lifetime;
            var license = new LicenseInfo
            {
                Key            = key,
                InstanceId     = resolvedInstanceId!,
                Type           = type,
                VariantName    = string.IsNullOrEmpty(variantName) ? type.ToString() : variantName,
                ActivationDate = _current?.ActivationDate ?? DateTime.UtcNow,
                ExpiryDate     = expiryDate
            };

            SaveLicense(license);
            _current = license;
            RaiseProStatusChanged();
            FileLogger.Info($"LicenseService — {successField}: type={type}, expiry={expiryDate?.ToString("yyyy-MM-dd") ?? "never"}");
            return LicenseActivationResult.Ok(license);
        }
        catch (JsonException ex)
        {
            FileLogger.Error("LicenseService — JSON parse error", ex);
            return LicenseActivationResult.Fail("Activation server returned an unreadable response.");
        }
    }

    private static string? MapLsError(string? lsError) => lsError switch
    {
        null                                                    => null,
        var s when s.Contains("activation limit",  StringComparison.OrdinalIgnoreCase)
                                                               => "This license key has reached its activation limit.",
        var s when s.Contains("disabled",           StringComparison.OrdinalIgnoreCase)
                                                               => "This license key has been disabled.",
        var s when s.Contains("expired",            StringComparison.OrdinalIgnoreCase)
                                                               => "This license key has expired.",
        var s when s.Contains("not found",          StringComparison.OrdinalIgnoreCase) ||
                   s.Contains("invalid",            StringComparison.OrdinalIgnoreCase)
                                                               => "License key not found. Please check and try again.",
        _                                                      => lsError
    };

    // ── Persistence ───────────────────────────────────────────────────

    private LicenseInfo? TryLoadLicense()
    {
        if (!File.Exists(_licensePath)) return null;
        try
        {
            var cipher = File.ReadAllText(_licensePath);
            var plain  = _protector.Unprotect(cipher);
            return JsonSerializer.Deserialize<LicenseInfo>(plain);
        }
        catch (Exception ex)
        {
            FileLogger.Warning($"LicenseService — could not load license: {ex.Message}");
            return null;
        }
    }

    private void SaveLicense(LicenseInfo info)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_licensePath)!);
        var plain  = JsonSerializer.Serialize(info);
        var cipher = _protector.Protect(plain);
        File.WriteAllText(_licensePath, cipher);
    }
}
