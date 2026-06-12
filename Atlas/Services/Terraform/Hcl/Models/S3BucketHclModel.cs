namespace Atlas.Services.Terraform.Hcl.Models;

public sealed class S3BucketHclModel
{
    // ── Identificador do recurso Terraform ────────────────────────────────
    public string ResourceName   { get; init; } = "main";

    // ── Bucket ────────────────────────────────────────────────────────────
    public string BucketName     { get; init; } = string.Empty;
    public bool   ForceDestroy   { get; init; }

    // ── Bloqueio público (defaults seguros) ───────────────────────────────
    public bool   BlockPublicAcls       { get; init; } = true;
    public bool   BlockPublicPolicy     { get; init; } = true;
    public bool   IgnorePublicAcls      { get; init; } = true;
    public bool   RestrictPublicBuckets { get; init; } = true;

    // ── Funcionalidades opcionais ─────────────────────────────────────────
    public bool   Versioning            { get; init; }
    public bool   ServerSideEncryption  { get; init; } = true;

    // ── Logging ───────────────────────────────────────────────────────────
    public string? LoggingTargetBucket  { get; init; }
    public string? LoggingTargetPrefix  { get; init; }

    // ── Tags ──────────────────────────────────────────────────────────────
    public IReadOnlyList<HclTag> Tags   { get; init; } = [];

    // ── Helper a partir do modelo Atlas ──────────────────────────────────

    public static S3BucketHclModel FromAtlasBucket(Atlas.Models.S3BucketModel bucket) =>
        new()
        {
            ResourceName = SanitizeIdentifier(bucket.Name),
            BucketName   = bucket.Name,
            Tags =
            [
                new("Region", bucket.Region),
            ],
        };

    private static string SanitizeIdentifier(string raw) =>
        System.Text.RegularExpressions.Regex
            .Replace(raw.ToLowerInvariant().Replace('-', '_').Replace('.', '_'), @"[^a-z0-9_]", "")
            .TrimStart('0', '1', '2', '3', '4', '5', '6', '7', '8', '9')
            .DefaultIfEmpty('r').ToString() ?? "bucket";
}
