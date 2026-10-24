import Foundation
import CryptoKit

// MARK: - Model (ported from Models/StackEntry.cs of Atlas 1.0.1)

enum StackStatus: String, Codable, Sendable, CaseIterable { case ready, queued, running, finished, failed }
enum StackRunType: String, Codable, Sendable { case importResources = "import", initialize = "init", fix, plan, apply, fixDrift, setup }
enum StackRunStatus: String, Codable, Sendable { case running, success, failed, cancelled }
enum DriftStatus: String, Codable, Sendable { case unknown, checking, clean, drifted, error }

enum DriftInterval: String, Codable, Sendable, CaseIterable, Identifiable {
    case off, hourly, daily, weekly
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .hourly: 3600
        case .daily: 86400
        case .weekly: 604_800
        }
    }
}

struct StackRun: Codable, Identifiable, Sendable {
    var id = UUID()
    var type: StackRunType
    var status: StackRunStatus = .running
    var trigger: String
    var startedAt = Date()
    var completedAt: Date?
    /// Plain text only in memory; `StackStore` writes it encrypted.
    var output = ""

    enum CodingKeys: String, CodingKey { case id, type, status, trigger, startedAt, completedAt }

    /// Output kept per run; a long apply or import would otherwise grow it (and memory) without limit.
    static let maxOutputBytes = 1_000_000
    static let trimmedNotice = "… earlier output removed (only the last part of a long run is kept) …"

    /// Appends lines; past `maxOutputBytes` keeps the last three quarters, cut at a line break.
    mutating func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        output += (output.isEmpty ? "" : "\n") + lines.joined(separator: "\n")
        guard output.utf8.count > Self.maxOutputBytes else { return }
        var tail = String(decoding: output.utf8.suffix(Self.maxOutputBytes * 3 / 4), as: UTF8.self)
        if let nl = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: nl)...]) }
        output = Self.trimmedNotice + "\n" + tail
    }

    var duration: TimeInterval? { completedAt.map { $0.timeIntervalSince(startedAt) } }
    var durationText: String {
        guard let d = duration else { return "running…" }
        return d >= 60 ? "\(Int(d) / 60)m \(Int(d) % 60)s" : "\(Int(d))s"
    }
}

struct StackEntry: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var projectPath: String
    /// The Atlas account and region the stack's terraform runs against.
    var accountId: String
    var region: String
    var status: StackStatus = .ready
    var createdAt = Date()
    var runs: [StackRun] = []
    /// Names and metadata only; the values live in the Keychain.
    var envVars: [StackEnvVar] = []

    var driftInterval: DriftInterval = .off
    var driftCron: [String] = []
    var driftStatus: DriftStatus = .unknown
    var driftSummary: String?
    var driftDiff: String?
    var lastDriftCheckAt: Date?
    var driftAcknowledged = false
    var autoFixOnDrift = false
    /// Optional so stacks saved before 2.5 still decode; nil is Terraform.
    var engineChoice: TerraformEngine?

    var engine: TerraformEngine {
        get { engineChoice ?? .terraform }
        set { engineChoice = newValue }
    }
    var url: URL { URL(fileURLWithPath: projectPath, isDirectory: true) }
    var lastRun: StackRun? { runs.first }
    var driftEnabled: Bool { driftInterval != .off || !driftCron.isEmpty }

    /// When the next scheduled drift check is due (interval or the earliest cron occurrence).
    func nextDriftCheck(after now: Date = Date()) -> Date? {
        var candidates: [Date] = []
        if let s = driftInterval.seconds { candidates.append(lastDriftCheckAt.map { $0.addingTimeInterval(s) } ?? now) }
        let since = lastDriftCheckAt ?? now.addingTimeInterval(-86400)
        for expr in driftCron { if let next = CronExpression(expr)?.next(after: since) { candidates.append(next) } }
        return candidates.min()
    }

    func isDriftDue(now: Date = Date()) -> Bool {
        guard driftEnabled, driftStatus != .checking, status != .running else { return false }
        return nextDriftCheck(after: now).map { $0 <= now } ?? false
    }
}

// MARK: - Cron (5 fields, no dependencies)

