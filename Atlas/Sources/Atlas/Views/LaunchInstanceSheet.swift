import SwiftUI
import AppKit

struct LaunchInstanceSheet: View {
    let service: Ec2Service
    let onLaunched: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var o = LaunchInstanceOptions()
    @State private var vpcs: [VpcInfo] = []
    @State private var subnets: [SubnetInfo] = []
    @State private var keyPairs: [KeyPairSummary] = []
    @State private var securityGroups: [SecurityGroupSummary] = []
    @State private var isLaunching = false
    @State private var error: String?
    @State private var newKeyName = ""
    @State private var showNewKey = false

    private let instanceTypes = ["t3.nano", "t3.micro", "t3.small", "t3.medium", "t3.large",
                                 "t4g.micro", "t4g.small", "t4g.medium",
                                 "m6i.large", "m6i.xlarge", "m7g.large", "c6i.large", "c7g.large", "r6i.large"]

    private let commonAmis: [(String, String)] = [
        ("Amazon Linux 2023 (x86_64)", "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"),
        ("Amazon Linux 2023 (arm64)", "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"),
        ("Ubuntu 24.04 LTS (x86_64)", "resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"),
        ("Ubuntu 24.04 LTS (arm64)", "resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("Launch Instance").font(Typo.panelTitle).padding()
            Divider()
            Form {
                Section("Name and image") {
                    TextField("Name", text: $o.name)
                    Picker("Quick AMI", selection: $o.amiId) {
                        Text("Custom…").tag("")
                        ForEach(commonAmis, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    TextField("AMI ID", text: $o.amiId, prompt: Text("ami-0123456789abcdef0"))
                        .font(.body.monospaced())
                }
                Section("Instance") {
                    Picker("Instance type", selection: $o.instanceType) {
                        ForEach(instanceTypes, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Count: \(o.count)", value: $o.count, in: 1...20)
                    HStack {
                        Picker("Key pair", selection: $o.keyPairName) {
                            Text("None (proceed without a key pair)").tag("")
                            ForEach(keyPairs) { Text("\($0.keyName) (\($0.keyType))").tag($0.keyName) }
                        }
                        Button("New…") { showNewKey = true }
                    }
                }
                Section("Network") {
                    Picker("VPC", selection: $o.vpcId) {
                        Text("Default").tag("")
                        ForEach(vpcs) { Text($0.display).tag($0.vpcId) }
                    }
                    Picker("Subnet", selection: $o.subnetId) {
                        Text("No preference").tag("")
                        ForEach(subnets) { Text($0.display).tag($0.subnetId) }
                    }
                    Toggle("Auto-assign public IP", isOn: $o.autoAssignPublicIp)
                    Picker("Security group", selection: $o.createNewSecurityGroup) {
                        Text("Create new").tag(true)
                        Text("Select existing").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if o.createNewSecurityGroup {
                        TextField("Group name", text: $o.newSecurityGroupName, prompt: Text("launch-wizard-…"))
                        Toggle("Allow SSH (22) from anywhere", isOn: $o.allowSsh)
                        Toggle("Allow HTTPS (443) from anywhere", isOn: $o.allowHttps)
                        Toggle("Allow HTTP (80) from anywhere", isOn: $o.allowHttp)
                    } else {
                        Picker("Existing group", selection: $o.existingSecurityGroupId) {
                            Text("—").tag("")
                            ForEach(securityGroups) { Text("\($0.groupName) (\($0.groupId))").tag($0.groupId) }
                        }
                    }
                }
                Section("Storage") {
                    Stepper("Root volume: \(o.rootVolumeSize) GiB", value: $o.rootVolumeSize, in: 8...16384)
                    Picker("Volume type", selection: $o.rootVolumeType) {
                        ForEach(["gp3", "gp2", "io1", "io2", "st1", "sc1", "standard"], id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Advanced") {
                    TextField("IAM instance profile (name or ARN)", text: $o.iamInstanceProfile)
                    Toggle("Require IMDSv2", isOn: $o.imdsv2Required)
                    Toggle("Detailed monitoring", isOn: $o.detailedMonitoring)
                    Toggle("Termination protection", isOn: $o.terminationProtection)
                    Picker("Shutdown behavior", selection: $o.shutdownBehavior) {
                        Text("Stop").tag("stop")
                        Text("Terminate").tag("terminate")
                    }
                    VStack(alignment: .leading) {
                        Text("User data").font(.callout)
                        TextEditor(text: $o.userData).font(.body.monospaced()).frame(height: 80)
                    }
                }
            }
            .formStyle(.grouped)

            if let error { ErrorBanner(message: error).padding(.horizontal) }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await launch() }
                } label: {
                    if isLaunching { ProgressView().controlSize(.small) } else { Text("Launch") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(o.amiId.trimmingCharacters(in: .whitespaces).isEmpty || isLaunching)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 620, height: 760)
        .task { await loadDiscovery() }
        .onChange(of: o.vpcId) {
            o.subnetId = ""
            o.existingSecurityGroupId = ""
            Task { await loadNetwork() }
        }
        .alert("Create key pair", isPresented: $showNewKey) {
            TextField("Key pair name", text: $newKeyName)
            Button("Create & Save .pem") { Task { await createKeyPair() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The private key is shown only once — you will be asked where to save it.")
        }
    }

    private func loadDiscovery() async {
        async let v = try? service.vpcs()
        async let k = try? service.keyPairs()
        vpcs = await v ?? []
        keyPairs = await k ?? []
        await loadNetwork()
    }

    private func loadNetwork() async {
        let vpc = o.vpcId.isEmpty ? nil : o.vpcId
        async let s = try? service.subnets(vpcId: vpc)
        async let g = try? service.securityGroups(vpcId: vpc)
        subnets = await s ?? []
        securityGroups = await g ?? []
    }

    private func createKeyPair() async {
        let name = newKeyName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            let pem = try await service.createKeyPair(name: name, type: "rsa")
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(name).pem"
            if panel.runModal() == .OK, let url = panel.url {
                try PrivateFile.write(Data(pem.utf8), to: url, permissions: 0o400)
            }
            keyPairs = (try? await service.keyPairs()) ?? keyPairs
            o.keyPairName = name
        } catch {
            self.error = "Key pair creation failed: \(error.localizedDescription)"
        }
    }

    private func launch() async {
        isLaunching = true
        error = nil
        defer { isLaunching = false }
        do {
            let ids = try await service.launch(o)
            onLaunched(ids)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
