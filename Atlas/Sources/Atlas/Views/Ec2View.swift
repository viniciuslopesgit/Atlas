import SwiftUI
import Charts

struct Ec2View: View {
    @EnvironmentObject private var state: AppState
    @State private var instances: [Ec2Instance] = []
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var statusFilter = "all"
    @State private var isLoading = false
    @State private var error: String?
    @State private var pendingAction: InstanceAction?
    @State private var showLaunch = false
    @State private var sortOrder = [KeyPathComparator(\Ec2Instance.name)]

    enum InstanceAction: String, Identifiable {
        case start, stop, reboot, terminate
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var isDanger: Bool { self == .terminate }
    }

    private var filtered: [Ec2Instance] {
        let q = search.lowercased()
        return instances
            .filter { statusFilter == "all" || $0.state == statusFilter }
            .filter { q.isEmpty || [$0.name, $0.instanceId, $0.publicIpAddress, $0.privateIpAddress, $0.instanceType]
                .contains { $0.lowercased().contains(q) } }
            .sorted(using: sortOrder)
    }

    private var selectedInstances: [Ec2Instance] { instances.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "EC2 Instances", subtitle: "\(filtered.count) of \(instances.count) instances · \(state.region)") {
                Button { exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                Button { showLaunch = true } label: { Label("Launch Instance", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }

            HStack {
                TextField("Search by name, ID, IP or type", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Picker("Status", selection: $statusFilter) {
                    ForEach(["all", "running", "stopped", "pending", "stopping", "terminated"], id: \.self) {
                        Text($0.capitalized).tag($0)
                    }
                }
                .frame(width: 180)
                Spacer()
            }

            if let error { ErrorBanner(message: error) { self.error = nil } }

            table

            if !selection.isEmpty { actionBar }
        }
        .padding(24)
        .inspector(isPresented: .constant(selection.count == 1)) {
            if let instance = selectedInstances.first {
                InstanceDetail(instance: instance).inspectorColumnWidth(min: 340, ideal: 400, max: 520)
            }
        }
        .task(id: state.sessionKey) { await load() }
        .confirmationDialog(pendingAction.map { "\($0.title) \(selection.count) instance(s)?" } ?? "",
                            isPresented: Binding(present: $pendingAction), presenting: pendingAction) { action in
            Button(action.title, role: action.isDanger ? .destructive : nil) { Task { await perform(action) } }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            let names = selectedInstances.map { "\($0.name) (\($0.instanceId))" }.joined(separator: "\n")
            Text(action.isDanger
                 ? "Terminating is permanent and cannot be undone. All instance-store data will be lost.\n\n\(names)"
                 : names)
        }
        .sheet(isPresented: $showLaunch) {
            if let client = state.client {
                LaunchInstanceSheet(service: Ec2Service(client: client)) { ids in
                    Task { await load() }
                    _ = ids
                }
            }
        }
    }

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("State", value: \.state) { i in Badge(text: i.state, color: Palette.ec2State(i.state)) }
                .width(min: 90, ideal: 100)
            TableColumn("Name", value: \.name)
                .width(min: 140, ideal: 200)
            TableColumn("Instance ID", value: \.instanceId) { i in Text(i.instanceId).font(.body.monospaced()) }
                .width(min: 150, ideal: 180)
            TableColumn("Type", value: \.instanceType)
                .width(min: 80, ideal: 100)
            TableColumn("Public IP", value: \.publicIpAddress)
                .width(min: 100, ideal: 120)
            TableColumn("Private IP", value: \.privateIpAddress)
                .width(min: 100, ideal: 120)
            TableColumn("AZ", value: \.availabilityZone)
                .width(min: 90, ideal: 110)
            TableColumn("Launch Time") { i in Text(Fmt.dt(i.launchTime)) }
                .width(min: 130, ideal: 160)
        }
        .overlay {
            if isLoading && instances.isEmpty { ProgressView() }
            else if !isLoading && instances.isEmpty && error == nil {
                EmptyStateView(icon: "server.rack", title: "No instances", message: "No EC2 instances in \(state.region).")
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected").font(.callout.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
            Spacer()
            Button { pendingAction = .start } label: { Label("Start", systemImage: "play.fill") }
            Button { pendingAction = .stop } label: { Label("Stop", systemImage: "stop.fill") }
            Button { pendingAction = .reboot } label: { Label("Reboot", systemImage: "arrow.clockwise") }
            Button(role: .destructive) { pendingAction = .terminate } label: { Label("Terminate", systemImage: "trash") }
            Button("Clear") { selection.removeAll() }
        }
        .padding(10)
        .card()
    }

    private func load() async {
        guard let client = state.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            instances = try await Ec2Service(client: client).instances()
            selection = selection.filter { id in instances.contains { $0.id == id } }
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func perform(_ action: InstanceAction) async {
        guard let client = state.client else { return }
        let svc = Ec2Service(client: client)
        let ids = Array(selection)
        do {
            switch action {
            case .start: try await svc.start(ids)
            case .stop: try await svc.stop(ids)
            case .reboot: try await svc.reboot(ids)
            case .terminate: try await svc.terminate(ids)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await load()
        } catch {
            self.error = "\(action.title) failed: \(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        CSVExport.save(name: "ec2-instances-\(state.region).csv",
                       header: ["Name", "InstanceId", "State", "Type", "PublicIP", "PrivateIP", "AZ", "LaunchTime"],
                       rows: filtered.map { [$0.name, $0.instanceId, $0.state, $0.instanceType, $0.publicIpAddress,
                                             $0.privateIpAddress, $0.availabilityZone, Fmt.dt($0.launchTime)] })
    }
}

// MARK: - Detail inspector

private struct InstanceDetail: View {
    @EnvironmentObject private var state: AppState
    let instance: Ec2Instance
    @State private var metrics: Ec2InstanceMetrics?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(instance.name).font(.title3.weight(.semibold))
                    Spacer()
                    Badge(text: instance.state, color: Palette.ec2State(instance.state))
                }

                SectionHeader("Metrics (last hour)")
                metricCharts

                SectionHeader("Instance summary")
                DetailRow("Instance ID", instance.instanceId, copyable: true)
                DetailRow("Instance type", instance.instanceType)
                DetailRow("vCPUs", "\(instance.vCpuCount)")
                DetailRow("Public IPv4", instance.publicIpAddress, copyable: true)
                DetailRow("Private IPv4", instance.privateIpAddress, copyable: true)
                DetailRow("IPv6", instance.ipv6Address)
                DetailRow("Region", instance.region)
                DetailRow("Public DNS", instance.publicDnsName, copyable: true)
                DetailRow("Private DNS", instance.privateDnsName)
                DetailRow("VPC ID", instance.vpcId, copyable: true)
                DetailRow("Subnet ID", instance.subnetId, copyable: true)
                DetailRow("IAM role", instance.iamInstanceProfileName).help(instance.iamInstanceProfileArn)
                DetailRow("Auto Scaling Group", instance.autoScalingGroupName)
                DetailRow("IMDSv2", instance.metadataHttpTokens)
                DetailRow("Owner", instance.ownerId)
                DetailRow("Instance ARN", instance.instanceArn, copyable: true)

                SectionHeader("Instance details")
                DetailRow("AMI ID", instance.imageId, copyable: true)
                DetailRow("Monitoring", instance.monitoringState)
                DetailRow("Platform", instance.platformDetails)
                DetailRow("Key pair", instance.keyName)
                DetailRow("Launch time", Fmt.dt(instance.launchTime))
                DetailRow("Virtualization", instance.virtualizationType)
                DetailRow("Lifecycle", instance.lifecycle)
                DetailRow("Usage operation", instance.usageOperation)
                DetailRow("Boot mode", instance.bootMode)
                DetailRow("Current boot mode", instance.currentInstanceBootMode)
                DetailRow("AMI launch index", "\(instance.amiLaunchIndex)")
                DetailRow("State transition", instance.stateTransitionReason)
                DetailRow("State reason", instance.stateReasonMessage)
                DetailRow("Hibernation", instance.hibernationEnabled ? "enabled" : "disabled")

                SectionHeader("Host and placement")
                DetailRow("Availability zone", instance.availabilityZone)
                DetailRow("Tenancy", instance.tenancy)
                DetailRow("Host ID", instance.hostId)
                DetailRow("Affinity", instance.affinity)
                DetailRow("Placement group", instance.placementGroup)
                DetailRow("Placement group ID", instance.placementGroupId)
                DetailRow("Partition number", instance.partitionNumber.map(String.init) ?? "—")
                DetailRow("Reservation ID", instance.reservationId)

                SectionHeader("Capacity reservation")
                DetailRow("Reservation ID", instance.capacityReservationId)
                DetailRow("Preference", instance.capacityReservationPreference)

                if !instance.tags.isEmpty {
                    SectionHeader("Tags")
                    ForEach(instance.tags.sorted { $0.key < $1.key }, id: \.key) { DetailRow($0.key, $0.value) }
                }
            }
            .padding(16)
        }
        .task(id: instance.id) {
            metrics = nil
            guard let client = state.client, instance.state == "running" else { return }
            metrics = try? await Ec2Service(client: client).metrics(instanceId: instance.instanceId)
        }
    }

    @ViewBuilder
    private var metricCharts: some View {
        if instance.state != "running" {
            Text("Metrics are available for running instances.").font(.callout).foregroundStyle(.secondary)
        } else if let m = metrics {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    MiniChart(title: "CPU %", points: m.cpu, format: { String(format: "%.1f%%", $0) })
                    MiniChart(title: "Disk write", points: m.diskWrite, format: { ByteFormat.string(Int64($0)) })
                }
                GridRow {
                    MiniChart(title: "Network in", points: m.networkIn, format: { ByteFormat.string(Int64($0)) })
                    MiniChart(title: "Network out", points: m.networkOut, format: { ByteFormat.string(Int64($0)) })
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

private struct MiniChart: View {
    let title: String
    let points: [MetricPoint]
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(points.last.map { format($0.value) } ?? "—").font(.caption.monospacedDigit())
            }
            Chart(points) { p in
                AreaMark(x: .value("t", p.timestamp), y: .value("v", p.value))
                    .foregroundStyle(Color.accentColor.opacity(0.2).gradient)
                LineMark(x: .value("t", p.timestamp), y: .value("v", p.value))
                    .foregroundStyle(Color.accentColor)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 50)
        }
        .padding(8)
        .card()
    }
}
