import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("theme") private var theme: AppTheme = .system

    @State private var name = ""
    @State private var accessKeyId = ""
    @State private var secret = ""
    @State private var region = "us-east-1"
    @State private var isValidating = false
    @State private var feedback: (ok: Bool, text: String)?
    @State private var pendingRemoval: AwsAccount?

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !accessKeyId.trimmingCharacters(in: .whitespaces).isEmpty
            && !secret.isEmpty && !isValidating
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Accounts", subtitle: "Credentials are verified with STS and stored in the macOS Keychain.")

                HStack(alignment: .top, spacing: 20) {
                    addForm.frame(maxWidth: 420)
                    accountList.frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Appearance")
                    Picker("Theme", selection: $theme) {
                        ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
                .padding(16)
                .card()

                UpdateStatusView()
            }
            .padding(24)
        }
        .confirmationDialog("Remove account?", isPresented: Binding(present: $pendingRemoval), presenting: pendingRemoval) { account in
            Button("Remove \(account.name)", role: .destructive) {
                state.removeAccount(account.id)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { account in
            Text("The access key \(account.accessKeyId) will be deleted from the Keychain.")
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Add AWS account")
            Form {
                TextField("Account name", text: $name, prompt: Text("e.g. Production"))
                TextField("Access Key ID", text: $accessKeyId, prompt: Text("AKIA…"))
                    .font(.body.monospaced())
                SecureField("Secret Access Key", text: $secret)
                Picker("Default region", selection: $region) {
                    ForEach(RegionItem.all) { Text("\($0.code) — \($0.display)").tag($0.code) }
                }
            }
            .formStyle(.columns)

            HStack {
                Button {
                    Task { await add() }
                } label: {
                    if isValidating { ProgressView().controlSize(.small) } else { Text("Validate & Add Account") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }

            if let feedback {
                Label(feedback.text, systemImage: feedback.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(feedback.ok ? Palette.success : Palette.danger)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .card()
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Configured accounts (\(state.accounts.count))")
            if state.accounts.isEmpty {
                Text("No accounts yet.").foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(state.accounts) { account in
                HStack(spacing: 12) {
                    Initials(name: account.name)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(account.name).font(.body.weight(.medium))
                            if account.isActive { Badge(text: "Active", color: Palette.success) }
                        }
                        Text("\(account.accessKeyId) · \(account.defaultRegion)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !account.isActive {
                        Button("Set Active") { state.setActive(account.id) }
                    }
                    Button(role: .destructive) { pendingRemoval = account } label: { Image(systemName: "trash") }
                        .help("Remove account")
                }
                .padding(.vertical, 6)
            }
        }
        .padding(16)
        .card()
    }

    private func add() async {
        isValidating = true
        feedback = nil
        defer { isValidating = false }
        let key = accessKeyId.trimmingCharacters(in: .whitespaces)
        do {
            let identity = try await AppState.validate(accessKeyId: key, secret: secret, region: region)
            try state.addAccount(name: name.trimmingCharacters(in: .whitespaces), accessKeyId: key, secret: secret, region: region)
            feedback = (true, "Account added — \(identity.arn)")
            name = ""; accessKeyId = ""; secret = ""
        } catch {
            feedback = (false, "Validation failed: \(error.localizedDescription)")
        }
    }
}

/// Installed version and the state written by the updater LaunchAgent (scripts/install-updater.sh).
private struct UpdateStatusView: View {
    /// Read when the view appears: a `@State` initial value is evaluated again on every parent render,
    /// and this one reads and decodes a file.
    @State private var status = Updater.Status()
    @State private var isInstalled = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Atlas \(AppInfo.version) (build \(AppInfo.build))").textSelection(.enabled)
                Text(status.description).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            if isInstalled {
                Button("Check for Updates Now") {
                    Updater.checkNow()
                    Task {
                        try? await Task.sleep(for: .seconds(8))
                        status = Updater.status()
                    }
                }
                .controlSize(.small)
            }
        }
        .task {
            isInstalled = Updater.isInstalled
            status = Updater.status()
        }
    }
}
