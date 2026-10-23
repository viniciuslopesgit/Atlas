import SwiftUI

/// Views and changes one bucket's configuration. Every change is described and confirmed before it reaches S3.
struct S3BucketSettingsSheet: View {
    let service: S3Service
    let bucket: String

    @Environment(\.dismiss) private var dismiss
    /// As S3 has it, and as edited here.
    @State private var saved: S3BucketSettings?
    @State private var draft = S3BucketSettings()
    @State private var pending: PendingChange?
    @State private var isApplying = false
    @State private var error: String?
    @State private var newTag = S3BucketSettings.Tag(key: "", value: "")
    @State private var newRule = RuleDraft()

    struct PendingChange: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        var destructive = false
        var section = ""
        let apply: () async throws -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bucket Settings").font(Typo.panelTitle)
                    Text(bucket).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if isApplying { ProgressView().controlSize(.small) }
            }
            .padding()
            Divider()
            if saved == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    versioningSection
                    encryptionSection
                    publicAccessSection
                    tagsSection
                    lifecycleSection
                    policySection
                }
                .formStyle(.grouped)
                .disabled(isApplying)
            }
            if let error { ErrorBanner(message: error) { self.error = nil }.padding(.horizontal) }
            Divider()
            HStack {
                Text("Changes are sent to S3 only after you confirm them.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 640, height: 720)
        .task { await reload() }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(present: $pending), presenting: pending) { change in
            Button("Apply", role: change.destructive ? .destructive : nil) { Task { await apply(change) } }
            Button("Cancel", role: .cancel) {}
        } message: { change in
            Text(change.message)
        }
    }

    // MARK: Sections

    private var versioningSection: some View {
        Section {
            Picker("Versioning", selection: $draft.versioning) {
                ForEach(S3BucketSettings.Versioning.allCases.filter { $0 != .off || saved?.versioning == .off }) {
                    Text($0.rawValue).tag($0)
                }
            }
            if draft.mfaDelete { DetailRow("MFA delete", "Enabled") }
            footer("versioning", changed: draft.versioning != saved?.versioning && draft.versioning != .off) {
                PendingChange(title: "Change versioning of \(bucket)?",
                              message: "Versioning: \(saved?.versioning.rawValue ?? "") → \(draft.versioning.rawValue)."
                                  + (draft.versioning == .suspended ? " New objects will overwrite older versions; existing versions are kept." : "")
                                  + " Once enabled, versioning can only be suspended, never turned off.",
                              destructive: draft.versioning == .suspended) { [draft] in
                    try await service.setVersioning(bucket, enabled: draft.versioning == .enabled)
                }
            }
        } header: { Text("Versioning") }
    }

    private var encryptionSection: some View {
        Section {
            Picker("Default encryption", selection: $draft.encryption) {
                ForEach(S3BucketSettings.Encryption.allCases) { Text($0.label).tag($0) }
            }
            if draft.encryption != .sseS3 {
                TextField("KMS key ARN or ID (empty = aws/s3)", text: $draft.kmsKeyId).font(.body.monospaced())
            }
            if draft.encryption == .sseKms { Toggle("Bucket key", isOn: $draft.bucketKeyEnabled) }
            footer("encryption", changed: encryptionChanged) {
                PendingChange(title: "Change default encryption of \(bucket)?",
                              message: "New objects will be encrypted with \(draft.encryption.label)"
                                  + (draft.encryption != .sseS3 && !draft.kmsKeyId.isEmpty ? " using \(draft.kmsKeyId)" : "")
                                  + ". Existing objects keep their current encryption.") { [draft] in
                    try await service.setEncryption(bucket, draft.encryption, kmsKeyId: draft.kmsKeyId, bucketKey: draft.bucketKeyEnabled)
                }
            }
        } header: { Text("Default encryption") }
    }

    private var encryptionChanged: Bool {
        guard let saved else { return false }
        return draft.encryption != saved.encryption || draft.kmsKeyId != saved.kmsKeyId || draft.bucketKeyEnabled != saved.bucketKeyEnabled
    }

    private var publicAccessSection: some View {
        Section {
            Toggle("Block public ACLs", isOn: $draft.publicAccess.blockPublicAcls)
            Toggle("Ignore public ACLs", isOn: $draft.publicAccess.ignorePublicAcls)
            Toggle("Block public bucket policies", isOn: $draft.publicAccess.blockPublicPolicy)
            Toggle("Restrict public buckets", isOn: $draft.publicAccess.restrictPublicBuckets)
            footer("publicAccessBlock", changed: draft.publicAccess != saved?.publicAccess) {
                let p = draft.publicAccess
                let off = [("Block public ACLs", p.blockPublicAcls), ("Ignore public ACLs", p.ignorePublicAcls),
                           ("Block public bucket policies", p.blockPublicPolicy), ("Restrict public buckets", p.restrictPublicBuckets)]
                    .filter { !$0.1 }.map(\.0)
                return PendingChange(title: "Change Block Public Access of \(bucket)?",
                                     message: off.isEmpty ? "All public access will be blocked."
                                         : "Turned off: \(off.joined(separator: ", ")). The bucket can then be made public by an ACL or a policy.",
                                     destructive: !off.isEmpty) {
                    try await service.setPublicAccessBlock(bucket, p)
                }
            }
        } header: { Text("Block Public Access") }
    }

    private var tagsSection: some View {
        Section {
            ForEach($draft.tags) { $tag in
                HStack {
                    Text(tag.key).font(.body.monospaced()).frame(width: 180, alignment: .leading)
                    TextField("Value", text: $tag.value).labelsHidden()
                    Button { draft.tags.removeAll { $0.key == tag.key } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Key", text: $newTag.key)
                TextField("Value", text: $newTag.value)
                Button("Add") {
                    draft.tags.append(newTag)
                    newTag = .init(key: "", value: "")
                }
                .disabled(newTag.key.isEmpty || draft.tags.contains { $0.key == newTag.key })
            }
            footer("tagging", changed: draft.tags != saved?.tags) {
                PendingChange(title: "Replace the tags of \(bucket)?",
                              message: draft.tags.isEmpty ? "All tags will be removed."
                                  : "The bucket will have exactly these tags: "
                                  + draft.tags.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + ".",
                              destructive: draft.tags.isEmpty) { [draft] in
                    try await service.setTags(bucket, draft.tags)
                }
            }
        } header: { Text("Tags") }
    }

    private var lifecycleSection: some View {
        Section {
            ForEach($draft.lifecycle) { $rule in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.ruleId).font(.body.monospaced())
                        Text(rule.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if rule.raw == nil { Toggle("Enabled", isOn: $rule.enabled).labelsHidden() }
                    Button { draft.lifecycle.removeAll { $0.ruleId == rule.ruleId } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            DisclosureGroup("Add rule") {
                TextField("Rule ID", text: $newRule.ruleId)
                TextField("Prefix (empty = whole bucket)", text: $newRule.prefix)
                HStack {
                    TextField("Move after (days)", text: $newRule.transitionDays)
                    Picker("to", selection: $newRule.storageClass) {
                        ForEach(RuleDraft.storageClasses, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Expire objects after (days)", text: $newRule.expirationDays)
                TextField("Expire old versions after (days)", text: $newRule.noncurrentDays)
                TextField("Abort incomplete uploads after (days)", text: $newRule.abortDays)
                Button("Add Rule") {
                    if let rule = newRule.rule { draft.lifecycle.append(rule); newRule = RuleDraft() }
                }
                .disabled(newRule.rule == nil || draft.lifecycle.contains { $0.ruleId == newRule.ruleId })
            }
            footer("lifecycle", changed: draft.lifecycle != saved?.lifecycle) {
                PendingChange(title: "Replace the lifecycle rules of \(bucket)?",
                              message: draft.lifecycle.isEmpty ? "All lifecycle rules will be deleted."
                                  : draft.lifecycle.map { "\($0.ruleId) (\($0.enabled ? "enabled" : "disabled")): \($0.summary)" }
                                      .joined(separator: "\n") + "\n\nExpiration rules permanently delete objects.",
                              destructive: true) { [draft] in
                    try await service.setLifecycle(bucket, draft.lifecycle)
                }
            }
        } header: { Text("Lifecycle rules") }
    }

    private var policySection: some View {
        Section {
            TextEditor(text: $draft.policy)
                .font(.body.monospaced())
                .frame(minHeight: 160)
            if !policyIsValid { Text("Not a JSON object.").font(.caption).foregroundStyle(Palette.danger) }
            footer("policy", changed: draft.policy != saved?.policy && policyIsValid) {
                PendingChange(title: draft.policy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  ? "Delete the policy of \(bucket)?" : "Replace the policy of \(bucket)?",
                              message: "Who can access the bucket changes as soon as S3 accepts the policy.",
                              destructive: true) { [draft] in
                    try await service.setPolicy(bucket, draft.policy)
                }
            }
        } header: { Text("Bucket policy") }
    }

    private var policyIsValid: Bool {
        let text = draft.policy.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any]
    }

    /// A section's read error, and Revert / Save when the draft differs from S3.
    private func footer(_ name: String, changed: Bool, change: @escaping () -> PendingChange) -> some View {
        HStack {
            if let message = saved?.errors[name] {
                Text(message).font(.caption).foregroundStyle(Palette.danger).lineLimit(2)
            }
            Spacer()
            if changed {
                Button("Revert") { if let saved { revert(name, from: saved) } }
                Button("Save…") { var c = change(); c.section = name; pending = c }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func revert(_ name: String, from s: S3BucketSettings) {
        switch name {
        case "versioning": draft.versioning = s.versioning
        case "encryption": draft.encryption = s.encryption; draft.kmsKeyId = s.kmsKeyId; draft.bucketKeyEnabled = s.bucketKeyEnabled
        case "publicAccessBlock": draft.publicAccess = s.publicAccess
        case "tagging": draft.tags = s.tags
        case "lifecycle": draft.lifecycle = s.lifecycle
        default: draft.policy = s.policy
        }
    }

    // MARK: Loading

    private func reload(applied: String? = nil) async {
        let s = await service.settings(bucket)
        // Keeps what is being edited in other sections.
        if let old = saved {
            for name in ["versioning", "encryption", "publicAccessBlock", "tagging", "lifecycle", "policy"]
            where name == applied || isUnchanged(name, old) { revert(name, from: s) }
        } else {
            draft = s
        }
        saved = s
    }

    private func isUnchanged(_ name: String, _ s: S3BucketSettings) -> Bool {
        switch name {
        case "versioning": draft.versioning == s.versioning
        case "encryption": draft.encryption == s.encryption && draft.kmsKeyId == s.kmsKeyId && draft.bucketKeyEnabled == s.bucketKeyEnabled
        case "publicAccessBlock": draft.publicAccess == s.publicAccess
        case "tagging": draft.tags == s.tags
        case "lifecycle": draft.lifecycle == s.lifecycle
        default: draft.policy == s.policy
        }
    }

    private func apply(_ change: PendingChange) async {
        isApplying = true
        defer { isApplying = false }
        do {
            try await change.apply()
            error = nil
            // The applied section is read back from S3 itself.
            await reload(applied: change.section)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The "Add rule" form: text fields, a rule only when it does something.
struct RuleDraft: Equatable {
    static let storageClasses = ["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"]

    var ruleId = ""
    var prefix = ""
    var transitionDays = ""
    var storageClass = "STANDARD_IA"
    var expirationDays = ""
    var noncurrentDays = ""
    var abortDays = ""

    var rule: S3BucketSettings.LifecycleRule? {
        let id = ruleId.trimmingCharacters(in: .whitespaces)
        func days(_ s: String) -> Int?? {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return .some(nil) }
            guard let d = Int(t), d > 0 else { return nil }
            return .some(d)
        }
        guard !id.isEmpty, let move = days(transitionDays), let expire = days(expirationDays),
              let old = days(noncurrentDays), let abort = days(abortDays),
              move != nil || expire != nil || old != nil || abort != nil else { return nil }
        return .init(ruleId: id, prefix: prefix, transitions: move.map { [.init(days: $0, storageClass: storageClass)] } ?? [],
                     expirationDays: expire, noncurrentExpirationDays: old, abortMultipartDays: abort)
    }
}
