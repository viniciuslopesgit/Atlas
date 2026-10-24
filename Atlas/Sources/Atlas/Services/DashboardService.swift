import Foundation
import os

let log = Logger(subsystem: "io.cloud-atlas.Atlas", category: "app")

struct DashboardService {
    let client: AWSClient

    /// Loads all dashboard data concurrently; one failing permission does not break the rest.
    func summary(month: Date) async -> DashboardSummary {
        async let instances = capture("EC2 instances") { try await Ec2Service(client: client).instances() }
        async let buckets = capture("S3 buckets") { try await S3Service(client: client).buckets() }
        async let alarms = capture("CloudWatch alarms") { try await CloudWatchService(client: client).activeAlarmCount() }
        async let identity = capture("STS identity") { try await StsService(client: client).callerIdentity() }
        async let costs = capture("Cost Explorer") { try await CostService(client: client).monthCosts(month) }

        var s = DashboardSummary()
        var warnings: [String] = []

        switch await instances {
        case .success(let list):
            s.runningInstances = list.filter { $0.state == "running" }.count
            s.stoppedInstances = list.filter { $0.state == "stopped" }.count
            s.totalInstances = list.count
        case .failure(let e): warnings.append(e.localizedDescription)
        }
        switch await buckets {
        case .success(let list): s.s3BucketCount = list.count
        case .failure(let e): warnings.append(e.localizedDescription)
        }
        switch await alarms {
        case .success(let n): s.activeAlarms = n
        case .failure(let e): warnings.append(e.localizedDescription)
        }
        switch await identity {
        case .success(let id):
            s.accountId = id.account
            s.accountArn = id.arn
        case .failure(let e): warnings.append(e.localizedDescription)
        }
        switch await costs {
        case .success(let c):
            s.currentMonthCost = c.current
            s.lastMonthCost = c.last
            s.forecastedMonthCost = c.forecast
            s.currency = c.currency
            s.dailyCosts = c.daily
            s.serviceCosts = c.services
        case .failure(let e): warnings.append(e.localizedDescription)
        }

        s.region = client.region
        s.lastRefreshed = Date()
        s.warnings = warnings
        return s
    }

    private func capture<T>(_ context: String, _ op: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await op())
        } catch {
            log.error("Dashboard: failed to load \(context, privacy: .public): \(error.localizedDescription, privacy: .private)")
            return .failure(LabeledError(context: context, underlying: error))
        }
    }
}

struct LabeledError: LocalizedError {
    let context: String
    let underlying: Error
    var errorDescription: String? { "\(context): \(underlying.localizedDescription)" }
}
