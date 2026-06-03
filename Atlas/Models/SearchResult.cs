namespace Atlas.Models;

public enum SearchResultType { EC2Instance, S3Bucket }

public class SearchResult
{
    public SearchResultType ResourceType { get; set; }
    public string Name       { get; set; } = string.Empty;
    public string Id         { get; set; } = string.Empty;
    public string Region     { get; set; } = string.Empty;
    public string State      { get; set; } = string.Empty;
    public string TypeLabel  { get; set; } = string.Empty;
    public string Icon       { get; set; } = string.Empty;
}
