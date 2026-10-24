import Foundation
import CryptoKit

// MARK: - Model (ported from Models/StackEntry.cs of Atlas 1.0.1)

enum StackStatus: String, Codable, Sendable, CaseIterable { case ready, queued, running, finished, failed }
enum StackRunType: String, Codable, Sendable {
    case importResources = "import", initialize = "init", fix, plan, apply, fixDrift, setup

    /// The phase name of a run saved before phases were recorded.
    var phaseName: String {
        switch self {
        case .importResources: "Importing"
        case .initialize: "Initializing"
        case .fix: "Fixing"
        case .plan: "Planning"
        case .apply, .fixDrift: "Applying"
        case .setup: "Preparing"
        }
    }
}
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

/// One step of a run (preparing the container, init, plan, apply…), with its time and where its output begins.
struct StackRunPhase: Codable, Sendable, Equatable {
    var name: String
    var startedAt: Date
    var completedAt: Date?
    var status: StackRunStatus = .running
    /// Index in the run's output lines of the phase's first line.
    var firstLine: Int
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
    var phases: [StackRunPhase] = []

    enum CodingKeys: String, CodingKey { case id, type, status, trigger, startedAt, completedAt, phases }

    init(id: UUID = UUID(), type: StackRunType, status: StackRunStatus = .running, trigger: String,
         startedAt: Date = Date(), completedAt: Date? = nil, output: String = "") {
        self.id = id; self.type = type; self.status = status; self.trigger = trigger
        self.startedAt = startedAt; self.completedAt = completedAt; self.output = output
    }

    /// Runs saved before phases still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        type = try c.decode(StackRunType.self, forKey: .type)
        status = try c.decode(StackRunStatus.self, forKey: .status)
        trigger = try c.decode(String.self, forKey: .trigger)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        phases = try c.decodeIfPresent([StackRunPhase].self, forKey: .phases) ?? []
    }

    var lineCount: Int { output.isEmpty ? 0 : output.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 } }

    /// Ends the current phase and starts `name` at the next output line.
    mutating func begin(_ name: String, at date: Date = Date()) {
        close(at: date, as: .success)
        phases.append(StackRunPhase(name: name, startedAt: date, firstLine: lineCount))
    }

    /// Ends the run: the phase still going gets the run's status, earlier ones had succeeded.
    mutating func finish(_ status: StackRunStatus, at date: Date) {
        self.status = status
        completedAt = date
        close(at: date, as: status)
    }

    private mutating func close(at date: Date, as status: StackRunStatus) {
        for i in phases.indices where phases[i].status == .running {
            phases[i].status = i == phases.count - 1 ? status : .success
            phases[i].completedAt = date
        }
    }

    /// The phases with their output, oldest first. A run without phases (saved before them) is one phase.
    var timeline: [(phase: StackRunPhase, output: String)] {
        let list = phases.isEmpty
            ? [StackRunPhase(name: type.phaseName, startedAt: startedAt, completedAt: completedAt, status: status, firstLine: 0)]
            : phases
        let lines = output.isEmpty ? [] : output.components(separatedBy: "\n")
        return list.enumerated().map { i, phase in
            let start = min(phase.firstLine, lines.count)
            let end = i + 1 < list.count ? max(start, min(list[i + 1].firstLine, lines.count)) : lines.count
            return (phase, lines[start..<end].joined(separator: "\n"))
        }
    }

    /// Output kept per run; a long apply or import would otherwise grow it (and memory) without limit.
    static let maxOutputBytes = 1_000_000
    static let trimmedNotice = "… earlier output removed (only the last part of a long run is kept) …"

    /// Appends lines; past `maxOutputBytes` keeps the last three quarters, cut at a line break.
    mutating func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        output += (output.isEmpty ? "" : "\n") + lines.joined(separator: "\n")
        guard output.utf8.count > Self.maxOutputBytes else { return }
        let before = lineCount
        var tail = String(decoding: output.utf8.suffix(Self.maxOutputBytes * 3 / 4), as: UTF8.self)
        if let nl = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: nl)...]) }
        output = Self.trimmedNotice + "\n" + tail
        // The notice takes line 0; a phase whose start was cut begins at it.
        let removed = before - (lineCount - 1)
        for i in phases.indices { phases[i].firstLine = phases[i].firstLine >= removed ? phases[i].firstLine - removed + 1 : 0 }
    }

    var duration: TimeInterval? { completedAt.map { $0.timeIntervalSince(startedAt) } }

    /// "00:02", "12:30" or "1:02:03", as a run's clock.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
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

