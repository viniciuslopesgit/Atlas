import SwiftUI

// Atlas runs from macOS 12. What SwiftUI only has from macOS 13 or 14 goes through these, with the closest
// macOS 12 equivalent: the newer API wherever it exists, so nothing changes there.

enum OS {
    /// Swift Charts, Grid, Layout, NavigationSplitView, grouped forms, continuous hover and located taps.
    static var hasMacOS13: Bool { if #available(macOS 13, *) { true } else { false } }
    /// Inspectors and key presses.
    static var hasMacOS14: Bool { if #available(macOS 14, *) { true } else { false } }
}

extension View {
    /// `.formStyle(.grouped)` from macOS 13; the default form before.
    @ViewBuilder func groupedForm() -> some View {
        if #available(macOS 13, *) { formStyle(.grouped) } else { self }
    }

    /// `.formStyle(.columns)` from macOS 13; the default form (already in columns on macOS) before.
    @ViewBuilder func columnsForm() -> some View {
        if #available(macOS 13, *) { formStyle(.columns) } else { self }
    }

    /// A trailing inspector column: `.inspector` from macOS 14, a fixed-width column at the side before.
    @ViewBuilder func sideInspector<Content: View>(isPresented: Bool, min: CGFloat, ideal: CGFloat, max: CGFloat? = nil,
                                                   @ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 14, *) {
            inspector(isPresented: .constant(isPresented)) { content().inspectorColumnWidth(min: min, ideal: ideal, max: max) }
        } else {
            HStack(spacing: 0) {
                self.frame(maxWidth: .infinity, maxHeight: .infinity)
                if isPresented {
                    Divider()
                    content().frame(width: ideal).frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    /// A table's context menu for its selected rows and its double-click action, from macOS 13. Tables have neither
    /// on macOS 12: there the same menu and action are buttons under the table while rows are selected.
    @ViewBuilder func selectionContextMenu<ID: Hashable, MenuContent: View>(
        selection: Set<ID>, @ViewBuilder menu: @escaping (Set<ID>) -> MenuContent,
        primaryAction: ((Set<ID>) -> Void)? = nil) -> some View {
        if #available(macOS 13, *) {
            contextMenu(forSelectionType: ID.self, menu: menu, primaryAction: primaryAction)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                self
                if !selection.isEmpty {
                    HStack {
                        if let primaryAction { Button("Open") { primaryAction(selection) } }
                        Menu("Actions") { menu(selection) }.fixedSize()
                        Spacer()
                    }
                }
            }
        }
    }

    /// Hides a scrolling view's own background, from macOS 13.
    @ViewBuilder func hiddenScrollBackground() -> some View {
        if #available(macOS 13, *) { scrollContentBackground(.hidden) } else { self }
    }

    /// No focus ring, from macOS 14.
    @ViewBuilder func noFocusEffect() -> some View {
        if #available(macOS 14, *) { focusEffectDisabled() } else { self }
    }

    /// The pointer's location over the view (nil when it leaves), from macOS 13. Before, the caller follows
    /// AppKit's mouse-moved events instead.
    @ViewBuilder func onPointer(_ action: @escaping (CGPoint?) -> Void) -> some View {
        if #available(macOS 13, *) {
            onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let p) = phase { action(p) } else { action(nil) }
            }
        } else {
            self
        }
    }

    /// A single click and where it was, from macOS 13. Before, the caller follows AppKit's mouse-up events instead.
    @ViewBuilder func onClick(_ action: @escaping (CGPoint) -> Void) -> some View {
        if #available(macOS 13, *) { onTapGesture(count: 1, coordinateSpace: .local, perform: action) } else { self }
    }

    /// The arrow keys, Return and Escape while the view has focus, from macOS 14. Before, the caller follows
    /// AppKit's key-down events instead. `action` returns whether it used the key.
    @ViewBuilder func onNavigationKey(_ action: @escaping (NavigationKey) -> Bool) -> some View {
        if #available(macOS 14, *) {
            onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape]) { press in
                guard let key = NavigationKey(press.key) else { return .ignored }
                return action(key) ? .handled : .ignored
            }
        } else {
            self
        }
    }
}

/// The keys that move around a diagram (KeyEquivalent is only Equatable from macOS 14).
enum NavigationKey: Equatable {
    case left, right, up, down, enter, escape

    init?(_ key: KeyEquivalent) {
        let all: [(KeyEquivalent, NavigationKey)] = [(.leftArrow, .left), (.rightArrow, .right), (.upArrow, .up),
                                                     (.downArrow, .down), (.return, .enter), (.escape, .escape)]
        guard let match = all.first(where: { $0.0.character == key.character }) else { return nil }
        self = match.1
    }

    /// The key of an AppKit key-down event, or nil.
    init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .left
        case 124: self = .right
        case 125: self = .down
        case 126: self = .up
        case 36, 76: self = .enter
        case 53: self = .escape
        default: return nil
        }
    }
}

/// A form row with a label: `LabeledContent` from macOS 13, the label beside its content before.
struct LabeledRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if #available(macOS 13, *) {
            LabeledContent(title) { content }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 12)
                content
            }
        }
    }
}

extension LabeledRow where Content == Text {
    init(_ title: String, value: String) {
        self.init(title) { Text(value).foregroundColor(.secondary) }
    }
}

/// A line of `points` drawn without Swift Charts (macOS 12), scaled to fill the frame.
struct SparklineShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, let lo = values.min(), let hi = values.max() else { return path }
        let span = hi > lo ? hi - lo : 1
        for (i, v) in values.enumerated() {
            let p = CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1),
                            y: rect.maxY - rect.height * CGFloat((v - lo) / span))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// Where a chart would be on macOS 12, which has no Swift Charts.
struct ChartUnavailable: View {
    var body: some View {
        Text("Charts need macOS 13 or later.")
            .font(.callout).foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
