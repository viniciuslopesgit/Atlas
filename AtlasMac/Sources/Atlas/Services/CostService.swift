import Foundation

/// Cost Explorer (JSON 1.1, always us-east-1).
struct CostService {
    let client: AWSClient

    private func call(_ op: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await client.json(host: "ce.us-east-1.amazonaws.com", signingName: "ce", signingRegion: "us-east-1",
                              target: "AWSInsightsIndexService.\(op)", body: body)
    }

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    struct MonthCosts {
        var current = 0.0
        var last = 0.0
        var forecast = 0.0
        var currency = "USD"
        var daily: [DailyCost] = []
        var services: [ServiceCost] = []
    }

    /// Costs for the month containing `month` (daily breakdown, previous month total, service split, forecast).
    func monthCosts(_ month: Date) async throws -> MonthCosts {
        let cal = Self.utc
        let today = cal.startOfDay(for: Date())
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let next = cal.date(byAdding: .month, value: 1, to: first)!
        let prev = cal.date(byAdding: .month, value: -1, to: first)!
        let isCurrent = cal.isDate(first, equalTo: today, toGranularity: .month)
        // Cost Explorer requires End > Start; on the 1st of the month use tomorrow.
        let rawEnd = isCurrent ? today : next
        let end = rawEnd > first ? rawEnd : cal.date(byAdding: .day, value: 1, to: first)!

        @Sendable func period(_ s: Date, _ e: Date) -> [String: String] { ["Start": AWSDate.day(s), "End": AWSDate.day(e)] }

        async let dailyResp = call("GetCostAndUsage", [
            "TimePeriod": period(first, end), "Granularity": "DAILY", "Metrics": ["BlendedCost"]])
        async let prevResp = call("GetCostAndUsage", [
            "TimePeriod": period(prev, first), "Granularity": "MONTHLY", "Metrics": ["BlendedCost"]])
        async let svcResp = call("GetCostAndUsage", [
            "TimePeriod": period(first, end), "Granularity": "MONTHLY", "Metrics": ["BlendedCost"],
            "GroupBy": [["Type": "DIMENSION", "Key": "SERVICE"]]])

        var r = MonthCosts()
        for row in try await dailyResp.array("ResultsByTime") {
            let metric = row.dict("Total").dict("BlendedCost")
            let amount = metric.number("Amount")
            if !metric.string("Unit").isEmpty { r.currency = metric.string("Unit") }
            r.current += amount
            if let d = AWSDate.parseDay(row.dict("TimePeriod").string("Start")) {
                r.daily.append(DailyCost(date: d, amount: amount))
            }
        }
        r.last = try await prevResp.array("ResultsByTime").first?.dict("Total").dict("BlendedCost").number("Amount") ?? 0
        r.services = try await svcResp.array("ResultsByTime").first?.array("Groups").compactMap { g in
            let amount = g.dict("Metrics").dict("BlendedCost").number("Amount")
            guard amount > 0.001 else { return nil }
            return ServiceCost(serviceName: g.strings("Keys").first ?? "Other", amount: amount)
        }.sorted { $0.amount > $1.amount } ?? []

        r.forecast = r.current
        let lastDay = cal.date(byAdding: .day, value: -1, to: next)!
        if isCurrent && today < lastDay {
            let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
            if let f = try? await call("GetCostForecast", [
                "TimePeriod": period(tomorrow, next), "Metric": "BLENDED_COST", "Granularity": "MONTHLY"]) {
                // Forecast covers the remainder of the month; add what has been spent so far.
                r.forecast = r.current + f.dict("Total").number("Amount")
            }
        }
        return r
    }

