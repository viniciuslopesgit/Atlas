namespace Atlas.Models;

public record MetricPoint(DateTime Timestamp, double Value);

public record Ec2InstanceMetrics(
    string InstanceId,
    IReadOnlyList<MetricPoint> CpuUtilization,
    IReadOnlyList<MetricPoint> NetworkIn,
    IReadOnlyList<MetricPoint> NetworkOut,
    IReadOnlyList<MetricPoint> DiskWriteBytes
);
