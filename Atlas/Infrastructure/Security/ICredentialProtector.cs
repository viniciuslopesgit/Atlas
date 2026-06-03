namespace Atlas.Infrastructure.Security;

public interface ICredentialProtector
{
    string Protect(string plainText);
    string Unprotect(string cipherText);
}
