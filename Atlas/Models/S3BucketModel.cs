namespace Atlas.Models;

public class S3BucketModel
{
    public string Name { get; set; } = string.Empty;
    public DateTime CreationDate { get; set; }
    public string Region { get; set; } = string.Empty;
    public long ObjectCount { get; set; }
    public long TotalSizeBytes { get; set; }
}

public class S3ObjectModel
{
    public string Key          { get; set; } = string.Empty;
    public long   SizeBytes    { get; set; }
    public DateTime LastModified { get; set; }
    public string StorageClass { get; set; } = string.Empty;
    public string ETag         { get; set; } = string.Empty;
    public bool   IsFolder     { get; set; }

    /// <summary>Last path segment, no trailing slash.</summary>
    public string DisplayName =>
        string.IsNullOrEmpty(Key) ? "" : Key.TrimEnd('/').Split('/').Last();

    /// <summary>"File folder", or uppercase extension + " File", or "File".</summary>
    public string FileType => IsFolder ? "File folder" :
        System.IO.Path.GetExtension(Key) is { Length: > 1 } ext
            ? $"{ext.TrimStart('.').ToUpperInvariant()} File"
            : "File";

    public string DisplaySize => IsFolder ? "" : SizeBytes switch
    {
        0                    => "0 B",
        < 1024               => $"{SizeBytes} B",
        < 1024 * 1024        => $"{SizeBytes / 1024.0:F1} KB",
        < 1024 * 1024 * 1024 => $"{SizeBytes / (1024.0 * 1024):F1} MB",
        _                    => $"{SizeBytes / (1024.0 * 1024 * 1024):F2} GB"
    };
}
