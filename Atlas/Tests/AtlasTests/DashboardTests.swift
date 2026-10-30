import Foundation
import Testing
@testable import Atlas

private func json(_ body: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
}

private func utc(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    return f.date(from: s)!
}

private func costRow(_ start: String, _ amount: Double) -> String {
    #"{"TimePeriod":{"Start":"\#(start)"},"Total":{"UnblendedCost":{"Amount":"\#(amount)","Unit":"USD"}}}"#
}

/// Dashboard services against fixture responses (in the serialized ServiceTests suite: the mock is shared).
extension ServiceTests {
    /// Answers Cost Explorer: two days this month, 100 last month, services over two pages, forecast 50.
    private func costClient() -> AWSClient {
        MockURLProtocol.client { req, body in
            let b = json(body)
            if req.value(forHTTPHeaderField: "x-amz-target")?.hasSuffix("GetCostForecast") == true {
                return .init(body: #"{"Total":{"Amount":"50","Unit":"USD"}}"#)
            }
            if b["GroupBy"] != nil {
                let group = { (name: String, amount: Double) in
                    #"{"Keys":["\#(name)"],"Metrics":{"UnblendedCost":{"Amount":"\#(amount)","Unit":"USD"}}}"#
                }
                if b["NextPageToken"] == nil {
                    return .init(body: #"{"ResultsByTime":[{"Groups":[\#(group("EC2", 10)),\#(group("S3", 3))]}],"NextPageToken":"p2"}"#)
                }
                return .init(body: #"{"ResultsByTime":[{"Groups":[\#(group("EC2", 5)),\#(group("Tax", 0.001))]}]}"#)
            }
            if b["Granularity"] as? String == "DAILY" {
                return .init(body: #"{"ResultsByTime":[\#(costRow("2026-08-01", 7)),\#(costRow("2026-08-02", 11))]}"#)
            }
            return .init(body: #"{"ResultsByTime":[\#(costRow("2026-07-01", 100))]}"#)
        }
    }

    private func periods(_ granularity: String) -> [[String: String]] {
        MockURLProtocol.requests.map { json($0.body) }
            .filter { $0["Granularity"] as? String == granularity && $0["NextPageToken"] == nil }
            .compactMap { $0["TimePeriod"] as? [String: String] }
    }

    @Test func dashboardCostsAskForTheMonthPickedWhateverTheTimeZone() async throws {
        // August picked in Lisbon used to be 31 July 23:00 UTC, so Cost Explorer was asked for July.
        var lisbon = Calendar(identifier: .gregorian)
        lisbon.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let august = CostMonth.containing(lisbon.date(from: DateComponents(year: 2026, month: 8, day: 1))!, calendar: lisbon)
        #expect(august == CostMonth(year: 2026, month: 8))

        let c = try await CostService(client: costClient()).monthCosts(august, now: utc("2026-10-30T10:00:00Z"))
        #expect(periods("DAILY") == [["Start": "2026-08-01", "End": "2026-09-01"]])
        #expect(periods("MONTHLY").contains(["Start": "2026-07-01", "End": "2026-08-01"]))
        #expect(!c.isCurrent)
        #expect(c.forecast == nil, "a month that ended has no forecast")
        #expect(c.current == 18 && c.last == 100)
        #expect(!MockURLProtocol.requests.contains { $0.request.value(forHTTPHeaderField: "x-amz-target")?.hasSuffix("GetCostForecast") == true })
    }

    @Test func dashboardCurrentMonthCountsTodayAndForecastsTheRest() async throws {
        let c = try await CostService(client: costClient()).monthCosts(CostMonth(year: 2026, month: 10),
                                                                        now: utc("2026-10-30T10:00:00Z"))
        // End is exclusive: the 31st, so today's cost so far counts; the forecast starts tomorrow.
        #expect(periods("DAILY") == [["Start": "2026-10-01", "End": "2026-10-31"]])
        let forecast = try #require(MockURLProtocol.requests.map { json($0.body) }.first { $0["Metric"] != nil })
        #expect(forecast["TimePeriod"] as? [String: String] == ["Start": "2026-10-31", "End": "2026-11-01"])
        #expect(forecast["Metric"] as? String == "UNBLENDED_COST")
        #expect(c.isCurrent && c.forecast == 18 + 50)
        #expect(MockURLProtocol.requests.map { json($0.body) }.allSatisfy {
            ($0["Metrics"] as? [String]).map { $0 == ["UnblendedCost"] } ?? true
        }, "the Billing console's unblended cost")
    }

    @Test func dashboardLastDayOfTheMonthNeedsNoForecast() async throws {
        let c = try await CostService(client: costClient()).monthCosts(CostMonth(year: 2026, month: 10),
                                                                        now: utc("2026-10-31T22:00:00Z"))
        #expect(periods("DAILY") == [["Start": "2026-10-01", "End": "2026-11-01"]])
        #expect(c.forecast == c.current)
        #expect(MockURLProtocol.requests.allSatisfy { json($0.body)["Metric"] == nil })
    }

    @Test func dashboardServicesAddUpAcrossPages() async throws {
        let c = try await CostService(client: costClient()).monthCosts(CostMonth(year: 2026, month: 8),
                                                                        now: utc("2026-10-30T10:00:00Z"))
        #expect(c.services == [ServiceCost(serviceName: "EC2", amount: 15), ServiceCost(serviceName: "S3", amount: 3)],
                "the second page used to be dropped; amounts under a cent are left out")
        #expect(c.daily.map(\.amount) == [7, 11])
        #expect(c.daily.first?.date == Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 1)),
                "a Cost Explorer day is that day in the Mac's time zone")
    }

    @Test func dashboardAMonthNotStartedHasNoCostsAndAsksNothing() async throws {
        let c = try await CostService(client: costClient()).monthCosts(CostMonth(year: 2026, month: 12),
                                                                        now: utc("2026-10-30T10:00:00Z"))
        #expect(c.current == 0 && MockURLProtocol.requests.isEmpty)
    }

    @Test func activeAlarmsCountEveryPageAndCompositeAlarms() async throws {
        let client = MockURLProtocol.client { _, body in
            let p = formParams(body)
            #expect(p["StateValue"] == "ALARM")
            #expect(p["AlarmTypes.member.2"] == "CompositeAlarm")
            let metric = (1...100).map { "<member><AlarmName>m\($0)</AlarmName></member>" }.joined()
            if p["NextToken"] == nil {
                return .init(body: "<DescribeAlarmsResponse><DescribeAlarmsResult><MetricAlarms>\(metric)</MetricAlarms><NextToken>t2</NextToken></DescribeAlarmsResult></DescribeAlarmsResponse>")
            }
            return .init(body: "<DescribeAlarmsResponse><DescribeAlarmsResult><MetricAlarms><member><AlarmName>x</AlarmName></member></MetricAlarms><CompositeAlarms><member><AlarmName>c</AlarmName></member></CompositeAlarms></DescribeAlarmsResult></DescribeAlarmsResponse>")
        }
        #expect(try await CloudWatchService(client: client).activeAlarmCount() == 102, "used to stop at 100 metric alarms")
    }

    @Test func dashboardLoadsOnlyTheSourcesShownAndAFailureIsNotAZero() async throws {
        let client = MockURLProtocol.client(region: "eu-west-1") { req, _ in
            if req.url?.host?.hasPrefix("ec2.") == true {
                return .init(body: """
                <DescribeInstancesResponse><reservationSet><item><instancesSet>
                <item><instanceId>i-1</instanceId><instanceState><name>running</name></instanceState></item>
                <item><instanceId>i-2</instanceId><instanceState><name>stopped</name></instanceState></item>
                <item><instanceId>i-3</instanceId><instanceState><name>terminated</name></instanceState></item>
                <item><instanceId>i-4</instanceId><instanceState><name>pending</name></instanceState></item>
                </instancesSet></item></reservationSet></DescribeInstancesResponse>
                """)
            }
            return .init(status: 403, body: "<ErrorResponse><Error><Code>AccessDenied</Code><Message>not allowed</Message></Error></ErrorResponse>")
        }
        let s = await DashboardService(client: client).resources([.ec2, .alarms])
        #expect(s.instances == InstanceCounts(running: 1, stopped: 1, changing: 1))
        #expect(s.instances?.total == 3, "terminated instances are not counted")
        #expect(s.activeAlarms == nil, "a failed source has no value, not 0")
        #expect(s.errors[.alarms]?.isEmpty == false)
        #expect(s.bucketCount == nil && s.identity == nil && s.errors[.s3] == nil)
        #expect(MockURLProtocol.requests.allSatisfy { ["ec2.eu-west-1.amazonaws.com", "monitoring.eu-west-1.amazonaws.com"].contains($0.request.url?.host ?? "") },
                "hidden cards ask AWS nothing")
        #expect(s.region == "eu-west-1")
    }
}

