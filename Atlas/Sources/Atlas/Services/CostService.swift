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
        /// Spent so far plus Cost Explorer's forecast for the rest of the month; nil for a month that has ended.
        var forecast: Double?
        var currency = "USD"
        var daily: [DailyCost] = []
        var services: [ServiceCost] = []
        /// Whether the month is still going on: the total is month to date.
        var isCurrent = false
    }

    /// Unblended cost, as the AWS Billing console shows it.
    static let metric = "UnblendedCost"

    /// Costs of `month` (daily breakdown, previous month total, service split, forecast). Cost Explorer counts
    /// days in UTC, and its End is exclusive: the current month runs until tomorrow, so today's cost so far counts.
    func monthCosts(_ month: CostMonth, now: Date = Date()) async throws -> MonthCosts {
        let cal = Self.utc
        let today = cal.startOfDay(for: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        let first = month.start(in: cal)
        let next = month.adding(1).start(in: cal)
        let prev = month.adding(-1).start(in: cal)
        let isCurrent = first <= today && today < next
        let end = isCurrent ? tomorrow : next
        let metric = Self.metric

        @Sendable func period(_ s: Date, _ e: Date) -> [String: String] { ["Start": AWSDate.day(s), "End": AWSDate.day(e)] }

        var r = MonthCosts(isCurrent: isCurrent)
        guard first <= today else { return r } // a month that hasn't started has no costs yet

        async let dailyRows = pages(["TimePeriod": period(first, end), "Granularity": "DAILY", "Metrics": [metric]])
        async let prevRows = pages(["TimePeriod": period(prev, first), "Granularity": "MONTHLY", "Metrics": [metric]])
        async let svcRows = pages([
            "TimePeriod": period(first, end), "Granularity": "MONTHLY", "Metrics": [metric],
            "GroupBy": [["Type": "DIMENSION", "Key": "SERVICE"]]])

        var days: [Date: Double] = [:]
        for row in try await dailyRows {
            let m = row.dict("Total").dict(metric)
            if !m.string("Unit").isEmpty { r.currency = m.string("Unit") }
            r.current += m.number("Amount")
            if let d = Self.localDay(row.dict("TimePeriod").string("Start")) { days[d, default: 0] += m.number("Amount") }
        }
        r.daily = days.map { DailyCost(date: $0.key, amount: $0.value) }.sorted { $0.date < $1.date }
        r.last = try await prevRows.reduce(0) { $0 + $1.dict("Total").dict(metric).number("Amount") }

        // A page can hold part of the groups; add each service up across pages.
        var services: [String: Double] = [:]
        for row in try await svcRows {
            for g in row.array("Groups") {
                services[g.strings("Keys").first ?? "Other", default: 0] += g.dict("Metrics").dict(metric).number("Amount")
            }
        }
        r.services = services.filter { $0.value >= 0.005 }
            .map { ServiceCost(serviceName: $0.key, amount: $0.value) }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.serviceName < $1.serviceName }

        if isCurrent {
            r.forecast = r.current
            if tomorrow < next, let f = try? await call("GetCostForecast", [
                "TimePeriod": period(tomorrow, next), "Metric": "UNBLENDED_COST", "Granularity": "MONTHLY"]) {
                // A MONTHLY forecast is the whole month's (its period starts on the 1st), spent so far included:
                // adding it to the spend counted the month twice. It never ends below what was spent.
                r.forecast = max(r.current, f.dict("Total").number("Amount"))
            }
        }
        return r
    }

    /// Every ResultsByTime row, following NextPageToken.
    private func pages(_ body: [String: Any]) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var token: String?
        repeat {
            var b = body
            if let token { b["NextPageToken"] = token }
            let resp = try await call("GetCostAndUsage", b)
            rows += resp.array("ResultsByTime")
            token = resp["NextPageToken"] as? String
        } while token?.isEmpty == false
        return rows
    }

    /// A Cost Explorer day ("2026-10-05") at local midnight, so charts put it on that day in any time zone.
    static func localDay(_ s: String, calendar: Calendar = .current) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
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
