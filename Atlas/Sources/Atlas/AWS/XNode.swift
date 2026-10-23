import Foundation

/// Minimal XML tree used to read AWS Query / REST-XML responses.
final class XNode {
    let name: String
    var text = ""
    var children: [XNode] = []

    init(name: String) { self.name = name }

    subscript(_ name: String) -> XNode? { children.first { $0.name == name } }

    func all(_ name: String) -> [XNode] { children.filter { $0.name == name } }

    /// Navigates a "/"-separated path of child names.
    func path(_ p: String) -> XNode? {
        var node: XNode? = self
        for part in p.split(separator: "/") { node = node?[String(part)] }
        return node
    }

    /// Text at path, or "" when missing.
    func str(_ p: String) -> String { path(p)?.text ?? "" }

    func int(_ p: String) -> Int? { Int(str(p)) }

    func double(_ p: String) -> Double? { Double(str(p)) }

    func bool(_ p: String) -> Bool { str(p) == "true" }

    func date(_ p: String) -> Date? { AWSDate.parse(str(p)) }

    /// Children of a list wrapper (EC2 uses `<item>`, IAM/CloudWatch use `<member>`).
    func list(_ p: String, item: String = "item") -> [XNode] { path(p)?.all(item) ?? [] }

    /// Depth-first search for the first descendant with this name.
    func find(_ name: String) -> XNode? {
        if self.name == name { return self }
        for c in children { if let f = c.find(name) { return f } }
        return nil
    }

    static func parse(_ data: Data) -> XNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XNode(name: elementName)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if let node = stack.popLast(), !node.children.isEmpty {
                node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

enum AWSDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    static func iso(_ d: Date) -> String { plain.string(from: d) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ d: Date) -> String { dayFormatter.string(from: d) }
    static func parseDay(_ s: String) -> Date? { dayFormatter.date(from: s) }
}