/// Standard 5-field cron: minute hour day-of-month month day-of-week.
/// Supports `*`, values, ranges `a-b`, steps `*/n` and `a-b/n`, and lists `a,b`. Sunday is 0 or 7.
/// As in cron, when both day fields are restricted a day matches if either does.
struct CronExpression: Sendable, Equatable {
    let minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    let dayRestricted: Bool, weekdayRestricted: Bool

    init?(_ text: String) {
        let f = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard f.count == 5,
              let mi = Self.field(f[0], 0, 59), let h = Self.field(f[1], 0, 23), let d = Self.field(f[2], 1, 31),
              let mo = Self.field(f[3], 1, 12), let w = Self.field(f[4], 0, 7) else { return nil }
        minutes = mi; hours = h; days = d; months = mo
        weekdays = Set(w.map { $0 == 7 ? 0 : $0 })
        dayRestricted = f[2] != "*"
        weekdayRestricted = f[4] != "*"
    }

    private static func field(_ s: String, _ lo: Int, _ hi: Int) -> Set<Int>? {
        var out = Set<Int>()
        for part in s.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return nil }
            let step = pieces.count == 2 ? Int(pieces[1]) : 1
            guard let step, step > 0 else { return nil }
            var a = lo, b = hi
            if pieces[0] != "*" {
                let range = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(range.count), let x = Int(range[0]) else { return nil }
                a = x
                b = range.count == 2 ? (Int(range[1]) ?? -1) : (pieces.count == 2 ? hi : x)
            }
            guard lo <= a, a <= b, b <= hi else { return nil }
            out.formUnion(stride(from: a, through: b, by: step))
        }
        return out.isEmpty ? nil : out
    }

    private func dayMatches(_ day: Int, _ weekday: Int) -> Bool {
        let d = days.contains(day), w = weekdays.contains(weekday)
        if dayRestricted && weekdayRestricted { return d || w }
        return d && w
    }

    /// The first matching minute strictly after `date`, within about four years.
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        var cal = calendar
        cal.locale = Locale(identifier: "en_US_POSIX")
        let minute = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard var t = cal.date(from: minute)?.addingTimeInterval(60) else { return nil }
        let limit = date.addingTimeInterval(4 * 366 * 86400)
        while t < limit {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: t)
            guard let month = c.month, let day = c.day, let hour = c.hour, let minute = c.minute, let wd = c.weekday else { return nil }
            if !months.contains(month) {
                guard let start = cal.date(from: DateComponents(year: c.year, month: month, day: 1)),
                      let next = cal.date(byAdding: .month, value: 1, to: start) else { return nil }
                t = next
            } else if !dayMatches(day, wd - 1) {
                guard let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: t)) else { return nil }
                t = next
            } else if !hours.contains(hour) {
                guard let next = cal.date(byAdding: .hour, value: 1, to: cal.date(bySettingHour: hour, minute: 0, second: 0, of: t) ?? t)
                else { return nil }
                t = next
            } else if !minutes.contains(minute) {
                t = t.addingTimeInterval(60)
            } else {
                return t
            }
        }
        return nil
    }
}

// MARK: - Drift report

/// What a `plan -detailed-exitcode` with changes says about drift.
struct DriftReport: Equatable, Sendable {
    struct Change: Equatable, Sendable {
        enum Action: String, Sendable { case create, update, replace, destroy, read }
        let address: String
        let action: Action
    }

    static let maxDiffLines = 400

    var summary: String?
    var diff: String?
    var changes: [Change] = []

    init(planOutput: String) {
        summary = Self.summary(planOutput)
        diff = Self.diff(planOutput)
        changes = Self.changes(planOutput)
    }

    /// "Plan: 0 to add, 3 to change, 0 to destroy." → "3 to change"
    static func summary(_ output: String) -> String? {
        guard let m = output.firstMatch(of: #/Plan:\s+(.+?)\./#) else { return nil }
        let parts = m.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("0 ") }
        return parts.isEmpty ? String(m.1).trimmingCharacters(in: .whitespaces) : parts.joined(separator: ", ")
    }