/// `stacks.json` with env var values in the Keychain; each finished run's whole output in its own file, encrypted
/// (AES-GCM, key in the Keychain). A run still going keeps its last lines in `stacks.json`, also encrypted.
struct StackStore {
    static let outputKeyName = "atlas-stacks-output-key"
    static let maxOutputLines = 300

    var folder: URL = AccountStore.defaultFolder
    var secrets: SecretStore
    /// What this store already wrote or read, so a save only touches the Keychain and disk for what changed.
    private let memo = Memo()

    private final class Memo: @unchecked Sendable {
        let lock = NSLock()
        var key: SymmetricKey?
        /// Keychain values as last written or read, by Keychain name.
        var envValues: [String: String] = [:]
        var savedLogs = Set<String>()
    }

    private var file: URL {
        try? PrivateFile.createFolder(folder)
        return folder.appendingPathComponent("stacks.json")
    }

    private struct StoredRun: Codable {
        var run: StackRun
        var encryptedOutput: String
    }

    private struct Stored: Codable {
        var stack: StackEntry
        var runs: [StoredRun]
        /// The drift summary and plan diff (they can show resource values), encrypted.
        var encryptedDrift: String?
    }

    private struct Drift: Codable {
        var summary: String?
        var diff: String?
    }

    func load() -> [StackEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([Stored].self, from: data) else { return [] }
        let key = outputKey()
        return stored.map { s in
            var stack = s.stack
            if let sealed = s.encryptedDrift, let key, let json = Self.decrypt(sealed, key: key),
               let drift = try? JSONDecoder().decode(Drift.self, from: Data(json.utf8)) {
                stack.driftSummary = drift.summary
                stack.driftDiff = drift.diff
            }
            stack.runs = s.runs.map { r in
                var run = r.run
                let sealed = r.encryptedOutput.isEmpty
                    ? (try? String(contentsOf: runLogFile(stack.id, run.id), encoding: .utf8)) ?? ""
                    : r.encryptedOutput
                run.output = key.flatMap { Self.decrypt(sealed, key: $0) } ?? ""
                return run
            }
            for i in stack.envVars.indices {
                let name = Self.envKey(stack.id, stack.envVars[i].id)
                let value = secrets.get(name)
                stack.envVars[i].value = value ?? ""
                if let value { memo.lock.withLock { memo.envValues[name] = value } }
            }
            return stack
        }
    }

