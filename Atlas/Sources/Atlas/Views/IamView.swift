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
    @State private var selectedUsers: Set<String> = []
    @State private var selectedRoles: Set<String> = []
    @State private var selectedGroups: Set<String> = []
    @State private var selectedPolicys: Set<String> = []
    @State private var search = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var showCreateUser = false
    @State private var pendingDelete: Set<String>?
    @State private var isDeleting = false

    private func matches(_ s: String) -> Bool { search.isEmpty || s.localizedCaseInsensitiveContains(search) }

    private var selection: Set<String> {
        switch tab {
        case .users: selectedUsers
        case .roles: selectedRoles
        case .groups: selectedGroups
        case .policies: selectedPolicys
        }
    }

    private var hasSelection: Bool { selection.count == 1 }

    /// Singular noun for the current tab, for buttons and confirmations.
    private var noun: String {
        switch tab {
        case .users: "user"
        case .roles: "role"
        case .groups: "group"
        case .policies: "policy"
        }
    }

    private func label(_ id: String) -> String {
        tab == .policies ? (policies.first { $0.arn == id }?.policyName ?? id) : id
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
            HStack {
                TextField("Search \(tab.rawValue.lowercased())", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                Spacer()
                if !selection.isEmpty {
                    Button(role: .destructive) { pendingDelete = selection } label: {
                        Label(selection.count == 1 ? "Delete \(noun)" : "Delete \(selection.count) \(tab.rawValue.lowercased())",
                              systemImage: "trash")
                    }
                    .disabled(isDeleting)
                }
                if tab == .users {
                    Button { showCreateUser = true } label: { Label("Create User…", systemImage: "person.badge.plus") }
                        .buttonStyle(.borderedProminent)
                }
            }
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
        .sheet(isPresented: $showCreateUser) {
            if let client = state.client {
                CreateUserSheet(service: IamService(client: client), users: users.map(\.userName)) { Task { await load() } }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(present: $pendingDelete), presenting: pendingDelete) { ids in
            Button("Delete", role: .destructive) { Task { await delete(ids) } }
        } message: { ids in
            Text(ids.map(label).sorted().joined(separator: "\n")
                 + "\n\nAttached policies, group memberships, keys and other dependencies are removed first. This cannot be undone.")
        }
    }

    private var deleteTitle: String {
        let n = pendingDelete?.count ?? 0
        return n == 1 ? "Delete this \(noun)?" : "Delete \(n) \(tab.rawValue.lowercased())?"
    }

    private func delete(_ ids: Set<String>) async {
        guard let client = state.client else { return }
        let svc = IamService(client: client)
        let tab = tab
        isDeleting = true
        defer { isDeleting = false }
        var failures: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for id in ids {
                group.addTask {
                    do {
                        switch tab {
                        case .users: try await svc.deleteUser(id)
                        case .roles: try await svc.deleteRole(id)
                        case .groups: try await svc.deleteGroup(id)
                        case .policies: try await svc.deletePolicy(id)
                        }
                        return nil
                    } catch {
                        return "\(id): \(error.localizedDescription)"
                    }
                }
            }
            for await f in group { if let f { failures.append(f) } }
        }
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        selectedUsers = []; selectedRoles = []; selectedGroups = []; selectedPolicys = []
        await load()
    }

    private var usersTable: some View {
        Table(users.filter { matches($0.userName) }, selection: $selectedUsers) {
            TableColumn("User name", value: \.userName)
            TableColumn("Path", value: \.path).width(80)
            TableColumn("Created") { Text(Fmt.day($0.createDate)) }.width(120)
            TableColumn("Console last used") { Text($0.passwordLastUsed.map { Fmt.dt($0) } ?? "Never") }.width(160)
        }
    }

    private var rolesTable: some View {
        Table(roles.filter { matches($0.roleName) }, selection: $selectedRoles) {
            TableColumn("Role name", value: \.roleName)
            TableColumn("Trusted entities", value: \.trustedEntities)
            TableColumn("Created") { Text(Fmt.day($0.createDate)) }.width(120)
        }
    }

    private var groupsTable: some View {
        Table(groups.filter { matches($0.groupName) }, selection: $selectedGroups) {
            TableColumn("Group name", value: \.groupName)
            TableColumn("Path", value: \.path).width(100)
            TableColumn("Created") { Text(Fmt.day($0.createDate)) }.width(120)
        }
    }

    private var policiesTable: some View {
        Table(policies.filter { matches($0.policyName) }, selection: $selectedPolicys) {
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
                if let u = users.first(where: { selectedUsers == [$0.id] }) {
                    UserDetail(user: u, service: service, allGroups: groups) { Task { await loadGroupsIfNeeded() } }
                }
            case .roles:
                if let r = roles.first(where: { [$0.id] == selectedRoles }) { RoleDetail(role: r, service: service) }
            case .groups:
                if let g = groups.first(where: { selectedGroups == [$0.id] }) { GroupDetail(group: g, service: service) }
            case .policies:
                if let p = policies.first(where: { selectedPolicys == [$0.id] }) { PolicyDetail(policy: p, service: service) }
            }
        }
    }

    private func loadGroupsIfNeeded() async {
        guard groups.isEmpty, let client = state.client else { return }
        groups = (try? await IamService(client: client).groups()) ?? []
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
    let allGroups: [IamGroup]
    let needGroups: () -> Void
    @State private var detail: IamUserDetail?
    @State private var showAttach = false
    @State private var showTags = false
    @State private var newKey: (id: String, secret: String)?
    @State private var pendingKeyDelete: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(user.userName).font(Typo.panelTitle)
                DetailRow("ARN", user.arn, copyable: true)
                DetailRow("User ID", user.userId, copyable: true)
                DetailRow("Path", user.path)
                DetailRow("Created", Fmt.dt(user.createDate))
                DetailRow("Console last used", user.passwordLastUsed.map { Fmt.dt($0) } ?? "Never")

                if let error { ErrorBanner(message: error) { self.error = nil } }

                if let d = detail {
                    HStack {
                        SectionHeader("Groups (\(d.groups.count))")
                        Spacer()
                        Menu("Add to Group") {
                            let available = allGroups.map(\.groupName).filter { !d.groups.contains($0) }
                            if available.isEmpty { Text("No other groups") }
                            ForEach(available, id: \.self) { g in
                                Button(g) { Task { await run { try await service.addUserToGroup(user.userName, g) } } }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                        .onAppear(perform: needGroups)
                    }
                    removableList(d.groups) { g in try await service.removeUserFromGroup(user.userName, g) }

                    HStack {
                        SectionHeader("Attached policies (\(d.attachedPolicies.count))")
                        Spacer()
                        Button("Attach Policy…") { showAttach = true }.controlSize(.small)
                    }
                    removableList(d.attachedPolicies.map(\.name)) { name in
                        if let arn = d.attachedPolicies.first(where: { $0.name == name })?.arn {
                            try await service.detachUserPolicy(user.userName, arn)
                        }
                    }
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

                    HStack {
                        SectionHeader("Tags (\(d.tags.count))")
                        Spacer()
                        Button("Edit Tags…") { showTags = true }.controlSize(.small)
                    }
                    if d.tags.isEmpty { Text("None").foregroundStyle(.secondary).font(.callout) }
                    ForEach(d.tags, id: \.key) { DetailRow($0.key, $0.value) }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .task(id: user.id) { detail = nil; detail = await service.userDetail(user.userName) }
        .sheet(isPresented: $showAttach) {
            AttachPolicySheet(service: service, attached: Set(detail?.attachedPolicies.map(\.arn) ?? [])) { arns in
                Task { await run { for arn in arns { try await service.attachUserPolicy(user.userName, arn) } } }
            }
        }
        .sheet(isPresented: $showTags) {
            TagEditorSheet(tags: detail?.tags ?? []) { new in
                let old = detail?.tags.map(\.key) ?? []
                Task { await run { try await service.setUserTags(user.userName, old: old, new: new) } }
            }
        }
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

    /// A list where each row has a remove button that runs `remove` and reloads the detail.
    private func removableList(_ items: [String], remove: @escaping (String) async throws -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if items.isEmpty { Text("None").foregroundStyle(.secondary).font(.callout) }
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { Task { await run { try await remove(item) } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
                }
            }
        }
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
                Text(role.roleName).font(Typo.panelTitle)
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
                Text(group.groupName).font(Typo.panelTitle)
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
                Text(policy.policyName).font(Typo.panelTitle)
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
