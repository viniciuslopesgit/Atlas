namespace Atlas.Models;

public class AwsAccount
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = string.Empty;
    public string AccessKeyId { get; set; } = string.Empty;
    // SecretAccessKey is stored encrypted; kept in memory decrypted only at runtime
    public string EncryptedSecretKey { get; set; } = string.Empty;
    public string DefaultRegion { get; set; } = "us-east-1";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public bool IsActive { get; set; }
}
