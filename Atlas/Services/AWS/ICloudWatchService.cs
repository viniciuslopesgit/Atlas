using Atlas.Models;

namespace Atlas.Services.AWS;

public interface ICloudWatchService
{
    Task<IReadOnlyList<CloudWatchAlarmModel>> GetAlarmsAsync(CancellationToken ct = default);
}
