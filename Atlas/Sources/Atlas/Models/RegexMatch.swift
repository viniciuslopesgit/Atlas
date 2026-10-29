import Foundation

/// Regular expressions that work on macOS 12: Swift's `Regex` and its `#/…/#` literals need macOS 13.
/// Patterns use NSRegularExpression (ICU) syntax and are compiled once.
struct RegexMatch {
    /// [0] is the whole match; a group that took no part in the match is nil.
    let groups: [Substring?]

    /// The text of group `i`, or "" when it took no part in the match.
    subscript(_ i: Int) -> Substring { groups[i] ?? "" }
    /// The text of group `i`, or nil when it took no part in the match.
    func group(_ i: Int) -> Substring? { groups[i] }
    /// Where the whole match is in the string that was searched.
    var range: Range<String.Index> { groups[0]!.startIndex..<groups[0]!.endIndex }
}

enum Pattern {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var compiled: [String: NSRegularExpression] = [:]

    static func regex(_ pattern: String) -> NSRegularExpression {
        lock.lock(); defer { lock.unlock() }
        if let re = compiled[pattern] { return re }
        // Patterns are literals in the source: an invalid one is a programming error.
        let re = try! NSRegularExpression(pattern: pattern)
        compiled[pattern] = re
        return re
    }
}

extension StringProtocol {
    /// The first match of `pattern`, or nil.
    func firstMatch(_ pattern: String) -> RegexMatch? {
        let s = String(self)
        return Pattern.regex(pattern).firstMatch(in: s, range: NSRange(s.startIndex..., in: s)).map { $0.match(in: s) }
    }

    /// The match of `pattern` against the whole string, or nil.
    func wholeMatch(_ pattern: String) -> RegexMatch? {
        let s = String(self)
        return Pattern.regex("^(?:\(pattern))$").firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
            .flatMap { $0.range.length == (s as NSString).length ? $0.match(in: s) : nil }
    }

    /// Every match of `pattern`, in order.
    func allMatches(_ pattern: String) -> [RegexMatch] {
        let s = String(self)
        return Pattern.regex(pattern).matches(in: s, range: NSRange(s.startIndex..., in: s)).map { $0.match(in: s) }
    }

    /// `self` with every match of `pattern` replaced by `replacement` (taken literally).
    func replacingMatches(_ pattern: String, with replacement: String) -> String {
        let s = String(self)
        return Pattern.regex(pattern).stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}

private extension NSTextCheckingResult {
    func match(in s: String) -> RegexMatch {
        RegexMatch(groups: (0..<numberOfRanges).map { Range(range(at: $0), in: s).map { s[$0] } })
    }
}
