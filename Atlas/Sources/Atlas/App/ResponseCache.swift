import Foundation

/// What the pages loaded from AWS, kept in memory: going back to a page shows its data at once, and it is
/// fetched again only when older than `ttl` or after Refresh (⌘R). Nothing is written to disk.
@MainActor
final class ResponseCache {
    private struct Entry {
        let value: Any
        let storedAt: Date
        /// `AppState.refreshToken` when stored: Refresh makes every entry stale.
        let token: Int
    }

    var ttl: TimeInterval
    private var entries: [String: Entry] = [:]

    init(ttl: TimeInterval = 180) { self.ttl = ttl }

    /// The value stored under `key`, however old.
    func value<T>(_ key: String, as type: T.Type = T.self) -> T? { entries[key]?.value as? T }

    func isFresh(_ key: String, token: Int, now: Date = Date()) -> Bool {
        guard let e = entries[key] else { return false }
        return e.token == token && now.timeIntervalSince(e.storedAt) < ttl
    }

    func store(_ value: Any, for key: String, token: Int, now: Date = Date()) {
        entries[key] = Entry(value: value, storedAt: now, token: token)
    }

    /// Forgets the entries whose key starts with `prefix` (an account), or all of them.
    func removeAll(prefix: String = "") {
        if prefix.isEmpty { entries.removeAll() } else { entries = entries.filter { !$0.key.hasPrefix(prefix) } }
    }

    var count: Int { entries.count }
}