    /// The resource diff, from the first `# address …` line up to `Plan:`.
    static func diff(_ output: String) -> String? {
        var kept: [String] = []
        var inDiff = false
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !inDiff && t.hasPrefix("# ") { inDiff = true }
            guard inDiff else { continue }
            if t.hasPrefix("Plan:") || t.hasPrefix("No changes.") { break }
            if kept.count >= maxDiffLines { kept.append("… (plan diff truncated)"); break }
            kept.append(line)
        }
        let s = kept.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return s.isEmpty ? nil : s
    }

    static func changes(_ output: String) -> [Change] {
        output.components(separatedBy: "\n").compactMap { line in
            guard let m = line.firstMatch(of: #/^\s*# (\S+) (will be|must be|has been) (.+)$/#) else { return nil }
            let what = String(m.3)
            let action: Change.Action? =
                what.hasPrefix("created") ? .create
                : what.hasPrefix("updated") || what.hasPrefix("changed") ? .update
                : what.hasPrefix("replaced") || what.contains("replaced") ? .replace
                : what.hasPrefix("destroyed") || what.hasPrefix("deleted") ? .destroy
                : what.hasPrefix("read") ? .read : nil
            return action.map { Change(address: String(m.1), action: $0) }
        }
    }
}

// MARK: - Persistence

/// `stacks.json` with run output encrypted (AES-GCM, key in the Keychain) and env var values in the Keychain.
struct StackStore {
    static let outputKeyName = "atlas-stacks-output-key"
    static let maxOutputLines = 300

    var folder: URL = AccountStore.defaultFolder
    var secrets: SecretStore

    private var file: URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("stacks.json")
    }

    private struct StoredRun: Codable {
        var run: StackRun
        var encryptedOutput: String
    }

    private struct Stored: Codable {
        var stack: StackEntry
        var runs: [StoredRun]
    }

    func load() -> [StackEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([Stored].self, from: data) else { return [] }
        let key = outputKey()
        return stored.map { s in
            var stack = s.stack
            stack.runs = s.runs.map { r in
                var run = r.run
                run.output = key.flatMap { Self.decrypt(r.encryptedOutput, key: $0) } ?? ""
                return run
            }
            for i in stack.envVars.indices { stack.envVars[i].value = secrets.get(Self.envKey(stack.id, stack.envVars[i].id)) ?? "" }
            return stack
        }
    }

    func save(_ stacks: [StackEntry]) {
        let key = outputKey(create: true)
        let stored = stacks.map { stack -> Stored in
            for v in stack.envVars { try? secrets.set(v.value, for: Self.envKey(stack.id, v.id)) }
            let runs = stack.runs.map { run in
                let tail = run.output.components(separatedBy: "\n").suffix(Self.maxOutputLines).joined(separator: "\n")
                return StoredRun(run: run, encryptedOutput: key.flatMap { Self.encrypt(tail, key: $0) } ?? "")
            }
            var meta = stack
            meta.runs = []
            return Stored(stack: meta, runs: runs)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(stored) { try? data.write(to: file, options: [.atomic]) }
    }

    /// Removes the Keychain items of a stack that is being deleted.
    func forget(_ stack: StackEntry) {
        for v in stack.envVars { secrets.delete(Self.envKey(stack.id, v.id)) }
    }

    func forget(envVar: StackEnvVar, of stack: StackEntry) { secrets.delete(Self.envKey(stack.id, envVar.id)) }

    static func envKey(_ stack: UUID, _ variable: String) -> String { "atlas-stack-env:\(stack.uuidString):\(variable)" }

    private func outputKey(create: Bool = false) -> SymmetricKey? {
        if let b64 = secrets.get(Self.outputKeyName), let data = Data(base64Encoded: b64), data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        try? secrets.set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: Self.outputKeyName)
        return key
    }

    static func encrypt(_ text: String, key: SymmetricKey) -> String? {
        guard !text.isEmpty else { return "" }
        return (try? AES.GCM.seal(Data(text.utf8), using: key))?.combined?.base64EncodedString()
    }

    static func decrypt(_ b64: String, key: SymmetricKey) -> String? {
        guard !b64.isEmpty else { return "" }
        guard let data = Data(base64Encoded: b64), let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }
}
