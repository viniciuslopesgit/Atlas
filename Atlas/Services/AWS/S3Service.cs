using Amazon.S3;
using Amazon.S3.Model;
using Amazon.S3.Transfer;
using Atlas.Infrastructure;
using Atlas.Models;
using System.IO;
using VersionStatus = Amazon.S3.VersionStatus;

namespace Atlas.Services.AWS;

public sealed class S3Service : IS3Service
{
    private readonly IAwsSessionFactory _session;
    private readonly AwsClientFactory _clients;

    public S3Service(IAwsSessionFactory session, AwsClientFactory clients)
    {
        _session = session;
        _clients = clients;
    }

    public async Task<IReadOnlyList<S3BucketModel>> GetBucketsAsync(CancellationToken ct = default)
    {
        var client = _clients.GetS3(_session.GetCredentials(), _session.GetRegion());
        var response = await client.ListBucketsAsync(ct);
        return response.Buckets.Select(b => new S3BucketModel
        {
            Name         = b.BucketName,
            CreationDate = b.CreationDate
        }).ToList();
    }

    public async Task<IReadOnlyList<S3ObjectModel>> GetObjectsAsync(
        string bucketName, string prefix = "", CancellationToken ct = default)
    {
        var client  = _clients.GetS3(_session.GetCredentials(), _session.GetRegion());
        var folders = new List<S3ObjectModel>();
        var files   = new List<S3ObjectModel>();
        string? continuationToken = null;

        do
        {
            var response = await client.ListObjectsV2Async(new ListObjectsV2Request
            {
                BucketName        = bucketName,
                Prefix            = prefix,
                Delimiter         = "/",
                MaxKeys           = 1000,
                ContinuationToken = continuationToken
            }, ct);

            // Common prefixes = virtual folders at this level
            foreach (var cp in response.CommonPrefixes)
                folders.Add(new S3ObjectModel { Key = cp, IsFolder = true });

            // Objects at this level (exclude the folder-placeholder entry itself)
            files.AddRange(response.S3Objects
                .Where(o => o.Key != prefix)
                .Select(o => new S3ObjectModel
                {
                    Key          = o.Key,
                    SizeBytes    = o.Size,
                    LastModified = o.LastModified,
                    StorageClass = o.StorageClass?.Value ?? "STANDARD",
                    ETag         = o.ETag?.Trim('"') ?? string.Empty
                }));

            continuationToken = response.IsTruncated ? response.NextContinuationToken : null;

        } while (continuationToken != null);

        // Folders first (sorted), then files (sorted)
        return [.. folders.OrderBy(f => f.DisplayName),
                .. files.OrderBy(f => f.DisplayName)];
    }

    public async Task<IReadOnlyList<S3ObjectModel>> GetAllObjectsRecursiveAsync(
        string bucketName, string prefix, CancellationToken ct = default)
    {
        var client  = _clients.GetS3(_session.GetCredentials(), _session.GetRegion());
        var results = new List<S3ObjectModel>();
        string? continuationToken = null;

        do
        {
            var response = await client.ListObjectsV2Async(new ListObjectsV2Request
            {
                BucketName        = bucketName,
                Prefix            = prefix,
                MaxKeys           = 1000,
                ContinuationToken = continuationToken
            }, ct);

            results.AddRange(response.S3Objects
                .Where(o => o.Key != prefix)
                .Select(o => new S3ObjectModel
                {
                    Key          = o.Key,
                    SizeBytes    = o.Size,
                    LastModified = o.LastModified,
                    StorageClass = o.StorageClass?.Value ?? "STANDARD",
                    ETag         = o.ETag?.Trim('"') ?? string.Empty
                }));

            continuationToken = response.IsTruncated ? response.NextContinuationToken : null;
        } while (continuationToken != null);

        return results;
    }

    public async Task UploadFileAsync(
        string bucketName, string key, string localPath,
        IProgress<int>? progress = null, CancellationToken ct = default)
    {
        var client = _clients.GetS3(_session.GetCredentials(), _session.GetRegion());
        using var transfer = new TransferUtility(client);

        var request = new TransferUtilityUploadRequest
        {
            BucketName = bucketName,
            Key        = key,
            FilePath   = localPath
        };

        if (progress != null)
        {
            long fileSize = new FileInfo(localPath).Length;
            request.UploadProgressEvent += (_, e) =>
                progress.Report(fileSize > 0 ? (int)(e.TransferredBytes * 100 / fileSize) : 0);
        }

        await transfer.UploadAsync(request, ct);
    }

