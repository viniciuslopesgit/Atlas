using Atlas.Models;

namespace Atlas.Services.AWS;

public interface IS3Service
{
    Task<IReadOnlyList<S3BucketModel>> GetBucketsAsync(CancellationToken ct = default);
    Task<IReadOnlyList<S3ObjectModel>> GetObjectsAsync(string bucketName, string prefix = "", CancellationToken ct = default);
    Task<IReadOnlyList<S3ObjectModel>> GetAllObjectsRecursiveAsync(string bucketName, string prefix, CancellationToken ct = default);
    Task UploadFileAsync(string bucketName, string key, string localPath, IProgress<int>? progress = null, CancellationToken ct = default);
    Task DownloadFileAsync(string bucketName, string key, string localPath, IProgress<int>? progress = null, CancellationToken ct = default);
    Task CreateBucketAsync(CreateBucketOptions opts, CancellationToken ct = default);
    Task DeleteBucketAsync(string bucketName, CancellationToken ct = default);
    Task<string> GetFileContentAsync(string bucketName, string key, CancellationToken ct = default);
    Task PutFileContentAsync(string bucketName, string key, string content, CancellationToken ct = default);
}
