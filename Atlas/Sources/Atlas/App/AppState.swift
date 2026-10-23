import Foundation
import SwiftUI

enum Page: String, CaseIterable, Identifiable, Hashable {
    case dashboard, ec2, s3, iam, cloudWatch, guardDuty, securityAudit, billing, settings

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
        case .settings: "Accounts"
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
        case .settings: "person.crop.circle.badge.plus"
        }
    }
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
    /// Bumped to ask the visible page to reload.
    @Published var refreshToken = 0

    private let store: AccountStore
    private let secrets: SecretStore

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
