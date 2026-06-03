namespace Atlas.Models;

public class IamPolicyModel
{
    public string PolicyName       { get; set; } = string.Empty;
    public string PolicyId         { get; set; } = string.Empty;
    public string Arn              { get; set; } = string.Empty;
    public string Path             { get; set; } = string.Empty;
    public string Description      { get; set; } = string.Empty;
    public DateTime CreateDate     { get; set; }
    public DateTime UpdateDate     { get; set; }
    public int AttachmentCount     { get; set; }
    public string DefaultVersionId { get; set; } = string.Empty;
    public bool IsAttachable       { get; set; }
    public string Scope            { get; set; } = "Local"; // "Local" | "AWS"
}
