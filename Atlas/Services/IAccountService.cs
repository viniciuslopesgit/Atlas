using Atlas.Models;

namespace Atlas.Services;

public interface IAccountService
{
    IReadOnlyList<AwsAccount> Accounts { get; }
    AwsAccount? ActiveAccount { get; }
    string ActiveRegion { get; }
    event EventHandler ActiveAccountChanged;
    event EventHandler ActiveRegionChanged;

    string GetActiveSecretKey();
    void AddAccount(string name, string accessKeyId, string secretKey, string region);
    void RemoveAccount(string id);
    void SetActiveAccount(string id);
    void SetActiveRegion(string region);
    Task<bool> ValidateCredentialsAsync(string accessKeyId, string secretKey, string region);
}