@MainActor
struct DashboardLayoutTests {
    private func folder() -> URL { TestTemp.root.appendingPathComponent("dashboard-\(UUID().uuidString)", isDirectory: true) }

    @Test func theDefaultShowsEveryCardButTheAccount() {
        let l = DashboardLayout.standard
        #expect(l.order == DashboardCard.allCases)
        #expect(l.visible == [.spend, .instances, .buckets, .alarms, .dailyCost, .topServices])
        #expect(l.sources == [.costs, .ec2, .s3, .alarms])
    }

    @Test func cardsCanBeHiddenShownAndReordered() {
        var l = DashboardLayout.standard
        l.setVisible(.spend, false)
        l.setVisible(.account, true)
        #expect(!l.isVisible(.spend) && l.isVisible(.account))
        #expect(l.sources.contains(.costs) && l.sources.contains(.identity), "daily cost still needs Cost Explorer")
        l.move(fromOffsets: IndexSet(integer: 6), toOffset: 0)
        #expect(l.order.first == .topServices)
        l.move(fromOffsets: IndexSet([0, 1]), toOffset: 7)
        #expect(l.order.suffix(2) == [.topServices, .spend])
        #expect(Set(l.order) == Set(DashboardCard.allCases) && l.order.count == DashboardCard.allCases.count)
    }

