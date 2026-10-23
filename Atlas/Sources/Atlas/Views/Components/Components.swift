import SwiftUI
import AppKit

/// Atlas visual identity: cartographic teal + muted state colors, legible in light and dark mode.
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

/// Typography: page titles in Expanded width (map legend), figures in Condensed with tabular digits.
enum Typo {
    static let pageTitle = Font.system(size: 22, weight: .semibold).width(.expanded)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static func figure(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.condensed).monospacedDigit()
    }
}

struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(Palette.accent.opacity(0.7))
            Text(title).font(.title3.weight(.semibold).width(.expanded))
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
        .padding(10)
        .background(Palette.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.tile))
        .overlay(RoundedRectangle(cornerRadius: Radius.tile).strokeBorder(Palette.danger.opacity(0.3)))
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = Palette.accent
    var subtitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(Typo.figure(24))
                Text(title).font(.callout).foregroundStyle(.secondary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(radius: Radius.tile)
    }
}

struct CardModifier: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color(nsColor: .separatorColor).opacity(0.7)))
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
            Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.1), in: Capsule())
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var copyable = false

    init(_ label: String, _ value: String, copyable: Bool = false) {
        self.label = label
        self.value = value
        self.copyable = copyable
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if copyable && !value.isEmpty && value != "—" { CopyButton(value: value) }
        }
        .font(.callout)
    }
}

struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
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
