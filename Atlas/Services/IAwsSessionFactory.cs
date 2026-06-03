using Amazon.Runtime;

namespace Atlas.Services;

/// <summary>
/// Creates AWS SDK credentials from the currently active account.
/// Centralises credential resolution so all services stay consistent.
/// </summary>
public interface IAwsSessionFactory
{
    AWSCredentials GetCredentials();
    string GetRegion();
}
