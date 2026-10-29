import SwiftUI
import Testing
@testable import Atlas

/// What replaces macOS 13+ APIs so Atlas runs on macOS 12: regular expressions without `Regex`, and the diagram's
/// keys without `KeyPress`.
struct CompatTests {
    @Test func firstMatchGivesGroupsAndNilForAGroupThatDidNotMatch() throws {
        let m = try #require(#"var.subnets["a"]"#.firstMatch(#"var\.(\w+)(?:\["([^"]+)"\])?(x)?"#))
        #expect(m[0] == #"var.subnets["a"]"#)
        #expect(m[1] == "subnets")
        #expect(m.group(2) == "a")
        #expect(m.group(3) == nil)
        #expect(m[3] == "")
        #expect("no match here".firstMatch(#"^\d+$"#) == nil)
    }

    @Test func wholeMatchNeedsTheWholeString() {
        #expect("-12.5".wholeMatch(#"-?[0-9.]+"#) != nil)
        #expect("12 ".wholeMatch(#"-?[0-9.]+"#) == nil)
        // ICU's $ also matches before a final newline: a whole match must not.
        #expect("12\n".wholeMatch(#"-?[0-9.]+"#) == nil)
        // Alternatives are anchored together, not just the first and the last.
        #expect("ab".wholeMatch("a|ab") != nil)
        #expect("xab".wholeMatch("a|ab") == nil)
    }

    @Test func allMatchesAndRangesReplaceInterpolations() {
        var value = "${a}-${bb}"
        let parts = value.allMatches(#"\$\{([^}]+)\}"#)
        #expect(parts.map { String($0[1]) } == ["a", "bb"])
        for part in parts.reversed() { value.replaceSubrange(part.range, with: String(part[1]).uppercased()) }
        #expect(value == "A-BB")
    }

    @Test func replacingMatchesTakesTheReplacementLiterally() {
        #expect("My Bucket!".lowercased().replacingMatches("[^a-z0-9]+", with: "_") == "my_bucket_")
        #expect("a.b".replacingMatches(#"\."#, with: "$0\\") == "a$0\\b")
    }

    @Test func matchesWorkOnSubstringsAndNonASCIIText() throws {
        let line = "  ╷ Error: bad ╵ tail"
        let m = try #require(line.dropFirst(2).firstMatch(#"(?s)╷(.*?)╵"#))
        #expect(m[1] == " Error: bad ")
    }

    @Test func navigationKeysFromSwiftUIAndAppKit() {
        #expect(NavigationKey(.leftArrow) == .left)
        #expect(NavigationKey(.return) == .enter)
        #expect(NavigationKey(.escape) == .escape)
        #expect(NavigationKey(KeyEquivalent("a")) == nil)
        #expect(NavigationKey(keyCode: 126) == .up)
        #expect(NavigationKey(keyCode: 125) == .down)
        #expect(NavigationKey(keyCode: 76) == .enter)
        #expect(NavigationKey(keyCode: 0) == nil)
    }

    @Test func sparklineSpansTheFrame() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(SparklineShape(values: [1]).path(in: rect).isEmpty)
        let bounds = SparklineShape(values: [0, 5, 10]).path(in: rect).boundingRect
        #expect(bounds == rect)
        // A flat line stays inside the frame.
        #expect(SparklineShape(values: [3, 3]).path(in: rect).boundingRect.maxY == 50)
    }
}
