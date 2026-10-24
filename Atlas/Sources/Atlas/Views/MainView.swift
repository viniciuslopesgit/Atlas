import SwiftUI

struct MainView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(DockerDesktopInstaller.promptedKey) private var dockerPrompted = false
    @State private var showDockerSetup = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { state.page?.menu }, set: { if let menu = $0 { state.open(menu) } })) {
                ForEach(SidebarMenu.allCases) { menu in
                    HStack {
                        Text(menu.title)
                        Spacer()
                        if menu.hasSubmenu { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    }
                    .tag(menu)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { AccountFooter() }
        } detail: {
            Group {
                if state.activeAccount == nil && state.page != .settings && state.page != .feedback {
                    EmptyStateView(icon: "person.crop.circle.badge.questionmark",
                                   title: "No AWS account configured",
                                   message: "Add an account to start managing your AWS resources.") {
                        Button("Add Account") { state.page = .settings }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    HStack(spacing: 0) {
                        if let menu = state.page?.menu, menu.hasSubmenu {
                            Submenu(menu: menu)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            Divider()
                        }
                        page(state.page ?? .dashboard).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .animation(.easeOut(duration: 0.18), value: state.page?.menu)
                }
            }
            .toolbar { MainToolbar() }
            .overlay(alignment: .bottom) {
                if let notice = state.notice {
                    NoticeBanner(message: notice) { state.notice = nil }
                        .frame(maxWidth: 560)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.tile))
                        .padding(16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: notice) {
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                            if state.notice == notice { withAnimation { state.notice = nil } }
                        }
                }
            }
            .animation(.easeOut(duration: 0.2), value: state.notice)
        }
        .sheet(isPresented: $state.showSearch) { SearchSheet() }
        .environmentObject(state.stacks)
        .sheet(isPresented: $showDockerSetup, onDismiss: { dockerPrompted = true }) { DockerSetupSheet() }
        .onAppear {
            state.stacks.startScheduler()
            // First launch: with Docker there is nothing to say; without it, offer Docker Desktop once.
            if !dockerPrompted && !SmokeTest.isEnabled && state.stacks.runtime == nil { showDockerSetup = true }
        }
    }

    @ViewBuilder
    private func page(_ page: Page) -> some View {
        switch page {
        case .dashboard: DashboardView()
        case .ec2: Ec2View()
        case .s3: S3View()
        case .iam: IamView()
        case .cloudWatch: CloudWatchView()
        case .guardDuty: GuardDutyView()
        case .securityAudit: SecurityAuditView()
        case .billing: BillingView()
        case .iac: IaCView()
        case .stacks: StacksView()
        case .settings: SettingsView()
        case .feedback: FeedbackView()
        }
    }
}

/// The pages of a sidebar menu, in a column to the right of the sidebar.
private struct Submenu: View {
    @EnvironmentObject private var state: AppState
    let menu: SidebarMenu

    var body: some View {
        List(selection: $state.page) {
            Section(menu.title) {
                ForEach(menu.pages) { Text($0.title).tag($0) }
            }
        }
        .frame(width: 190)
    }
}

/// Accounts and Feedback, outside the three sidebar menus.
private struct AccountFooter: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Button { state.page = .settings } label: {
                HStack(spacing: 8) {
                    Initials(name: state.activeAccount?.name ?? "")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.activeAccount?.name ?? "Add account").font(.callout).lineLimit(1)
                        if let account = state.activeAccount {
                            Text(account.accessKeyId).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Accounts")

            Button { state.page = .feedback } label: { Image(systemName: "envelope") }
                .buttonStyle(.borderless)
                .foregroundStyle(state.page == .feedback ? .primary : .secondary)
                .help("Send feedback")
        }
        .padding(10)
    }
}

struct Initials: View {
    let name: String
    var body: some View {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(letters.isEmpty ? "?" : letters)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(Circle().strokeBorder(.tertiary))
    }
}

private struct MainToolbar: ToolbarContent {
    @EnvironmentObject private var state: AppState

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !state.accounts.isEmpty {
                Menu {
                    ForEach(state.accounts) { account in
                        Button {
                            state.setActive(account.id)
                        } label: {
                            if account.isActive { Label(account.name, systemImage: "checkmark") } else { Text(account.name) }
                        }
                    }
                    Divider()
                    Button("Manage Accounts…") { state.page = .settings }
                } label: {
                    Label(state.activeAccount?.name ?? "Account", systemImage: "person.crop.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help("Active AWS account")

                Picker("Region", selection: $state.region) {
                    ForEach(RegionItem.all) { r in
                        Text("\(r.code) — \(r.display)").tag(r.code)
                    }
                }
                .frame(width: 260)
                .help("Active region")
            }

            Button { state.showSearch = true } label: { Label("Search", systemImage: "magnifyingglass") }
                .help("Search resources (⌘K)")
            Button { state.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh (⌘R)")
        }
    }
}
