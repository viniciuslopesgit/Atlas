import SwiftUI

struct IamView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case users = "Users", roles = "Roles", groups = "Groups", policies = "Policies"
        var id: String { rawValue }
    }

    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .users
    @State private var users: [IamUser] = []
    @State private var roles: [IamRole] = []
    @State private var groups: [IamGroup] = []
    @State private var policies: [IamPolicy] = []
    @State private var selectedUser: String?
    @State private var selectedRole: String?
    @State private var selectedGroup: String?
    @State private var selectedPolicy: String?
    @State private var search = ""
    @State private var isLoading = false
    @State private var error: String?

    private func matches(_ s: String) -> Bool { search.isEmpty || s.localizedCaseInsensitiveContains(search) }

    private var hasSelection: Bool {
        switch tab {
        case .users: selectedUser != nil
        case .roles: selectedRole != nil
        case .groups: selectedGroup != nil
        case .policies: selectedPolicy != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "IAM", subtitle: "Global identity and access management") {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)
            }
            TextField("Search \(tab.rawValue.lowercased())", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            if let error { ErrorBanner(message: error) { self.error = nil } }

            Group {
                switch tab {
                case .users: usersTable
                case .roles: rolesTable
                case .groups: groupsTable
                case .policies: policiesTable
                }
            }
            .overlay { if isLoading { ProgressView() } }
        }
        .padding(24)
        .inspector(isPresented: .constant(hasSelection)) { inspector.inspectorColumnWidth(min: 320, ideal: 380, max: 520) }
        .task(id: "\(state.sessionKey)|\(tab)") { await load() }
    }

    private var usersTable: some View {
        Table(users.filter { matches($0.userName) }, selection: $selectedUser) {
            TableColumn("User name", value: \.userName)
            TableColumn("Path", value: \.path).width(80)
            TableColumn("Created") { Text(Fmt.day($0.createDate)) }.width(120)
            TableColumn("Console last used") { Text($0.passwordLastUsed.map { Fmt.dt($0) } ?? "Never") }.width(160)
        }
    }

    private var rolesTable: some View {
        Table(roles.filter { matches($0.roleName) }, selection: $selectedRole) {
            TableColumn("Role name", value: \.roleName)
            TableColumn("Trusted entities", value: \.trustedEntities)
            TableColumn("Created") { Text(Fmt.day($0.createDate)) }.width(120)
        }
    }

    private var groupsTable: some View {
        Table(groups.filter { matches($0.groupName) }, selection: $selectedGroup) {
            TableColumn("Group name", value: \.groupName)
            TableColumn("Path", value: \.path).width(100)
            TableColumn("Created") { Text(Fmt.day($0.createDate)) }.width(120)
        }
    }

    private var policiesTable: some View {
        Table(policies.filter { matches($0.policyName) }, selection: $selectedPolicy) {
            TableColumn("Policy name", value: \.policyName)
            TableColumn("Attachments") { Text("\($0.attachmentCount)") }.width(90)
            TableColumn("Description", value: \.description)
            TableColumn("Updated") { Text(Fmt.day($0.updateDate)) }.width(120)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let client = state.client {
            let service = IamService(client: client)
            switch tab {
            case .users:
                if let u = users.first(where: { $0.id == selectedUser }) { UserDetail(user: u, service: service) }
            case .roles:
                if let r = roles.first(where: { $0.id == selectedRole }) { RoleDetail(role: r, service: service) }
            case .groups:
                if let g = groups.first(where: { $0.id == selectedGroup }) { GroupDetail(group: g, service: service) }
            case .policies:
                if let p = policies.first(where: { $0.id == selectedPolicy }) { PolicyDetail(policy: p, service: service) }
            }
        }
    }

    private func load() async {
        guard let client = state.client else { return }
        let svc = IamService(client: client)
        isLoading = true
        defer { isLoading = false }
        do {
            switch tab {
            case .users: users = try await svc.users()
            case .roles: roles = try await svc.roles()
            case .groups: groups = try await svc.groups()
            case .policies: policies = try await svc.policies()
            }
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Inspectors

private struct UserDetail: View {
    let user: IamUser
    let service: IamService
    @State private var detail: IamUserDetail?
    @State private var newKey: (id: String, secret: String)?
    @State private var pendingKeyDelete: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(user.userName).font(.title3.weight(.semibold))
                DetailRow("ARN", user.arn, copyable: true)
                DetailRow("User ID", user.userId, copyable: true)
                DetailRow("Path", user.path)
                DetailRow("Created", Fmt.dt(user.createDate))
                DetailRow("Console last used", user.passwordLastUsed.map { Fmt.dt($0) } ?? "Never")

                if let error { ErrorBanner(message: error) { self.error = nil } }

                if let d = detail {
                    SectionHeader("Groups (\(d.groups.count))")
                    list(d.groups)
                    SectionHeader("Attached policies (\(d.attachedPolicies.count))")
                    list(d.attachedPolicies.map(\.name))
                    SectionHeader("Inline policies (\(d.inlinePolicies.count))")
                    list(d.inlinePolicies)

                    HStack {
                        SectionHeader("Access keys (\(d.accessKeys.count)/2)")
                        Spacer()
                        Button("Create Key") { Task { await createKey() } }
                            .disabled(d.accessKeys.count >= 2)
                            .controlSize(.small)
                    }
                    ForEach(d.accessKeys) { key in accessKeyRow(key) }

                    if !d.tags.isEmpty {
                        SectionHeader("Tags")
                        ForEach(d.tags, id: \.key) { DetailRow($0.key, $0.value) }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .task(id: user.id) { detail = nil; detail = await service.userDetail(user.userName) }
        .alert("Access key created", isPresented: Binding(present: Binding(
            get: { newKey.map { $0.id } }, set: { if $0 == nil { newKey = nil } }))) {
            Button("Copy Secret") { copy(newKey?.secret ?? "") }
            Button("Done", role: .cancel) {}
        } message: {
            Text("Access key ID: \(newKey?.id ?? "")\nSecret: \(newKey?.secret ?? "")\n\nThe secret is shown only once.")
        }
        .confirmationDialog("Delete access key \(pendingKeyDelete ?? "")?", isPresented: Binding(present: $pendingKeyDelete),
                            presenting: pendingKeyDelete) { id in
            Button("Delete Key", role: .destructive) { Task { await run { try await service.deleteAccessKey(user.userName, id) } } }
        }
    }

    private func accessKeyRow(_ key: AccessKeyInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.accessKeyId).font(.callout.monospaced()).textSelection(.enabled)
                Spacer()
                Badge(text: key.status, color: key.isActive ? Palette.success : .secondary)
            }
            Text("Created \(Fmt.day(key.createDate)) · last used \(key.lastUsedDate.map { Fmt.day($0) } ?? "never")"
                 + (key.lastUsedService.isEmpty || key.lastUsedService == "N/A" ? "" : " (\(key.lastUsedService))"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(key.isActive ? "Deactivate" : "Activate") {
                    Task { await run { try await service.setAccessKey(user.userName, key.accessKeyId, active: !key.isActive) } }
                }
                Button("Delete", role: .destructive) { pendingKeyDelete = key.accessKeyId }
            }
            .controlSize(.small)
        }
        .padding(8)
        .card()
    }

    private func list(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if items.isEmpty { Text("None").foregroundStyle(.secondary).font(.callout) }
            ForEach(items, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func createKey() async {
        do { newKey = try await service.createAccessKey(user.userName) } catch { self.error = error.localizedDescription }
        detail = await service.userDetail(user.userName)
    }

    private func run(_ op: () async throws -> Void) async {
        do { try await op() } catch { self.error = error.localizedDescription }
        detail = await service.userDetail(user.userName)
    }
}

private struct RoleDetail: View {
    let role: IamRole
    let service: IamService
    @State private var detail: IamEntityDetail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(role.roleName).font(.title3.weight(.semibold))
                DetailRow("ARN", role.arn, copyable: true)
                DetailRow("Role ID", role.roleId)
                DetailRow("Description", role.description)
                DetailRow("Path", role.path)
                DetailRow("Created", Fmt.dt(role.createDate))
                DetailRow("Max session", role.maxSessionDisplay)
                DetailRow("Trusted entities", role.trustedEntities)
                EntityPolicies(detail: detail)
            }
            .padding(16)
        }
        .task(id: role.id) { detail = nil; detail = await service.roleDetail(role.roleName) }
    }
}

private struct GroupDetail: View {
    let group: IamGroup
    let service: IamService
    @State private var detail: IamEntityDetail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(group.groupName).font(.title3.weight(.semibold))
                DetailRow("ARN", group.arn, copyable: true)
                DetailRow("Group ID", group.groupId)
                DetailRow("Path", group.path)
                DetailRow("Created", Fmt.dt(group.createDate))
                if let d = detail {
                    SectionHeader("Members (\(d.members.count))")
                    ForEach(d.members, id: \.self) { Text($0).font(.callout) }
                }
                EntityPolicies(detail: detail)
            }
            .padding(16)
        }
        .task(id: group.id) { detail = nil; detail = await service.groupDetail(group.groupName) }
    }
}

