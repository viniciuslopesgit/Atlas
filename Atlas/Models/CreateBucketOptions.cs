namespace Atlas.Models;

public class CreateBucketOptions
{
    // ── General ───────────────────────────────────────────────────
    public string BucketName      { get; set; } = string.Empty;
    public string Region          { get; set; } = "us-east-1";
    public BucketTypeOption       BucketType      { get; set; } = BucketTypeOption.GeneralPurpose;
    public BucketNamespaceOption  BucketNamespace { get; set; } = BucketNamespaceOption.AccountRegional;

    // ── Object Ownership ──────────────────────────────────────────
    /// <summary>false = ACLs disabled (BucketOwnerEnforced) — recommended</summary>
    public bool AclsEnabled { get; set; } = false;

    // ── Block Public Access ───────────────────────────────────────
    public bool BlockNewAcls            { get; set; } = true;
    public bool BlockExistingAcls       { get; set; } = true;
    public bool BlockNewPublicPolicies  { get; set; } = true;
    public bool BlockCrossAccount       { get; set; } = true;

    // ── Versioning ────────────────────────────────────────────────
    public bool VersioningEnabled { get; set; } = false;

    // ── Default Encryption ────────────────────────────────────────
    public BucketEncryptionType Encryption  { get; set; } = BucketEncryptionType.SSE_S3;
    public string?              KmsKeyArn   { get; set; }
    public bool                 BucketKeyEnabled { get; set; } = true;

    // ── Tags ──────────────────────────────────────────────────────
    public Dictionary<string, string> Tags { get; set; } = [];

    // ── Object Lock ───────────────────────────────────────────────
    /// <summary>Enabling Object Lock automatically enables Versioning.</summary>
    public bool ObjectLockEnabled { get; set; } = false;
}

public enum BucketEncryptionType  { SSE_S3, SSE_KMS, DSSE_KMS }
public enum BucketTypeOption      { GeneralPurpose, Directory }
public enum BucketNamespaceOption { Global, AccountRegional }
