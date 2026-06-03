using Amazon.Runtime;
using Atlas.Infrastructure.Security;

namespace Atlas.Services;

public sealed class AwsSessionFactory : IAwsSessionFactory
{
    private readonly IAccountService _accountService;
    private readonly ICredentialProtector _protector;

    public AwsSessionFactory(IAccountService accountService, ICredentialProtector protector)
    {
        _accountService = accountService;
        _protector = protector;
    }

    public AWSCredentials GetCredentials()
    {
        var account = _accountService.ActiveAccount
            ?? throw new InvalidOperationException("No active AWS account selected.");

        var secretKey = _protector.Unprotect(account.EncryptedSecretKey);
        return new BasicAWSCredentials(account.AccessKeyId, secretKey);
    }

    public string GetRegion() => _accountService.ActiveRegion;
}