private struct EntityPolicies: View {
    let detail: IamEntityDetail?
    var body: some View {
        if let d = detail {
            SectionHeader("Attached policies (\(d.attachedPolicies.count))")
            ForEach(d.attachedPolicies, id: \.self) { Text($0).font(.callout) }
            SectionHeader("Inline policies (\(d.inlinePolicies.count))")
            ForEach(d.inlinePolicies, id: \.self) { Text($0).font(.callout) }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

private struct PolicyDetail: View {
    let policy: IamPolicy
    let service: IamService
    @State private var document: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(policy.policyName).font(.title3.weight(.semibold))
                DetailRow("ARN", policy.arn, copyable: true)
                DetailRow("Description", policy.description)
                DetailRow("Attachments", "\(policy.attachmentCount)")
                DetailRow("Default version", policy.defaultVersionId)
                DetailRow("Created", Fmt.dt(policy.createDate))
                DetailRow("Updated", Fmt.dt(policy.updateDate))
                HStack {
                    SectionHeader("Policy document")
                    Spacer()
                    if let document { CopyButton(value: document) }
                }
                if let document {
                    Text(document).font(.caption.monospaced()).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).card()
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .task(id: policy.id) {
            document = nil
            document = (try? await service.policyDocument(arn: policy.arn, versionId: policy.defaultVersionId))
                ?? "Could not load document."
        }
    }
}
