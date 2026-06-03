using Velopack;
using Velopack.Sources;
using Atlas.Infrastructure.Logging;

namespace Atlas.Services;

public sealed class UpdateService : IUpdateService
{
    private const string RepoUrl = "https://github.com/viniciuslopesgit/atlas-cloud";

    private readonly UpdateManager? _manager;
    private UpdateInfo? _pendingUpdate;

    public string? AvailableVersion => _pendingUpdate?.TargetFullRelease.Version.ToString();

    public UpdateService()
    {
        try
        {
            _manager = new UpdateManager(new GithubSource(RepoUrl, null, false));
        }
        catch (Exception ex)
        {
            FileLogger.Warning($"UpdateManager init skipped: {ex.Message}");
        }
    }

    public async Task<bool> CheckAsync()
    {
        if (_manager == null) return false;
        try
        {
            _pendingUpdate = await _manager.CheckForUpdatesAsync();
            return _pendingUpdate != null;
        }
        catch (Exception ex)
        {
            FileLogger.Warning($"Update check failed: {ex.Message}");
            return false;
        }
    }

    public async Task ApplyAndRestartAsync()
    {
        if (_manager == null || _pendingUpdate == null) return;
        try
        {
            await _manager.DownloadUpdatesAsync(_pendingUpdate);
            _manager.ApplyUpdatesAndRestart(_pendingUpdate);
        }
        catch (Exception ex)
        {
            FileLogger.Error("Failed to apply update", ex);
        }
    }
}
