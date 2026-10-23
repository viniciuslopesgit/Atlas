import Foundation

/// Every 2 minutes while Atlas is open, asks GuardDuty in the active account and region for findings updated
/// since the last check and posts a desktop notification for the new ones (a summary when there are many).
/// What was already announced is kept on disk, so nothing repeats after a restart.
@MainActor
final class GuardDutyAlerts {
    nonisolated static let enabledKey = "guardDutyNotifications"
    static let interval: TimeInterval = 120
    /// Findings become visible to ListFindings a little after their `updatedAt`; the overlap catches them,
    /// the remembered ids keep them from being announced twice.
    static let overlap: TimeInterval = 300
    /// Up to this many findings get a notification each; more get one summary.
    static let individualLimit = 3
    static let rememberedIds = 1000

    struct Memory: Codable, Equatable {
        var lastCheck: Date
        var notified: [String]
    }

    struct Context {
        /// Account and region: each one has its own memory.
        let key: String
        let client: AWSClient
    }

    private let file: URL
    private let context: () -> Context?
    private let isEnabled: () -> Bool
    private let post: @MainActor (String, String) -> Void
    private(set) var memory: [String: Memory]
    private var timer: Timer?
    private var isChecking = false

    init(folder: URL, context: @escaping () -> Context?,
         isEnabled: @escaping () -> Bool = { UserDefaults.standard.object(forKey: GuardDutyAlerts.enabledKey) as? Bool ?? true },
         post: @escaping @MainActor (String, String) -> Void = StacksModel.notify) {
        file = folder.appendingPathComponent("guardduty-alerts.json")
        self.context = context
        self.isEnabled = isEnabled
        self.post = post
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        memory = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([String: Memory].self, from: $0) } ?? [:]
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.check() } }
        }
        Task { await check() }
    }

    /// One check; returns the findings it announced. The first check of an account and region only marks
    /// the starting point: findings from before Atlas watched it are on the GuardDuty page, not in notifications.
    @discardableResult
    func check(now: Date = Date()) async -> [GuardDutyFinding] {
        guard isEnabled(), !isChecking, let ctx = context() else { return [] }
        isChecking = true
        defer { isChecking = false }

        guard let previous = memory[ctx.key] else {
            remember(ctx.key, Memory(lastCheck: now, notified: []))
            return []
        }
        let service = GuardDutyService(client: ctx.client)
        let found: [GuardDutyFinding]
        do {
            guard let detector = try await service.detectorId() else {
                remember(ctx.key, Memory(lastCheck: now, notified: previous.notified))
                return []
            }
            found = try await service.findings(detectorId: detector,
                                               updatedAfter: previous.lastCheck.addingTimeInterval(-Self.overlap))
        } catch {
            // Offline or no permission: try again next time from the same point.
            return []
        }
        let seen = Set(previous.notified)
        let new = found.filter { !seen.contains($0.id) }
        announce(new)
        remember(ctx.key, Memory(lastCheck: now, notified: Array((previous.notified + new.map(\.id)).suffix(Self.rememberedIds))))
        return new
    }

    private func announce(_ findings: [GuardDutyFinding]) {
        guard let first = findings.first else { return }
        if findings.count <= Self.individualLimit {
            for f in findings {
                post("GuardDuty · \(f.level.label) severity", "\(f.title)\n\(f.resourceLabel) · \(f.region)")
            }
            return
        }
        let counts = GuardDutySeverity.allCases.reversed().compactMap { level -> String? in
            let n = findings.filter { $0.level == level }.count
            return n == 0 ? nil : "\(n) \(level.label.lowercased())"
        }
        post("\(findings.count) new GuardDuty findings in \(first.region)",
             counts.joined(separator: ", ") + "\nHighest: \(first.title)")
    }

    private func remember(_ key: String, _ m: Memory) {
        memory[key] = m
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(memory) else { return }
        try? PrivateFile.createFolder(file.deletingLastPathComponent())
        try? PrivateFile.write(data, to: file)
    }
}
