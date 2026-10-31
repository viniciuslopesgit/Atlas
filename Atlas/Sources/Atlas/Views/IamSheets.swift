import SwiftUI

/// Create user wizard (name, console access, permissions, tags, optional access key) — as in Atlas 1.0.1.
struct CreateUserSheet: View {
    let service: IamService
    let users: [String]
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var o = CreateUserOptions()
    @State private var groups: [IamGroup] = []
    @State private var policies: [AttachablePolicy] = []
    @State private var policySearch = ""
    @State private var tags: [TagRow] = []
    @State private var isCreating = false
    @State private var error: String?
    @State private var created: CreatedUser?

    private var nameIsValid: Bool { o.userName.range(of: #"^[\w+=,.@-]{1,64}$"#, options: .regularExpression) != nil }
    private var canCreate: Bool {
        nameIsValid && !isCreating && (!o.consoleAccess || o.password.count >= 8)
            && (o.permissions != .copy || !o.copyFromUser.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(created == nil ? "Create user" : "User created").font(Typo.panelTitle).padding(20)
            Divider()
            if let created { result(created) } else { form }
            Divider()
            HStack {
                if let error { Text(error).foregroundStyle(Palette.danger).font(.callout).lineLimit(3) }
                Spacer()
                if created == nil {
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(isCreating ? "Creating…" : "Create User") { Task { await create() } }
                        .keyboardShortcut(.defaultAction).disabled(!canCreate)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .task {
            async let g = try? service.groups()
            async let p = try? service.attachablePolicies()
            groups = await g ?? []
            policies = await p ?? []
        }
    }

    private var form: some View {
        Form {
            Section("User") {
                TextField("User name", text: $o.userName)
                if !o.userName.isEmpty && !nameIsValid {
                    Text("Up to 64 letters, digits and + = , . @ _ -").font(.caption).foregroundStyle(Palette.danger)
                }
                TextField("Path", text: $o.path)
            }
            Section("Console access") {
                Toggle("Allow sign-in to the AWS console", isOn: $o.consoleAccess)
                if o.consoleAccess {
                    SecureField("Password (at least 8 characters)", text: $o.password)
                    Toggle("Require a new password at first sign-in", isOn: $o.requirePasswordReset)
                }
            }
            Section("Permissions") {
                Picker("Permissions", selection: $o.permissions) {
                    ForEach(CreateUserOptions.Permissions.allCases) { Text($0.rawValue).tag($0) }
                }
                switch o.permissions {
                case .none: EmptyView()
                case .groups:
                    if groups.isEmpty { Text("No groups in this account").foregroundStyle(.secondary) }
                    ForEach(groups) { g in Toggle(g.groupName, isOn: member(g.groupName, in: \.groupNames)) }
                case .copy:
                    Picker("Copy from", selection: $o.copyFromUser) {
                        Text("Choose a user").tag("")
                        ForEach(users, id: \.self) { Text($0).tag($0) }
                    }
                case .policies:
                    TextField("Filter policies", text: $policySearch)
                    let shown = policies.filter { policySearch.isEmpty || $0.name.localizedCaseInsensitiveContains(policySearch) }
                    ForEach(shown.prefix(60)) { p in
                        Toggle(isOn: member(p.arn, in: \.policyArns)) {
                            Text(p.name) + Text(p.isAWSManaged ? "  AWS managed" : "  Customer managed").foregroundColor(.secondary)
                        }
                    }
                    if shown.count > 60 { Text("\(shown.count - 60) more — refine the filter").foregroundStyle(.secondary) }
                }
            }
            Section("Tags") {
                TagRowsEditor(rows: $tags)
            }
            Section {
                Toggle("Create an access key for programmatic access", isOn: $o.createAccessKey)
            }
        }
        .groupedForm()
    }

    private func result(_ c: CreatedUser) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(c.userName) is ready.", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.success)
            if let key = c.accessKey {
                Text("Save the secret now: AWS shows it only once.").foregroundStyle(.secondary)
                DetailRow("Access key ID", key.id, copyable: true)
                DetailRow("Secret access key", key.secret, copyable: true, secret: true)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func member(_ value: String, in path: WritableKeyPath<CreateUserOptions, [String]>) -> Binding<Bool> {
        Binding(get: { o[keyPath: path].contains(value) },
                set: { on in if on { o[keyPath: path].append(value) } else { o[keyPath: path].removeAll { $0 == value } } })
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        o.tags = tags.cleaned
        do {
            created = try await service.createUser(o)
            error = nil
            onCreated()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Picks managed policies to attach, filtered by name.
struct AttachPolicySheet: View {
    let service: IamService
    let attached: Set<String>
    let onAttach: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var policies: [AttachablePolicy]?
    @State private var chosen: Set<String> = []
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Attach policies").font(Typo.panelTitle)
            TextField("Filter by name", text: $search).textFieldStyle(.roundedBorder)
            if let policies {
                let shown = policies.filter { !attached.contains($0.arn)
                    && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
                List(shown, selection: $chosen) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Text(p.isAWSManaged ? "AWS managed" : "Customer managed").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text(chosen.isEmpty ? "Select one or more policies" : "\(chosen.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Attach") { onAttach(Array(chosen)); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .task { policies = (try? await service.attachablePolicies()) ?? [] }
    }
}

/// Edits a list of key/value tags.
struct TagEditorSheet: View {
    let onSave: ([(key: String, value: String)]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [TagRow]

    init(tags: [(key: String, value: String)], onSave: @escaping ([(key: String, value: String)]) -> Void) {
        self.onSave = onSave
        _rows = State(initialValue: tags.map { TagRow(key: $0.key, value: $0.value) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags").font(Typo.panelTitle)
            ScrollView { TagRowsEditor(rows: $rows) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Tags") { onSave(rows.cleaned); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }
}

struct TagRow: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""
}

extension [TagRow] {
    /// Rows with a key, trimmed, last value winning for duplicate keys.
    var cleaned: [(key: String, value: String)] {
        var seen: [String: String] = [:]
        var order: [String] = []
        for r in self {
            let k = r.key.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { continue }
            if seen[k] == nil { order.append(k) }
            seen[k] = r.value.trimmingCharacters(in: .whitespaces)
        }
        return order.map { (key: $0, value: seen[$0]!) }
    }
}

struct TagRowsEditor: View {
    @Binding var rows: [TagRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                HStack {
                    TextField("Key", text: $row.key)
                    TextField("Value", text: $row.value)
                    Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button { rows.append(TagRow()) } label: { Label("Add Tag", systemImage: "plus") }
                .buttonStyle(.borderless)
        }
    }
}
