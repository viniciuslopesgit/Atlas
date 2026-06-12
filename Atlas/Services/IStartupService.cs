namespace Atlas.Services;

public interface IStartupService
{
    bool IsEnabled { get; }
    void Set(bool enabled);
}
