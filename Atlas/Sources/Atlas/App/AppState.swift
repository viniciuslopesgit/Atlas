import Foundation
import SwiftUI

enum Page: String, CaseIterable, Identifiable, Hashable {
    case dashboard, ec2, s3, iam, cloudWatch, guardDuty, securityAudit, billing, iac, stacks, settings, feedback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .ec2: "EC2 Instances"
        case .s3: "S3 Buckets"
        case .iam: "IAM"
        case .cloudWatch: "CloudWatch"
        case .guardDuty: "GuardDuty"
        case .securityAudit: "Security Audit"
        case .billing: "Billing"
        case .iac: "Infrastructure as Code"
        case .stacks: "Stacks"
        case .settings: "Accounts"
        case .feedback: "Feedback"
        }
    }

    /// Extra words the ⌘K search matches for this page.
    var keywords: [String] {
        switch self {
        case .dashboard: ["home", "overview", "costs", "summary"]
        case .ec2: ["instances", "servers", "compute", "launch", "ssm", "connect"]
        case .s3: ["buckets", "storage", "files", "objects", "upload"]
        case .iam: ["users", "roles", "groups", "policies", "access keys", "permissions"]
        case .cloudWatch: ["alarms", "metrics", "monitoring"]
        case .guardDuty: ["guard", "threats", "findings", "detection"]
        case .securityAudit: ["audit", "mfa", "password policy", "imds", "public"]
        case .billing: ["costs", "spend", "invoice", "forecast"]
        case .iac: ["terraform", "iac", "infrastructure", "code", "init", "plan", "apply", "import", "hcl"]
        case .stacks: ["stacks", "terraform", "runs", "drift", "import", "plan", "apply", "history", "cron"]
        case .settings: ["settings", "config", "accounts", "preferences", "keys", "updates"]
        case .feedback: ["contact", "feedback", "bug", "report", "suggestion", "help", "issue"]
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .ec2: "server.rack"
        case .s3: "archivebox"
        case .iam: "person.2.badge.key"
        case .cloudWatch: "waveform.path.ecg"
        case .guardDuty: "shield.lefthalf.filled"
        case .securityAudit: "checkmark.shield"
        case .billing: "dollarsign.circle"
        case .iac: "chevron.left.forwardslash.chevron.right"
        case .stacks: "square.stack.3d.up"
        case .settings: "person.crop.circle.badge.plus"
        case .feedback: "envelope"
        }
    }
}

/// The sidebar's three menus. Accounts and Feedback live in the sidebar footer instead.
enum SidebarMenu: String, CaseIterable, Identifiable {
    case dashboard, resources, stacks

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var pages: [Page] {
        switch self {
        case .dashboard: [.dashboard, .billing]
        case .resources: [.ec2, .s3, .iam, .cloudWatch, .guardDuty, .securityAudit]
        case .stacks: [.stacks, .iac]
        }
    }
}

extension Page {
    /// The sidebar menu that lists this page; nil for the footer pages (Accounts, Feedback).
    var menu: SidebarMenu? { SidebarMenu.allCases.first { $0.pages.contains(self) } }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var accounts: [AwsAccount] = []
    @Published var region: String = "us-east-1"
    @Published var page: Page? = .dashboard
    @Published var showSearch = false
    /// A short confirmation shown at the bottom of the window (e.g. "Added to project: ec2.tf").
    @Published var notice: String?
    /// Bumped to ask the visible page to reload.
    @Published var refreshToken = 0

    private let store: AccountStore
    private let secrets: SecretStore
    var usesKeychain: Bool { secrets is KeychainSecretStore }

    init(store: AccountStore = AccountStore(), secrets: SecretStore = KeychainSecretStore()) {
        self.store = store
        self.secrets = secrets
        accounts = store.load()
        region = activeAccount?.defaultRegion ?? "us-east-1"
        if accounts.isEmpty { page = .settings }
    }

