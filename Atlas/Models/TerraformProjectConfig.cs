namespace Atlas.Models;

public sealed class TerraformProjectConfig
{
    public string Id { get; init; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = string.Empty;
    public string RootPath { get; set; } = string.Empty;
    public string DefaultWorkspace { get; set; } = "default";
    public string BackendType { get; set; } = "local";
    public bool AutoCommitEnabled { get; set; }
    public string ManagedModules { get; set; } = string.Empty;
    public DateTime CreatedAt { get; init; } = DateTime.UtcNow;
    public bool IsInitialized { get; set; }
}
