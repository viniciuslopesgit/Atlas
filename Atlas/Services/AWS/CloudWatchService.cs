using Amazon.CloudWatch;
using Amazon.CloudWatch.Model;
using Atlas.Infrastructure;
using Atlas.Infrastructure.Logging;
using Atlas.Models;

namespace Atlas.Services.AWS;

public sealed class CloudWatchService : ICloudWatchService
{
    private readonly IAwsSessionFactory _session;
    private readonly AwsClientFactory   _clients;

    public CloudWatchService(IAwsSessionFactory session, AwsClientFactory clients)
    {
        _session = session;
        _clients = clients;
    }

    public async Task<IReadOnlyList<CloudWatchAlarmModel>> GetAlarmsAsync(CancellationToken ct = default)
    {
        try
        {
            var cw     = _clients.GetCloudWatch(_session.GetCredentials(), _session.GetRegion());
            var alarms = new List<CloudWatchAlarmModel>();
            string? nextToken = null;

            do
            {
                var resp = await cw.DescribeAlarmsAsync(new DescribeAlarmsRequest
                {
                    AlarmTypes = [AlarmType.MetricAlarm],
                    NextToken  = nextToken,
                    MaxRecords = 100
                }, ct);

                foreach (var a in resp.MetricAlarms)
                {
                    alarms.Add(new CloudWatchAlarmModel
                    {
                        Name        = a.AlarmName,
                        State       = a.StateValue?.Value ?? "UNKNOWN",
                        MetricName  = a.MetricName ?? string.Empty,
                        Namespace   = a.Namespace  ?? string.Empty,
                        Description = a.AlarmDescription ?? string.Empty,
                        UpdatedAt   = a.StateUpdatedTimestamp,
                        AlarmArn    = a.AlarmArn ?? string.Empty,
                    });
                }

                nextToken = resp.NextToken;
            }
            while (!string.IsNullOrEmpty(nextToken));

            return alarms
                .OrderBy(a => a.State == "ALARM" ? 0 : a.State == "INSUFFICIENT_DATA" ? 1 : 2)
                .ThenBy(a => a.Name)
                .ToList();
        }
        catch (Exception ex)
        {
            FileLogger.Error("CloudWatchService.GetAlarmsAsync", ex);
            throw;
        }
    }
}
