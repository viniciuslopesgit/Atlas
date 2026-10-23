import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct S3View: View {
    @EnvironmentObject private var state: AppState
    @State private var buckets: [S3Bucket] = []
    @State private var bucketFilter = ""
    @State private var selectedBucket: String?
    @State private var prefix = ""
    @State private var objects: [S3Object] = []
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var isLoadingBuckets = false
    @State private var isLoadingObjects = false
    @State private var error: String?
    @State private var transfer: (label: String, progress: Double)?
    @State private var pendingDelete: [S3Object]?
    @State private var pendingBucketDelete: String?
    @State private var showCreateBucket = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var editing: S3Object?
    @State private var settingsBucket: String?
    @State private var isDropTargeted = false

    private var service: S3Service? { state.client.map { S3Service(client: $0) } }

    private var visibleBuckets: [S3Bucket] {
        bucketFilter.isEmpty ? buckets : buckets.filter { $0.name.localizedCaseInsensitiveContains(bucketFilter) }
    }

    private var visibleObjects: [S3Object] {
        search.isEmpty ? objects : objects.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    private var selectedObjects: [S3Object] { objects.filter { selection.contains($0.id) } }

    var body: some View {
        HSplitView {
            bucketPanel.frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            objectPanel.frame(minWidth: 520)
        }
        .task(id: state.sessionKey) { await loadBuckets() }
        .confirmationDialog("Delete \(pendingDelete?.count ?? 0) item(s)?", isPresented: Binding(present: $pendingDelete),
                            presenting: pendingDelete) { items in
            Button("Delete", role: .destructive) { Task { await delete(items) } }
        } message: { items in
            Text(items.prefix(10).map(\.key).joined(separator: "\n")
                 + (items.contains { $0.isFolder } ? "\n\nFolders are deleted with all their contents." : ""))
        }
        .confirmationDialog("Delete bucket \(pendingBucketDelete ?? "")?", isPresented: Binding(present: $pendingBucketDelete),
                            presenting: pendingBucketDelete) { name in
            Button("Empty and Delete Bucket", role: .destructive) { Task { await deleteBucket(name) } }
        } message: { _ in
            Text("All objects and versions will be permanently deleted. This cannot be undone.")
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { Task { await createFolder() } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showCreateBucket) {
            if let service {
                CreateBucketSheet(service: service, defaultRegion: state.region) { options in
                    Task { await loadBuckets() }
                    Task { if let message = await TerraformAware.record({ [TerraformAware.bucket(options)] }) { state.notice = message } }
                }
            }
        }
        .sheet(isPresented: Binding(present: $settingsBucket)) {
            if let service, let bucket = settingsBucket { S3BucketSettingsSheet(service: service, bucket: bucket) }
        }
        .sheet(item: $editing) { object in
            if let service, let bucket = selectedBucket {
                S3TextEditorSheet(service: service, bucket: bucket, object: object)
            }
        }
    }

    // MARK: Buckets

    private var bucketPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Buckets").font(Typo.panelTitle)
                Text("\(buckets.count)").foregroundStyle(.secondary)
                Spacer()
                Button { showCreateBucket = true } label: { Image(systemName: "plus") }.help("Create bucket")
            }
            TextField("Filter buckets", text: $bucketFilter).textFieldStyle(.roundedBorder)
            List(visibleBuckets, selection: $selectedBucket) { b in
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.name).lineLimit(1)
                    Text([b.region, Fmt.day(b.creationDate)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(b.name)
                .contextMenu {
                    Button("Copy Name") { copy(b.name) }
                    Button("Copy ARN") { copy("arn:aws:s3:::\(b.name)") }
                    Button("Settings…") { settingsBucket = b.name }
                    Divider()
                    Button("Delete Bucket…", role: .destructive) { pendingBucketDelete = b.name }
                }
            }
            .overlay { if isLoadingBuckets && buckets.isEmpty { ProgressView() } }
            Button {
                CSVExport.save(name: "s3-buckets.csv", header: ["Name", "Region", "Created"],
                               rows: buckets.map { [$0.name, $0.region, Fmt.day($0.creationDate)] })
            } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderless)
        }
        .padding(12)
        .onChange(of: selectedBucket) {
            prefix = ""
            Task { await loadObjects() }
        }
    }

    // MARK: Objects

    @ViewBuilder
    private var objectPanel: some View {
        if let bucket = selectedBucket {
            VStack(alignment: .leading, spacing: 10) {
                breadcrumbs(bucket)
                HStack {
                    TextField("Filter in this folder", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    Spacer()
                    Button { settingsBucket = bucket } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                        .help("Versioning, encryption, public access, tags, lifecycle and policy")
                    Button { showNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { pickAndUpload() } label: { Label("Upload", systemImage: "arrow.up.doc") }
                    Button { downloadSelected() } label: { Label("Download", systemImage: "arrow.down.doc") }
                        .disabled(selectedObjects.filter { !$0.isFolder }.isEmpty)
                    Button(role: .destructive) { pendingDelete = selectedObjects } label: { Label("Delete", systemImage: "trash") }
                        .disabled(selection.isEmpty)
                }

                if let error { ErrorBanner(message: error) { self.error = nil } }
                if let transfer {
                    HStack {
                        Text(transfer.label).font(.callout).lineLimit(1)
                        ProgressView(value: transfer.progress)
                        Text("\(Int(transfer.progress * 100))%").font(.callout.monospacedDigit()).frame(width: 44)
                    }
                }

                Table(visibleObjects, selection: $selection) {
                    TableColumn("Name") { o in
                        Label(o.displayName, systemImage: o.isFolder ? "folder.fill" : "doc")
                            .foregroundStyle(o.isFolder ? Palette.accent : .primary)
                    }
                    .width(min: 220, ideal: 320)
                    TableColumn("Type", value: \.fileType).width(min: 80, ideal: 100)
                    TableColumn("Size") { o in Text(o.displaySize).monospacedDigit() }.width(min: 70, ideal: 90)
                    TableColumn("Storage class", value: \.storageClass).width(min: 90, ideal: 120)
                    TableColumn("Last modified") { o in Text(o.isFolder ? "" : Fmt.dt(o.lastModified)) }
                        .width(min: 130, ideal: 160)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let items = objects.filter { ids.contains($0.id) }
                    if items.count == 1, let o = items.first, !o.isFolder {
                        Button("Edit as Text…") { editing = o }.disabled(o.sizeBytes > 2_000_000)
                        Button("Download…") { download(o) }
                    }
                    Button("Copy Key") { copy(items.map(\.key).joined(separator: "\n")) }
                    Button("Copy S3 URI") { copy(items.map { "s3://\(bucket)/\($0.key)" }.joined(separator: "\n")) }
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = items }
                } primaryAction: { ids in
                    guard ids.count == 1, let o = objects.first(where: { ids.contains($0.id) }) else { return }
                    if o.isFolder { open(prefix: o.key) } else { download(o) }
                }
                .overlay {
                    if isLoadingObjects && objects.isEmpty { ProgressView() }
                    else if !isLoadingObjects && objects.isEmpty {
                        EmptyStateView(icon: "tray", title: "Empty folder", message: "Drop files here or use Upload.")
                    }
                }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers)
                    return true
                }
            }
            .padding(16)
        } else {
            EmptyStateView(icon: "archivebox", title: "Select a bucket", message: "Choose a bucket on the left to browse its objects.")
        }
    }

    private func breadcrumbs(_ bucket: String) -> some View {
        let parts = prefix.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            Button { open(prefix: "") } label: { Label(bucket, systemImage: "archivebox.fill") }.buttonStyle(.link)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                Button(part) { open(prefix: parts[0...index].joined(separator: "/") + "/") }.buttonStyle(.link)
            }
            Spacer()
            Text("\(objects.count) items").foregroundStyle(.secondary).font(.callout)
        }
        .font(.callout)
    }

    private func open(prefix newPrefix: String) {
        prefix = newPrefix
        selection.removeAll()
        search = ""
        Task { await loadObjects() }
    }

    // MARK: Loading

    private func loadBuckets() async {
        guard let service else { return }
        isLoadingBuckets = true
        defer { isLoadingBuckets = false }
        do {
            buckets = try await service.buckets()
            if let sel = selectedBucket, !buckets.contains(where: { $0.name == sel }) { selectedBucket = nil }
            else if selectedBucket != nil { await loadObjects() }
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func loadObjects() async {
        guard let service, let bucket = selectedBucket else { objects = []; return }
        isLoadingObjects = true
        defer { isLoadingObjects = false }
        let requested = prefix
        do {
            let result = try await service.objects(bucket: bucket, prefix: requested)
            guard bucket == selectedBucket, requested == prefix else { return }
            objects = result
            selection = selection.filter { id in result.contains { $0.id == id } }
            error = nil
        } catch {
            objects = []
            self.error = error.localizedDescription
        }
    }

    // MARK: Actions

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func createFolder() async {
        guard let service, let bucket = selectedBucket else { return }
        let name = newFolderName.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        newFolderName = ""
        guard !name.isEmpty else { return }
        do {
            try await service.createFolder(bucket: bucket, key: prefix + name + "/")
            await loadObjects()
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ items: [S3Object]) async {
        guard let service, let bucket = selectedBucket else { return }
        do {
            for item in items { try await service.delete(bucket: bucket, object: item) }
            selection.removeAll()
            await loadObjects()
        } catch { self.error = "Delete failed: \(error.localizedDescription)" }
    }

    private func deleteBucket(_ name: String) async {
        guard let service else { return }
        transfer = ("Deleting \(name)…", 0)
        defer { transfer = nil }
        do {
            try await service.deleteBucket(name)
            if selectedBucket == name { selectedBucket = nil }
            await loadBuckets()
        } catch { self.error = "Bucket deletion failed: \(error.localizedDescription)" }
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        Task { await upload(panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for p in providers {
                // The callback API keeps the (non-Sendable) provider on the main actor; only the URL crosses.
                let url: URL? = await withCheckedContinuation { cont in
                    _ = p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        cont.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                    }
                }
                if let url { urls.append(url) }
            }
            await upload(urls.filter { !$0.hasDirectoryPath })
        }
    }

    private func upload(_ urls: [URL]) async {
        guard let service, let bucket = selectedBucket, !urls.isEmpty else { return }
        for (n, url) in urls.enumerated() {
            let label = "Uploading \(url.lastPathComponent)" + (urls.count > 1 ? " (\(n + 1)/\(urls.count))" : "")
            transfer = (label, 0)
            do {
                try await service.upload(bucket: bucket, key: prefix + url.lastPathComponent, file: url) { p in
                    Task { @MainActor in transfer = (label, p) }
                }
            } catch {
                self.error = "Upload of \(url.lastPathComponent) failed: \(error.localizedDescription)"
                break
            }
        }
        transfer = nil
        await loadObjects()
    }

    private func downloadSelected() {
        let files = selectedObjects.filter { !$0.isFolder }
        if files.count == 1 { download(files[0]); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Download Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            for o in files { await download(o, to: S3Download.destination(forKey: o.key, in: dir)) }
        }
    }

    private func download(_ o: S3Object) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = S3Download.fileName(forKey: o.key)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await download(o, to: url) }
    }

    private func download(_ o: S3Object, to url: URL) async {
        guard let service, let bucket = selectedBucket else { return }
        let label = "Downloading \(o.displayName)"
        transfer = (label, 0)
        defer { transfer = nil }
        do {
            try await service.download(bucket: bucket, key: o.key, to: url) { p in
                Task { @MainActor in transfer = (label, p) }
            }
        } catch {
            self.error = "Download failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Create bucket

private struct CreateBucketSheet: View {
    let service: S3Service
    let defaultRegion: String
    let onCreated: (CreateBucketOptions) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var o = CreateBucketOptions()
    @State private var tagKey = ""
    @State private var tagValue = ""
    @State private var isCreating = false
    @State private var error: String?

    private var nameValid: Bool {
        o.bucketName.range(of: #"^[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]$"#, options: .regularExpression) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Create Bucket").font(Typo.panelTitle).padding()
            Divider()
            Form {
                Section("General") {
                    TextField("Bucket name", text: $o.bucketName, prompt: Text("my-unique-bucket"))
                    if !o.bucketName.isEmpty && !nameValid {
                        Text("3–63 characters: lowercase letters, numbers, dots and hyphens.")
                            .font(.caption).foregroundStyle(Palette.danger)
                    }
                    Picker("Region", selection: $o.region) {
                        ForEach(RegionItem.all) { Text("\($0.code) — \($0.display)").tag($0.code) }
                    }
                }
                Section("Security") {
                    Toggle("Block all public access", isOn: $o.blockAllPublicAccess)
                    Toggle("Bucket versioning", isOn: $o.versioningEnabled)
                    Picker("Default encryption", selection: $o.encryption) {
                        ForEach(CreateBucketOptions.Encryption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if o.encryption == .sseKms {
                        TextField("KMS key ARN (empty = aws/s3)", text: $o.kmsKeyArn)
                        Toggle("Bucket key", isOn: $o.bucketKeyEnabled)
                    }
                }
                Section("Tags") {
                    ForEach(Array(o.tags.enumerated()), id: \.offset) { index, tag in
                        HStack {
                            Text(tag.0).font(.body.monospaced())
                            Text("=").foregroundStyle(.secondary)
                            Text(tag.1)
                            Spacer()
                            Button { o.tags.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("Key", text: $tagKey)
                        TextField("Value", text: $tagValue)
                        Button("Add") {
                            o.tags.append((tagKey, tagValue)); tagKey = ""; tagValue = ""
                        }
                        .disabled(tagKey.isEmpty)
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
                    Task { await create() }
                } label: {
                    if isCreating { ProgressView().controlSize(.small) } else { Text("Create Bucket") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!nameValid || isCreating)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 540, height: 600)
        .onAppear { o.region = defaultRegion }
    }

    private func create() async {
        isCreating = true
        error = nil
        defer { isCreating = false }
        do {
            try await service.createBucket(o)
            onCreated(o)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Text editor

private struct S3TextEditorSheet: View {
    let service: S3Service
    let bucket: String
    let object: S3Object

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(object.displayName).font(Typo.panelTitle)
                    Text("s3://\(bucket)/\(object.key)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if text != original { Badge(text: "Modified", color: Palette.warning) }
            }
            .padding()
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $text).font(.body.monospaced()).scrollContentBackground(.hidden).padding(6)
            }
            if let error { ErrorBanner(message: error).padding(.horizontal) }
            Divider()
            HStack {
                Text("\(text.count) characters").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(text == original || isSaving)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding()
        }
        .frame(width: 760, height: 560)
        .task {
            do {
                text = try await service.getText(bucket: bucket, key: object.key)
                original = text
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.putText(bucket: bucket, key: object.key, content: text)
            original = text
        } catch {
            self.error = "Save failed: \(error.localizedDescription)"
        }
    }
}
