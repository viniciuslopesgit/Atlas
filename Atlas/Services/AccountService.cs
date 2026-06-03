using Amazon;
using Amazon.SecurityToken;
using Amazon.SecurityToken.Model;
using Amazon.Runtime;
using Atlas.Infrastructure.Database;
using Atlas.Infrastructure.Security;
using Atlas.Models;

namespace Atlas.Services;

public sealed class AccountService : IAccountService
{
    private readonly IAccountRepository _repo;
    private readonly ICredentialProtector _protector;
    private List<AwsAccount> _accounts;
    private string? _activeRegionOverride;

    public event EventHandler ActiveAccountChanged = delegate { };
    public event EventHandler ActiveRegionChanged = delegate { };

    public AccountService(IAccountRepository repo, ICredentialProtector protector)
    {
        _repo = repo;
        _protector = protector;
        _accounts = _repo.GetAll().ToList();
        MigrateLegacyCredentials();
    }

    // Re-encrypt any v1 (no-entropy) DPAPI blobs to v2 (with entropy) on first run after update.
    private void MigrateLegacyCredentials()
    {
        bool changed = false;
        foreach (var account in _accounts)
        {
            if (account.EncryptedSecretKey.StartsWith("v2:", StringComparison.Ordinal)) continue;
            try
            {
                var plain = _protector.Unprotect(account.EncryptedSecretKey);
                account.EncryptedSecretKey = _protector.Protect(plain);
                _repo.Save(account);
                changed = true;
            }
            catch { /* leave as-is if migration fails — will retry on next start */ }
        }
        if (changed) _accounts = _repo.GetAll().ToList();
    }

    public IReadOnlyList<AwsAccount> Accounts => _accounts;

    public AwsAccount? ActiveAccount => _accounts.FirstOrDefault(a => a.IsActive);

    public string ActiveRegion => _activeRegionOverride ?? ActiveAccount?.DefaultRegion ?? "us-east-1";

    public string GetActiveSecretKey()
    {
        var account = ActiveAccount;
        if (account == null) return string.Empty;
        return _protector.Unprotect(account.EncryptedSecretKey);
    }

    public void SetActiveRegion(string region)
    {
        if (_activeRegionOverride == region) return;
        _activeRegionOverride = region;
        ActiveRegionChanged(this, EventArgs.Empty);
    }

    public void AddAccount(string name, string accessKeyId, string secretKey, string region)
    {
        var account = new AwsAccount
        {
            Name = name,
            AccessKeyId = accessKeyId,
            EncryptedSecretKey = _protector.Protect(secretKey),
            DefaultRegion = region,
            IsActive = !_accounts.Any()
        };
        _repo.Save(account);
        _accounts = _repo.GetAll().ToList();
        if (account.IsActive)
            ActiveAccountChanged(this, EventArgs.Empty);
    }

    public void RemoveAccount(string id)
    {
        var wasActive = ActiveAccount?.Id == id;
        _repo.Delete(id);
        _accounts = _repo.GetAll().ToList();
        if (wasActive && _accounts.Any())
        {
            SetActiveAccount(_accounts[0].Id);
        }
    }

    public void SetActiveAccount(string id)
    {
        _repo.SetActive(id);
        _accounts = _repo.GetAll().ToList();
        _activeRegionOverride = null;
        ActiveAccountChanged(this, EventArgs.Empty);
        ActiveRegionChanged(this, EventArgs.Empty);
    }

    public async Task<bool> ValidateCredentialsAsync(string accessKeyId, string secretKey, string region)
    {
        try
        {
            var credentials = new BasicAWSCredentials(accessKeyId, secretKey);
            using var stsClient = new AmazonSecurityTokenServiceClient(credentials, RegionEndpoint.GetBySystemName(region));
            await stsClient.GetCallerIdentityAsync(new GetCallerIdentityRequest());
            return true;
        }
        catch
        {
            return false;
        }
    }
}
