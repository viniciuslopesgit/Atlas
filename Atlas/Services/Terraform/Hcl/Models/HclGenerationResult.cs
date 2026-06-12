namespace Atlas.Services.Terraform.Hcl.Models;

public sealed class HclGenerationResult
{
    public bool   Success      { get; init; }
    public string Content      { get; init; } = string.Empty;
    public string? OutputPath  { get; init; }
    public bool   WasWritten   { get; init; }
    public string? ErrorMessage { get; init; }

    /// <summary>Chaves dos blocos ATLAS-MANAGED presentes no conteúdo gerado.</summary>
    public IReadOnlyList<string> ManagedBlockKeys { get; init; } = [];

    // ── Factories ─────────────────────────────────────────────────────────

    internal static HclGenerationResult Ok(
        string content, string? outputPath, bool written, IReadOnlyList<string> keys) => new()
    {
        Success          = true,
        Content          = content,
        OutputPath       = outputPath,
        WasWritten       = written,
        ManagedBlockKeys = keys,
    };

    internal static HclGenerationResult Fail(string error) => new()
    {
        Success       = false,
        ErrorMessage  = error,
    };
}
