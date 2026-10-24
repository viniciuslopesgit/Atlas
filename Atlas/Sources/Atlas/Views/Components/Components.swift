import SwiftUI
import AppKit

/// Atlas visual identity, minimal: greys carry the layout; one teal accent for actions and spend,
/// state colors only on small dots and figures that need attention.
enum Palette {
    /// "Meridian" — the app's accent (replaces the system blue).
    static let accent = adaptive(light: 0x16797A, dark: 0x3FB8B4)
    /// "Lichen" — running / OK.
    static let success = adaptive(light: 0x2F8A57, dark: 0x5CC48A)
    /// "Ochre" — pending / warning.
    static let warning = adaptive(light: 0xB07C1F, dark: 0xE0B04E)
    /// "Brick" — stopped / critical.
    static let danger = adaptive(light: 0xB8492F, dark: 0xE8775C)
    /// "Slate" — neutral or terminated states.
    static let neutral = adaptive(light: 0x6B7682, dark: 0x8D98A4)
    static let purple = adaptive(light: 0x6E5BB8, dark: 0xA594E8)
    /// "Fjord" — networks, in the Terraform diagram.
    static let blue = adaptive(light: 0x2F6DB5, dark: 0x6FA3E8)

    static func ec2State(_ state: String) -> Color {
        switch state {
        case "running": success
        case "stopped": danger
        case "pending", "stopping": warning
        case "shutting-down": purple
        default: neutral
        }
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Radii by hierarchy: panel > tile > control.
enum Radius {
    static let panel: CGFloat = 12
    static let tile: CGFloat = 8
}

/// Typography: quiet titles, figures in a light weight with tabular digits; the numbers are the page.
enum Typo {
    static let pageTitle = Font.system(size: 20, weight: .medium)
    static let sectionTitle = Font.system(size: 12, weight: .regular)
    /// Titles of sheets, inspectors and side panels: a step below the page title, never bold or expanded.
    static let panelTitle = Font.system(size: 15, weight: .medium)
    static func figure(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 26, weight: .ultraLight)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.medium))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            actions()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, message: String) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}

struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
            Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = Palette.accent
    var subtitle: String?

    var body: some View {
        // `icon` stays in the API for VoiceOver; the minimal design shows only the figure and its label.
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Typo.figure(28)).foregroundStyle(Self.figureColor(tint))
            Text(title).font(.callout).foregroundStyle(.secondary)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

extension StatCard {
    /// Figures stay in the text color; only a state color (success, warning, danger…) tints them.
    static func figureColor(_ tint: Color) -> Color {
        tint == Palette.accent || tint == Palette.neutral ? .primary : tint
    }
}

struct CardModifier: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: radius))
    }
}

extension View {
    func card(radius: CGFloat = Radius.panel) -> some View { modifier(CardModifier(radius: radius)) }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var copyable = false
    /// Copied as a secret (see `Clipboard`).
    var secret = false

    init(_ label: String, _ value: String, copyable: Bool = false, secret: Bool = false) {
        self.label = label
        self.value = value
        self.copyable = copyable
        self.secret = secret
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if copyable && !value.isEmpty && value != "—" { CopyButton(value: value, secret: secret) }
        }
        .font(.callout)
    }
}

/// Copying to the pasteboard. A secret is marked concealed and transient, so clipboard managers and Universal
/// Clipboard leave it out, and it is cleared after `secretLifetime` unless something else was copied meanwhile.
enum Clipboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let secretLifetime: TimeInterval = 60

    @MainActor
    static func copy(_ value: String, secret: Bool = false, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard secret else {
            pasteboard.setString(value, forType: .string)
            return
        }
        pasteboard.declareTypes([.string, concealedType, transientType], owner: nil)
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: concealedType)
        pasteboard.setString("", forType: transientType)
        let count = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + secretLifetime) { clear(pasteboard, ifStill: count) }
    }

    /// Clears the pasteboard if nothing was copied since `count`.
    @discardableResult
    static func clear(_ pasteboard: NSPasteboard, ifStill count: Int) -> Bool {
        guard pasteboard.changeCount == count else { return false }
        pasteboard.clearContents()
        return true
    }
}

struct CopyButton: View {
    let value: String
    var secret = false
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(value, secret: secret)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(Typo.sectionTitle).foregroundStyle(.secondary).padding(.top, 6)
    }
}

/// Page header with title, subtitle and trailing actions.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.pageTitle)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct LoadingOverlay: View {
    let isLoading: Bool
    var body: some View {
        if isLoading {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial.opacity(0.6))
        }
    }
}

enum Fmt {
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static func dt(_ d: Date?) -> String { d.map { dateTime.string(from: $0) } ?? "—" }
    static let dateTimeSeconds: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()
    /// Date and time to the second, for run history.
    static func dts(_ d: Date?) -> String { d.map { dateTimeSeconds.string(from: $0) } ?? "—" }
    static func day(_ d: Date?) -> String { d.map { date.string(from: $0) } ?? "—" }

    static func money(_ v: Double, _ currency: String = "USD") -> String {
        v.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }
}

/// Writes rows to a CSV file chosen by the user.
enum CSVExport {
    @MainActor
    static func save(name: String, header: [String], rows: [[String]]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func esc(_ s: String) -> String {
            s.contains(where: { ",\"\n".contains($0) }) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
        }
        let text = ([header] + rows).map { $0.map(esc).joined(separator: ",") }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

extension Binding where Value == Bool {
    /// True while the optional holds a value; setting false clears it.
    init<T>(present optional: Binding<T?>) {
        self.init(get: { optional.wrappedValue != nil }, set: { if !$0 { optional.wrappedValue = nil } })
    }
}
