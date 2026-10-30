import Foundation
import os

let log = Logger(subsystem: "io.cloud-atlas.Atlas", category: "app")

struct DashboardService {
    let client: AWSClient

    /// Loads the resource sources asked for concurrently; one failing permission does not break the rest.
    /// Costs are loaded apart (`costs`), since each Cost Explorer request is billed.
    func resources(_ sources: Set<DashboardSource>) async -> DashboardSummary {
        async let instances = load(.ec2, sources) { try await Ec2Service(client: client).instances() }
        async let buckets = load(.s3, sources) { try await S3Service(client: client).buckets() }
        async let alarms = load(.alarms, sources) { try await CloudWatchService(client: client).activeAlarmCount() }
        async let identity = load(.identity, sources) { try await StsService(client: client).callerIdentity() }

        var s = DashboardSummary()
        s.instances = Self.value(await instances, .ec2, &s.errors).map(InstanceCounts.init)
        s.bucketCount = Self.value(await buckets, .s3, &s.errors)?.count
        s.activeAlarms = Self.value(await alarms, .alarms, &s.errors)
        s.identity = Self.value(await identity, .identity, &s.errors)
        s.region = client.region
        s.lastRefreshed = Date()
        return s
    }

    func costs(_ month: CostMonth) async throws -> CostService.MonthCosts {
        do {
            return try await CostService(client: client).monthCosts(month)
        } catch {
            log.error("Dashboard: failed to load costs: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    private static func value<T>(_ r: Result<T, Error>?, _ source: DashboardSource,
                                 _ errors: inout [DashboardSource: String]) -> T? {
        switch r {
        case .success(let v): return v
        case .failure(let e): errors[source] = e.localizedDescription; return nil
        case nil: return nil
        }
    }

    private func load<T>(_ source: DashboardSource, _ sources: Set<DashboardSource>,
                         _ op: () async throws -> T) async -> Result<T, Error>? {
        sources.contains(source) ? await capture(source.name, op) : nil
    }

    private func capture<T>(_ context: String, _ op: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await op())
        } catch {
            log.error("Dashboard: failed to load \(context, privacy: .public): \(error.localizedDescription, privacy: .private)")
            return .failure(error)
        }
    }
}