    @Test func movingOneStepSkipsHiddenCards() {
        var l = DashboardLayout(order: [.spend, .account, .instances], hidden: [.account])
        l.move(.instances, by: -1)
        #expect(l.visible.prefix(2) == [.instances, .spend])
        l.move(.instances, by: -1)
        #expect(l.visible.first == .instances, "the first card stays first")
    }

    @Test func aSavedLayoutKeepsItsOrderAndPicksUpNewCards() throws {
        let saved = Data(#"{"order":["alarms","gone","spend"],"hidden":["spend","gone"]}"#.utf8)
        let l = try JSONDecoder().decode(DashboardLayout.self, from: saved)
        #expect(l.order.prefix(2) == [.alarms, .spend])
        #expect(l.order.count == DashboardCard.allCases.count, "cards added since are appended")
        #expect(l.hidden == [.spend])
        #expect(try JSONDecoder().decode(DashboardLayout.self, from: JSONEncoder().encode(l)) == l)
    }

    @Test func theLayoutPersistsInAtlasFolder() {
        let dir = folder()
        let store = DashboardLayoutStore(folder: dir)
        #expect(store.layout == .standard, "the default when nothing is saved")
        store.layout.setVisible(.buckets, false)
        store.layout.move(.alarms, by: -1)
        let reopened = DashboardLayoutStore(folder: dir)
        #expect(reopened.layout == store.layout)
        reopened.reset()
        #expect(DashboardLayoutStore(folder: dir).layout == .standard)

        try? Data("not json".utf8).write(to: dir.appendingPathComponent("dashboard.json"))
        #expect(DashboardLayoutStore(folder: dir).layout == .standard, "a damaged file falls back to the default")
    }

    @Test func rowsGroupTilesAndHalvesAndColumnsFitTheWidth() {
        let rows = DashboardLayout.standard.rows
        #expect(rows.map(\.cards) == [[.spend], [.instances, .buckets, .alarms], [.dailyCost, .topServices]])
        let split = DashboardLayout(order: [.instances, .spend, .buckets], hidden: []).rows
        #expect(split.map(\.cards).prefix(3) == [[.instances], [.spend], [.buckets, .alarms, .account]],
                "a wide card splits the tiles around it")

        #expect(DashboardLayout.columns(.tile, count: 3, width: 1000) == 3)
        #expect(DashboardLayout.columns(.tile, count: 3, width: 360) == 2)
        #expect(DashboardLayout.columns(.tile, count: 3, width: 100) == 1)
        #expect(DashboardLayout.columns(.half, count: 2, width: 900) == 2)
        #expect(DashboardLayout.columns(.half, count: 2, width: 600) == 1)
        #expect(DashboardLayout.columns(.wide, count: 1, width: 2000) == 1)
        #expect(DashboardLayout.columns(.tile, count: 4, width: 0) == 1)
    }

    @Test func costMonthsWrapAcrossYears() {
        let jan = CostMonth(year: 2026, month: 1)
        #expect(jan.adding(-1) == CostMonth(year: 2025, month: 12))
        #expect(CostMonth(year: 2026, month: 13) == CostMonth(year: 2027, month: 1))
        #expect(jan.id == "2026-01")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let recent = CostMonth.recent(3, now: utc("2026-02-10T00:00:00Z"), calendar: cal)
        #expect(recent == [CostMonth(year: 2026, month: 2), jan, CostMonth(year: 2025, month: 12)])
        #expect(recent.contains(CostMonth.containing(utc("2026-02-28T12:00:00Z"), calendar: cal)),
                "the picker's selection is one of its months")
    }

    @Test func instanceDetailNamesTheRegion() {
        #expect(DashboardBody.instanceDetail(InstanceCounts(running: 2, stopped: 1), region: "eu-west-1") == "1 stopped · 3 in eu-west-1")
        #expect(DashboardBody.instanceDetail(InstanceCounts(running: 0, stopped: 0, changing: 2), region: "us-east-1")
                .contains("2 starting or stopping"))
    }

    @Test func globalCacheEntriesAreSharedByEveryRegion() async throws {
        let state = AppState(store: AccountStore(folder: folder()), secrets: InMemorySecretStore())
        try state.addAccount(name: "Prod", accessKeyId: "AKIAPROD", secret: "s", region: "eu-west-1")
        var fetches = 0
        func load() async throws { try await state.cached("costs", regional: false, show: { (_: Int) in }) { fetches += 1; return fetches } }
        try await load()
        state.region = "us-east-1"
        try await load()
        #expect(fetches == 1, "Cost Explorer is billed per request and the same in every region")
    }
}
