using Atlas.Models;

namespace Atlas.Infrastructure.Database;

/// <summary>
/// Persists stack environment variables encrypted at rest (DPAPI).
/// Values are never stored in plain text on disk.
/// </summary>
public interface IStackEnvVarRepository
{
    /// <summary>Insert or update a single env var (value is encrypted before storage).</summary>
    Task UpsertAsync(string stackName, StackEnvVar var);

    /// <summary>Insert or update a batch of env vars for a stack.</summary>
    Task UpsertBatchAsync(string stackName, IEnumerable<StackEnvVar> vars);

    /// <summary>
    /// Returns all vars for a stack with decrypted values populated in
    /// <see cref="StackEnvVar.Value"/>. Empty list if none stored.
    /// </summary>
    Task<IReadOnlyList<StackEnvVar>> GetForStackAsync(string stackName);

    /// <summary>
    /// Returns a dictionary suitable for injecting as <c>TF_VAR_*</c> environment
    /// variables: keys are Terraform var names, values are plain-text secrets.
    /// </summary>
    Task<IReadOnlyDictionary<string, string>> GetTfVarsAsync(string stackName);

    Task DeleteAsync(string stackName, string tfVarName);
    Task DeleteAllForStackAsync(string stackName);
}
