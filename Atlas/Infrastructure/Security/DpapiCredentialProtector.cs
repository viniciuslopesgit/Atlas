using System.Security.Cryptography;
using System.Text;

namespace Atlas.Infrastructure.Security;

/// <summary>
/// Uses Windows DPAPI — data is tied to the current user's Windows account.
/// No key management required; decryption only works on the same machine+user.
///
/// App-specific entropy (v2: prefix) prevents other processes running as the same
/// Windows user from calling ProtectedData.Unprotect() to access stored credentials.
/// Old v1 blobs (no prefix) are decrypted without entropy for backward compatibility.
/// </summary>
public sealed class DpapiCredentialProtector : ICredentialProtector
{
    // Constant entropy tied to this application. Prevents a different app running
    // under the same Windows user account from decrypting our DPAPI-protected blobs.
    private static readonly byte[] Entropy =
        "Atlas-v2-Credential-Protection-Salt"u8.ToArray();

    private const string V2Prefix = "v2:";

    public string Protect(string plainText)
    {
        var bytes     = Encoding.UTF8.GetBytes(plainText);
        var encrypted = ProtectedData.Protect(bytes, Entropy, DataProtectionScope.CurrentUser);
        return V2Prefix + Convert.ToBase64String(encrypted);
    }

    public string Unprotect(string cipherText)
    {
        // v2: format — encrypted with app-specific entropy
        if (cipherText.StartsWith(V2Prefix, StringComparison.Ordinal))
        {
            var encrypted = Convert.FromBase64String(cipherText[V2Prefix.Length..]);
            var decrypted = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(decrypted);
        }

        // Legacy v1 format — no entropy (re-encrypted to v2 on next Save via AccountService)
        var legacyEncrypted = Convert.FromBase64String(cipherText);
        var legacyDecrypted = ProtectedData.Unprotect(legacyEncrypted, null, DataProtectionScope.CurrentUser);
        return Encoding.UTF8.GetString(legacyDecrypted);
    }
}