    public async Task CreateBucketAsync(CreateBucketOptions opts, CancellationToken ct = default)
    {
        var client  = _clients.GetS3(_session.GetCredentials(), _session.GetRegion());
        var request = new PutBucketRequest { BucketName = opts.BucketName, UseClientRegion = false };

        if (!string.Equals(opts.Region, "us-east-1", StringComparison.OrdinalIgnoreCase))
            request.BucketRegionName = opts.Region;

        await client.PutBucketAsync(request, ct);

        // Object Ownership
        var ownership = opts.AclsEnabled
            ? ObjectOwnership.BucketOwnerPreferred
            : ObjectOwnership.BucketOwnerEnforced;

        await client.PutBucketOwnershipControlsAsync(new PutBucketOwnershipControlsRequest
        {
            BucketName        = opts.BucketName,
            OwnershipControls = new OwnershipControls
            {
                Rules = [new OwnershipControlsRule { ObjectOwnership = ownership }]
            }
        }, ct);

        // Block Public Access
        await client.PutPublicAccessBlockAsync(new PutPublicAccessBlockRequest
        {
            BucketName = opts.BucketName,
            PublicAccessBlockConfiguration = new PublicAccessBlockConfiguration
            {
                BlockPublicAcls       = opts.BlockNewAcls,
                IgnorePublicAcls      = opts.BlockExistingAcls,
                BlockPublicPolicy     = opts.BlockNewPublicPolicies,
                RestrictPublicBuckets = opts.BlockCrossAccount
            }
        }, ct);

        // Versioning
        if (opts.VersioningEnabled || opts.ObjectLockEnabled)
        {
            await client.PutBucketVersioningAsync(new PutBucketVersioningRequest
            {
                BucketName       = opts.BucketName,
                VersioningConfig = new S3BucketVersioningConfig
                {
                    Status = VersionStatus.Enabled
                }
            }, ct);
        }

        // Default Encryption
        ServerSideEncryptionRule encRule = opts.Encryption switch
        {
            BucketEncryptionType.SSE_KMS => new ServerSideEncryptionRule
            {
                ServerSideEncryptionByDefault = new ServerSideEncryptionByDefault
                {
                    ServerSideEncryptionAlgorithm = ServerSideEncryptionMethod.AWSKMS,
                    ServerSideEncryptionKeyManagementServiceKeyId = opts.KmsKeyArn
                },
                BucketKeyEnabled = opts.BucketKeyEnabled
            },
            BucketEncryptionType.DSSE_KMS => new ServerSideEncryptionRule
            {
                ServerSideEncryptionByDefault = new ServerSideEncryptionByDefault
                {
                    ServerSideEncryptionAlgorithm = ServerSideEncryptionMethod.AWSKMSDSSE,
                    ServerSideEncryptionKeyManagementServiceKeyId = opts.KmsKeyArn
                }
            },
            _ => new ServerSideEncryptionRule
            {
                ServerSideEncryptionByDefault = new ServerSideEncryptionByDefault
                {
                    ServerSideEncryptionAlgorithm = ServerSideEncryptionMethod.AES256
                },
                BucketKeyEnabled = false
            }
        };

        await client.PutBucketEncryptionAsync(new PutBucketEncryptionRequest
        {
            BucketName = opts.BucketName,
            ServerSideEncryptionConfiguration = new ServerSideEncryptionConfiguration
            {
                ServerSideEncryptionRules = [encRule]
            }
        }, ct);

        // Tags
        if (opts.Tags.Count > 0)
        {
            await client.PutBucketTaggingAsync(new PutBucketTaggingRequest
            {
                BucketName = opts.BucketName,
                TagSet     = opts.Tags
                                 .Select(kv => new Tag { Key = kv.Key, Value = kv.Value })
                                 .ToList()
            }, ct);
        }
    }

    public async Task DeleteBucketAsync(string bucketName, CancellationToken ct = default)
    {
        var client = _clients.GetS3(_session.GetCredentials(), _session.GetRegion());

        // Delete all objects (required before bucket deletion)
        string? continuationToken = null;
        do
        {
            var list = await client.ListObjectsV2Async(new ListObjectsV2Request
            {
                BucketName        = bucketName,
                MaxKeys           = 1000,
                ContinuationToken = continuationToken
            }, ct);

            if (list.S3Objects.Count > 0)
            {
                await client.DeleteObjectsAsync(new DeleteObjectsRequest
                {
                    BucketName = bucketName,
                    Objects    = list.S3Objects
                                     .Select(o => new KeyVersion { Key = o.Key })
                                     .ToList()
                }, ct);
            }

            continuationToken = list.IsTruncated ? list.NextContinuationToken : null;
        } while (continuationToken != null);

        // Delete all object versions (if versioning was enabled)
        string? versionKeyMarker = null;
        do
        {
            var versions = await client.ListVersionsAsync(new ListVersionsRequest
            {
                BucketName     = bucketName,
                MaxKeys        = 1000,
                KeyMarker      = versionKeyMarker
            }, ct);

            if (versions.Versions.Count > 0)
            {
                await client.DeleteObjectsAsync(new DeleteObjectsRequest
                {
                    BucketName = bucketName,
                    Objects    = versions.Versions
                                         .Select(v => new KeyVersion { Key = v.Key, VersionId = v.VersionId })
                                         .ToList()
                }, ct);
            }

            versionKeyMarker = versions.IsTruncated ? versions.NextKeyMarker : null;
        } while (versionKeyMarker != null);

        await client.DeleteBucketAsync(bucketName, ct);
    }

    public async Task DownloadFileAsync(
        string bucketName, string key, string localPath,
        IProgress<int>? progress = null, CancellationToken ct = default)
    {
        var client = _clients.GetS3(_session.GetCredentials(), _session.GetRegion());
        using var transfer = new TransferUtility(client);

        var request = new TransferUtilityDownloadRequest
        {
            BucketName = bucketName,
            Key        = key,
            FilePath   = localPath
        };

        if (progress != null)
            request.WriteObjectProgressEvent += (_, e) => progress.Report(e.PercentDone);

        await transfer.DownloadAsync(request, ct);
    }
}
