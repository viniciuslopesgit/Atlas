using CommunityToolkit.Mvvm.ComponentModel;
using Atlas.Infrastructure.Logging;

namespace Atlas.ViewModels;

/// <summary>
/// Base class that manages a single in-flight async load.
/// Calling BeginLoad() cancels any previous load and returns a fresh token.
/// Subclasses never need to manage CancellationTokenSource manually.
/// </summary>
public abstract partial class AsyncViewModel : ObservableObject, IDisposable
{
    private CancellationTokenSource? _cts;
    private DateTime _lastLoaded = DateTime.MinValue;

    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private string? _errorMessage;

    /// <summary>Minimum seconds between auto-reloads to avoid hammering AWS on rapid navigation.</summary>
    protected virtual int StalenessSeconds => 30;

    protected bool IsDataStale =>
        (DateTime.UtcNow - _lastLoaded).TotalSeconds > StalenessSeconds;

    /// <summary>
    /// Call at the start of every Load method.
    /// Cancels any running load and returns a fresh CancellationToken.
    /// </summary>
    protected CancellationToken BeginLoad()
    {
        _cts?.Cancel();
        _cts?.Dispose();
        _cts = new CancellationTokenSource();
        IsLoading = true;
        ErrorMessage = null;
        return _cts.Token;
    }

    protected void EndLoad(bool success = true)
    {
        IsLoading = false;
        if (success) _lastLoaded = DateTime.UtcNow;
    }

    protected void HandleError(string context, Exception ex)
    {
        if (ex is OperationCanceledException) return; // navigation cancel — not an error
        FileLogger.Error(context, ex);
        ErrorMessage = ex.Message;
        EndLoad(false);
    }

    public void Dispose()
    {
        Dispose(true);
        GC.SuppressFinalize(this);
    }

    protected virtual void Dispose(bool disposing)
    {
        if (disposing)
        {
            _cts?.Cancel();
            _cts?.Dispose();
            _cts = null;
        }
    }
}
