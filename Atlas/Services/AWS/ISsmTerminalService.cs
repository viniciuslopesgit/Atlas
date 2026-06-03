namespace Atlas.Services.AWS;

public interface ISsmTerminalService
{
    Task OpenSessionAsync(string instanceId, string region, CancellationToken ct = default);
}