    /// Monthly cost per dimension for the period (inclusive), top 7 + "Others".
    func breakdown(start: Date, end: Date, groupBy: String) async throws -> BillingReport {
        let cal = Self.utc
        let ceEnd = cal.date(byAdding: .day, value: 1, to: end)!
        let resp = try await call("GetCostAndUsage", [
            "TimePeriod": ["Start": AWSDate.day(start), "End": AWSDate.day(ceEnd)],
            "Granularity": "MONTHLY", "Metrics": ["BlendedCost"],
            "GroupBy": [["Type": "DIMENSION", "Key": groupBy]]])

        let labelFormatter = DateFormatter()
        labelFormatter.locale = Locale(identifier: "en_US_POSIX")
        labelFormatter.timeZone = TimeZone(identifier: "UTC")
        labelFormatter.dateFormat = "MMM yyyy"

        var entries: [MonthlyServiceCost] = []
        var months: [(Date, String)] = []
        var totals: [String: Double] = [:]
        var currency = "USD"

        for row in resp.array("ResultsByTime") {
            guard let month = AWSDate.parseDay(row.dict("TimePeriod").string("Start")) else { continue }
            let label = labelFormatter.string(from: month)
            months.append((month, label))
            for g in row.array("Groups") {
                let key = g.strings("Keys").first ?? ""
                let svc = key.trimmingCharacters(in: .whitespaces).isEmpty ? "Untagged" : key
                let metric = g.dict("Metrics").dict("BlendedCost")
                let amount = metric.number("Amount")
                if !metric.string("Unit").isEmpty { currency = metric.string("Unit") }
                guard amount >= 0.001 else { continue }
                entries.append(MonthlyServiceCost(month: month, monthLabel: label, service: svc, amount: amount))
                totals[svc, default: 0] += amount
            }
        }

        let top = totals.sorted { $0.value > $1.value }.prefix(7).map(\.key)
        let topSet = Set(top)
        var final: [MonthlyServiceCost] = []
        var hasOthers = false
        for (month, label) in months {
            let rows = entries.filter { $0.monthLabel == label }
            final += rows.filter { topSet.contains($0.service) }
            let others = rows.filter { !topSet.contains($0.service) }.reduce(0) { $0 + $1.amount }
            if others > 0.001 {
                final.append(MonthlyServiceCost(month: month, monthLabel: label, service: "Others", amount: others))
                hasOthers = true
            }
        }

        return BillingReport(monthLabels: months.map(\.1), topServices: top + (hasOthers ? ["Others"] : []),
                             entries: final, grandTotal: totals.values.reduce(0, +), currency: currency)
    }
}

/// GuardDuty (REST-JSON).
struct GuardDutyService {
    let client: AWSClient

    private var host: String { "guardduty.\(client.region).amazonaws.com" }

    func findings() async throws -> [GuardDutyFinding] {
        let detectors = try await client.restJSON(method: "GET", host: host, signingName: "guardduty", path: "/detector")
        guard let detectorId = detectors.strings("detectorIds").first else { return [] }

        var ids: [String] = []
        var token: String?
        repeat {
            var body: [String: Any] = [
                "maxResults": 50,
                "findingCriteria": ["criterion": ["service.archived": ["eq": ["false"]]]],
                "sortCriteria": ["attributeName": "severity", "orderBy": "DESC"],
            ]
            if let token { body["nextToken"] = token }
            let resp = try await client.restJSON(method: "POST", host: host, signingName: "guardduty",
                                                 path: "/detector/\(detectorId)/findings", body: body)
            ids += resp.strings("findingIds")
            let next = resp.string("nextToken")
            token = next.isEmpty ? nil : next
        } while token != nil

        var findings: [GuardDutyFinding] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            let resp = try await client.restJSON(method: "POST", host: host, signingName: "guardduty",
                                                 path: "/detector/\(detectorId)/findings/get",
                                                 body: ["findingIds": batch])
            for f in resp.array("findings") {
                let resourceType = f.dict("resource").string("resourceType")
                findings.append(GuardDutyFinding(
                    id: f.string("id"), title: f.string("title"), description: f.string("description"),
                    severity: f.number("severity"), type: f.string("type"),
                    resourceType: resourceType.isEmpty ? "Unknown" : resourceType,
                    region: client.region, accountId: f.string("accountId"),
                    updatedAt: AWSDate.parse(f.string("updatedAt"))))
            }
        }
        return findings.sorted { ($1.severity, $0.title) < ($0.severity, $1.title) }
    }
}
