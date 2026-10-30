import Foundation

struct CloudWatchService {
    let client: AWSClient

    func alarms() async throws -> [CloudWatchAlarm] {
        var alarms: [CloudWatchAlarm] = []
        try await client.queryPaged(
            .cloudWatch, "DescribeAlarms",
            ["AlarmTypes.member.1": "MetricAlarm", "MaxRecords": "100"],
            tokenParam: "NextToken",
            tokenPath: { $0.str("DescribeAlarmsResult/NextToken") }
        ) { xml in
            for a in xml.list("DescribeAlarmsResult/MetricAlarms", item: "member") {
                alarms.append(CloudWatchAlarm(
                    name: a.str("AlarmName"),
                    state: a.str("StateValue").isEmpty ? "UNKNOWN" : a.str("StateValue"),
                    metricName: a.str("MetricName"),
                    namespace: a.str("Namespace"),
                    description: a.str("AlarmDescription"),
                    updatedAt: a.date("StateUpdatedTimestamp"),
                    alarmArn: a.str("AlarmArn")))
            }
        }
        func rank(_ s: String) -> Int { s == "ALARM" ? 0 : s == "INSUFFICIENT_DATA" ? 1 : 2 }
        return alarms.sorted { (rank($0.state), $0.name) < (rank($1.state), $1.name) }
    }

    /// Metric and composite alarms in the ALARM state, across every page (100 alarms each).
    func activeAlarmCount() async throws -> Int {
        var count = 0
        try await client.queryPaged(.cloudWatch, "DescribeAlarms", [
            "StateValue": "ALARM", "MaxRecords": "100",
            "AlarmTypes.member.1": "MetricAlarm", "AlarmTypes.member.2": "CompositeAlarm",
        ], tokenParam: "NextToken", tokenPath: { $0.str("DescribeAlarmsResult/NextToken") }) { xml in
            count += xml.list("DescribeAlarmsResult/MetricAlarms", item: "member").count
                + xml.list("DescribeAlarmsResult/CompositeAlarms", item: "member").count
        }
        return count
    }

    func ec2Metric(_ instanceId: String, _ metric: String, _ statistic: String,
                   _ start: Date, _ end: Date) async throws -> [MetricPoint] {
        let xml = try await client.query(.cloudWatch, "GetMetricStatistics", [
            "Namespace": "AWS/EC2",
            "MetricName": metric,
            "Dimensions.member.1.Name": "InstanceId",
            "Dimensions.member.1.Value": instanceId,
            "StartTime": AWSDate.iso(start),
            "EndTime": AWSDate.iso(end),
            "Period": "300",
            "Statistics.member.1": statistic,
        ])
        return xml.list("GetMetricStatisticsResult/Datapoints", item: "member")
            .compactMap { p in
                guard let t = p.date("Timestamp") else { return nil }
                return MetricPoint(timestamp: t, value: p.double(statistic) ?? 0)
            }
            .sorted { $0.timestamp < $1.timestamp }
    }
}
