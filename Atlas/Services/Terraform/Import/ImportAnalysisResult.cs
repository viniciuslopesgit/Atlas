namespace Atlas.Services.Terraform.Import;

public sealed class ImportAnalysisResult
{
    public bool   Success      { get; init; }
    public string? ErrorMessage { get; init; }
    public string  Region       { get; init; } = string.Empty;
    public TimeSpan Duration    { get; init; }

    /// <summary>Todos os recursos descobertos, de todos os tipos.</summary>
    public IReadOnlyList<DiscoveredResource> Resources { get; init; } = [];

    /// <summary>Número total de recursos descobertos.</summary>
    public int TotalDiscovered => Resources.Count;

    /// <summary>Número de recursos por tipo.</summary>
    public IReadOnlyDictionary<AwsResourceType, int> CountByType { get; init; } =
        new Dictionary<AwsResourceType, int>();

    /// <summary>Erros não-fatais por tipo (ex.: sem permissão para listar S3).</summary>
    public IReadOnlyDictionary<AwsResourceType, string> PartialErrors { get; init; } =
        new Dictionary<AwsResourceType, string>();

    /// <summary>Recursos com <see cref="ImportConfidence.High"/>.</summary>
    public IReadOnlyList<DiscoveredResource> HighConfidence =>
        Resources.Where(r => r.Confidence == ImportConfidence.High).ToList();

    /// <summary>Recursos com <see cref="ImportConfidence.Low"/> — necessitam revisão manual.</summary>
    public IReadOnlyList<DiscoveredResource> NeedsReview =>
        Resources.Where(r => r.Confidence == ImportConfidence.Low).ToList();

    // ── Factories ─────────────────────────────────────────────────────────

    internal static ImportAnalysisResult Ok(
        IReadOnlyList<DiscoveredResource>              resources,
        IReadOnlyDictionary<AwsResourceType, string>   partialErrors,
        string                                          region,
        TimeSpan                                        duration) => new()
    {
        Success       = true,
        Resources     = resources,
        PartialErrors = partialErrors,
        Region        = region,
        Duration      = duration,
        CountByType   = resources
                            .GroupBy(r => r.ResourceType)
                            .ToDictionary(g => g.Key, g => g.Count()),
    };

    internal static ImportAnalysisResult Fail(string error) => new()
    {
        Success      = false,
        ErrorMessage = error,
    };
}