    var activeAccount: AwsAccount? { accounts.first { $0.isActive } }

    /// Identifies the current AWS context; pages reload when it changes.
    var sessionKey: String { "\(activeAccount?.id ?? "none")|\(region)|\(refreshToken)" }

    /// Client for the active account and region, or nil when no account is configured.
    var client: AWSClient? {
        guard let account = activeAccount else { return nil }
        let key = "\(account.id)|\(region)"
        if let cached = cachedClient, cached.key == key { return cached.client }
        guard let secret = secrets.get(account.id) else { return nil }
        let client = AWSClient(credentials: AWSCredentials(accessKeyId: account.accessKeyId, secretAccessKey: secret),
                               region: region)
        cachedClient = (key, client)
        return client
    }

    private var cachedClient: (key: String, client: AWSClient)?

    /// Client for any configured account (stacks run against the account they were created with).
    func client(accountId: String, region: String) -> AWSClient? {
        guard let account = accounts.first(where: { $0.id == accountId }), let secret = secrets.get(account.id) else { return nil }
        return AWSClient(credentials: AWSCredentials(accessKeyId: account.accessKeyId, secretAccessKey: secret), region: region)
    }

    /// Stacks and their drift scheduler live as long as the app.
    private(set) lazy var stacks = StacksModel(
        store: StackStore(folder: store.folder, secrets: secrets),
        clientFor: { [unowned self] stack in self.client(accountId: stack.accountId, region: stack.region) })

    func refresh() { refreshToken += 1 }

    // MARK: Account management

    static func validate(accessKeyId: String, secret: String, region: String) async throws -> StsService.Identity {
        let client = AWSClient(credentials: AWSCredentials(accessKeyId: accessKeyId, secretAccessKey: secret), region: region)
        return try await StsService(client: client).callerIdentity()
    }

    func addAccount(name: String, accessKeyId: String, secret: String, region: String) throws {
        let account = AwsAccount(name: name, accessKeyId: accessKeyId, defaultRegion: region, isActive: accounts.isEmpty)
        try secrets.set(secret, for: account.id)
        accounts.append(account)
        store.save(accounts)
        if account.isActive { self.region = region }
    }

    func removeAccount(_ id: String) {
        let wasActive = activeAccount?.id == id
        secrets.delete(id)
        accounts.removeAll { $0.id == id }
        if wasActive, let first = accounts.first {
            setActive(first.id)
        } else {
            store.save(accounts)
        }
    }

    func setActive(_ id: String) {
        for i in accounts.indices { accounts[i].isActive = accounts[i].id == id }
        store.save(accounts)
        region = activeAccount?.defaultRegion ?? region
    }
}

enum AppInfo {
    /// Set by scripts/build-app.sh from scripts/version.sh; "dev" when run with `swift run`.
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
}

/// Talks to the updater LaunchAgent installed by scripts/install-updater.sh.
enum Updater {
    static let label = "io.cloud-atlas.updater"
    private static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Atlas/updater")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist").path)
    }

    struct Status {
        var lastCheck: Date?
        var result = ""
        var latest = ""

        var description: String {
            guard let lastCheck else { return isInstalled ? "Automatic updates on, not checked yet" : "Automatic updates off" }
            let when = lastCheck.formatted(.relative(presentation: .named))
            return result.isEmpty ? "Checked \(when)" : "Checked \(when): \(result)"
        }
    }

    static func status() -> Status {
        struct Raw: Decodable { let lastCheck: String; let result: String; let latest: String }
        guard let data = try? Data(contentsOf: support.appendingPathComponent("state.json")),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return Status() }
        return Status(lastCheck: ISO8601DateFormatter().date(from: raw.lastCheck), result: raw.result, latest: raw.latest)
    }

    /// Runs the agent immediately; it quits and relaunches Atlas if a newer release exists.
    static func checkNow() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        try? task.run()
    }
}
