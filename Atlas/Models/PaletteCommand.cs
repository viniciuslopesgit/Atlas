namespace Atlas.Models;

public sealed class PaletteCommand
{
    public required string Title    { get; init; }
    public required string Category { get; init; }
    public string   Icon            { get; init; } = "";
    public string?  Subtitle        { get; init; }
    public string[]? Keywords       { get; init; }
    public required Action Execute  { get; init; }
}
