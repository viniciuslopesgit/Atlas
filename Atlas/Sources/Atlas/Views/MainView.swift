import SwiftUI

struct MainView: View {
    @EnvironmentObject private var state: AppState

    private let sections: [(String, [Page])] = [
        ("Overview", [.dashboard]),
        ("Compute & Storage", [.ec2, .s3]),
        ("Security", [.iam, .guardDuty, .securityAudit]),
        ("Monitoring", [.cloudWatch, .billing]),
        ("Infrastructure", [.iac, .stacks]),
        ("Settings", [.settings]),
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: $state.page) {
                ForEach(sections, id: \.0) { title, pages in
                    Section(title) {
                        ForEach(pages) { page in
                            Label(page.title, systemImage: page.icon).tag(page)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { AccountFooter() }
        } detail: {
            Group {
                if state.activeAccount == nil && state.page != .settings {
                    EmptyStateView(icon: "person.crop.circle.badge.questionmark",
                                   title: "No AWS account configured",
                                   message: "Add an account to start managing your AWS resources.") {
                        Button("Add Account") { state.page = .settings }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    page(state.page ?? .dashboard)
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
        .onAppear { state.stacks.startScheduler() }
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
        }
    }
}

private struct AccountFooter: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let account = state.activeAccount {
            HStack(spacing: 8) {
                Initials(name: account.name)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(account.accessKeyId).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(10)
        }
    }
}

struct Initials: View {
    let name: String
    var body: some View {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        Text(letters.isEmpty ? "?" : letters)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Palette.accent))
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
