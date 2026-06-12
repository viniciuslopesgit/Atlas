using Atlas.Infrastructure.Logging;
using Atlas.Models;
using Atlas.Services.Terraform;
using Atlas.Services.Terraform.Hcl.Models;

namespace Atlas.Services.AWS;

/// <summary>
/// Decorator de <see cref="IS3Service"/> que, após <see cref="CreateBucketAsync"/>,
/// gera automaticamente o HCL Terraform correspondente em background.
/// Todas as outras chamadas são delegadas ao serviço interior sem modificação.
/// </summary>
public sealed class TerraformAwareS3Service : IS3Service
{
    private readonly IS3Service        _inner;
    private readonly ITerraformService _terraform;

    public TerraformAwareS3Service(IS3Service inner, ITerraformService terraform)
    {
        _inner     = inner;
        _terraform = terraform;
    }

    // ── CreateBucketAsync — ponto de integração ───────────────────────────

    public async Task CreateBucketAsync(CreateBucketOptions opts, CancellationToken ct = default)
    {
        await _inner.CreateBucketAsync(opts, ct);

        if (_terraform.ActiveProject is not null)
            _ = Task.Run(() => GenerateHclAsync(opts), CancellationToken.None);
    }

    // ── Passthrough ───────────────────────────────────────────────────────

    public Task<IReadOnlyList<S3BucketModel>> GetBucketsAsync(CancellationToken ct = default)
        => _inner.GetBucketsAsync(ct);

    public Task<IReadOnlyList<S3ObjectModel>> GetObjectsAsync(
        string bucketName, string prefix = "", CancellationToken ct = default)
        => _inner.GetObjectsAsync(bucketName, prefix, ct);

    public Task<IReadOnlyList<S3ObjectModel>> GetAllObjectsRecursiveAsync(
        string bucketName, string prefix, CancellationToken ct = default)
        => _inner.GetAllObjectsRecursiveAsync(bucketName, prefix, ct);

    public Task UploadFileAsync(string bucketName, string key, string localPath,
        IProgress<int>? progress = null, CancellationToken ct = default)
        => _inner.UploadFileAsync(bucketName, key, localPath, progress, ct);

    public Task DownloadFileAsync(string bucketName, string key, string localPath,
        IProgress<int>? progress = null, CancellationToken ct = default)
        => _inner.DownloadFileAsync(bucketName, key, localPath, progress, ct);

    public Task DeleteBucketAsync(string bucketName, CancellationToken ct = default)
        => _inner.DeleteBucketAsync(bucketName, ct);

    public Task<string> GetFileContentAsync(string bucketName, string key, CancellationToken ct = default)
        => _inner.GetFileContentAsync(bucketName, key, ct);

    public Task PutFileContentAsync(string bucketName, string key, string content, CancellationToken ct = default)
        => _inner.PutFileContentAsync(bucketName, key, content, ct);

    // ── HCL generation ────────────────────────────────────────────────────

    private async Task GenerateHclAsync(CreateBucketOptions opts)
    {
        try
        {
            var model  = BuildHclModel(opts);
            var result = await _terraform.GenerateS3ResourceAsync(model);

            if (result.Success)
                FileLogger.Info($"[TerraformAwareS3] Auto-generated HCL for '{opts.BucketName}' → {result.WrittenFiles.FirstOrDefault()}");
            else
                FileLogger.Warning($"[TerraformAwareS3] HCL generation failed for '{opts.BucketName}': {result.ErrorMessage}");
        }
        catch (Exception ex)
        {
            FileLogger.Error("[TerraformAwareS3] Background HCL generation threw", ex);
        }
    }

    private static S3BucketHclModel BuildHclModel(CreateBucketOptions opts)
    {
        var resourceName = SanitizeTfName(opts.BucketName);

        return new S3BucketHclModel
        {
            ResourceName          = resourceName,
            BucketName            = opts.BucketName,
            BlockPublicAcls       = opts.BlockNewAcls,
            BlockPublicPolicy     = opts.BlockNewPublicPolicies,
            IgnorePublicAcls      = opts.BlockExistingAcls,
            RestrictPublicBuckets = opts.BlockCrossAccount,
            Versioning            = opts.VersioningEnabled,
            // BUG FIX: "|| true" tornava a condição sempre verdadeira (lógica morta).
            // Todos os tipos suportados (SSE_S3, SSE_KMS, DSSE_KMS) são SSE — o campo é sempre true.
            ServerSideEncryption  = true,
            Tags = opts.Tags
                       .Select(kv => new HclTag(kv.Key, kv.Value))
                       .ToList(),
        };
    }

    private static string SanitizeTfName(string raw)
    {
        var lower = raw.ToLowerInvariant()
                       .Replace('-', '_').Replace('.', '_').Replace(' ', '_');
        var clean = System.Text.RegularExpressions.Regex
                        .Replace(lower, @"[^a-z0-9_]", "_")
                        .Trim('_');
        clean = System.Text.RegularExpressions.Regex.Replace(clean, "_+", "_");
        if (clean.Length > 0 && char.IsDigit(clean[0])) clean = "r_" + clean;
        return string.IsNullOrEmpty(clean) ? "bucket" : clean;
    }
}