    func save(_ stacks: [StackEntry]) {
        let key = outputKey(create: true)
        let stored = stacks.map { stack -> Stored in
            for v in stack.envVars { setSecret(v.value, for: Self.envKey(stack.id, v.id)) }
            let runs = stack.runs.map { run in
                if run.completedAt != nil, let key, saveLog(run, of: stack.id, key: key) {
                    return StoredRun(run: run, encryptedOutput: "")
                }
                let tail = run.output.components(separatedBy: "\n").suffix(Self.maxOutputLines).joined(separator: "\n")
                return StoredRun(run: run, encryptedOutput: key.flatMap { Self.encrypt(tail, key: $0) } ?? "")
            }
            var meta = stack
            meta.runs = []
            meta.driftSummary = nil
            meta.driftDiff = nil
            var drift: String?
            if stack.driftSummary != nil || stack.driftDiff != nil, let key,
               let json = try? JSONEncoder().encode(Drift(summary: stack.driftSummary, diff: stack.driftDiff)) {
                drift = Self.encrypt(String(decoding: json, as: UTF8.self), key: key)
            }
            return Stored(stack: meta, runs: runs, encryptedDrift: drift)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Readable only by the user, like accounts.json.
        if let data = try? encoder.encode(stored) { try? PrivateFile.write(data, to: file) }
    }

    /// Writes a Keychain value only when it differs from the one this store last wrote or read.
    private func setSecret(_ value: String, for name: String) {
        guard memo.lock.withLock({ memo.envValues[name] }) != value else { return }
        if (try? secrets.set(value, for: name)) != nil { memo.lock.withLock { memo.envValues[name] = value } }
    }

    /// A finished run's output does not change: its file is written once.
    private func saveLog(_ run: StackRun, of stack: UUID, key: SymmetricKey) -> Bool {
        let file = runLogFile(stack, run.id)
        if memo.lock.withLock({ memo.savedLogs.contains(file.path) }) { return true }
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let sealed = Self.encrypt(run.output, key: key) else { return false }
            do {
                try PrivateFile.createFolder(file.deletingLastPathComponent())
                try PrivateFile.write(Data(sealed.utf8), to: file)
            } catch { return false }
        }
        memo.lock.withLock { _ = memo.savedLogs.insert(file.path) }
        return true
    }

    func runLogFile(_ stack: UUID, _ run: UUID) -> URL {
        stacksFolder(stack).appendingPathComponent("runs", isDirectory: true).appendingPathComponent("\(run.uuidString).log")
    }

    /// Removes the Keychain items of a stack that is being deleted.
    func forget(_ stack: StackEntry) {
        for v in stack.envVars { forgetSecret(Self.envKey(stack.id, v.id)) }
    }

    func forget(envVar: StackEnvVar, of stack: StackEntry) { forgetSecret(Self.envKey(stack.id, envVar.id)) }

    private func forgetSecret(_ name: String) {
        secrets.delete(name)
        memo.lock.withLock { _ = memo.envValues.removeValue(forKey: name) }
    }

    /// Where a stack's container keeps the engine's data (providers, modules, backend cache), one per engine.
    func dataFolder(_ stack: UUID, _ engine: TerraformEngine) -> URL {
        stacksFolder(stack).appendingPathComponent(engine.rawValue, isDirectory: true)
    }

    /// A stack's saved plans, inside its data folder (mounted in the container at `StackContainer.dataDirectory`).
    func planFolder(_ stack: UUID, _ engine: TerraformEngine) -> URL {
        dataFolder(stack, engine).appendingPathComponent("plans", isDirectory: true)
    }

    /// Providers downloaded by the containers of an engine, shared by all stacks (TF_PLUGIN_CACHE_DIR).
    func pluginCacheFolder(_ engine: TerraformEngine) -> URL {
        folder.appendingPathComponent("plugin-cache", isDirectory: true).appendingPathComponent(engine.rawValue, isDirectory: true)
    }

    func stacksFolder(_ stack: UUID) -> URL {
        folder.appendingPathComponent("stacks", isDirectory: true).appendingPathComponent(stack.uuidString, isDirectory: true)
    }

    static func envKey(_ stack: UUID, _ variable: String) -> String { "atlas-stack-env:\(stack.uuidString):\(variable)" }

    /// Read from the Keychain once per store, not on every save.
    private func outputKey(create: Bool = false) -> SymmetricKey? {
        if let key = memo.lock.withLock({ memo.key }) { return key }
        if let b64 = secrets.get(Self.outputKeyName), let data = Data(base64Encoded: b64), data.count == 32 {
            let key = SymmetricKey(data: data)
            memo.lock.withLock { memo.key = key }
            return key
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        guard (try? secrets.set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), for: Self.outputKeyName)) != nil else { return key }
        memo.lock.withLock { memo.key = key }
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
