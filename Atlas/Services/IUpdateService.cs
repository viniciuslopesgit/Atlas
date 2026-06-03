namespace Atlas.Services;

public interface IUpdateService
{
    string? AvailableVersion { get; }
    Task<bool> CheckAsync();
    Task ApplyAndRestartAsync();
}
