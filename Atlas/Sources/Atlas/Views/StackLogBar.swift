import SwiftUI
import AppKit

/// The output of the stack's latest run (Init, Plan, Apply, drift, import) in a bar at the bottom of the stack,
/// following the lines as `StacksModel` groups them. It opens when a run starts; it can be closed and resized.
struct StackLogBar: View {
    static let openKey = "stacks.logBar.open"
    static let heightKey = "stacks.logBar.height"
    static let defaultHeight: Double = 200
    static let heightRange: ClosedRange<Double> = 90...640

    let stack: StackEntry
    let isBusy: Bool
    @AppStorage(StackLogBar.openKey) private var isOpen = true
    @AppStorage(StackLogBar.heightKey) private var height = StackLogBar.defaultHeight
    @State private var dragStart: Double?

    /// Dragging the handle up makes the bar taller, within `heightRange`.
    static func resized(from start: Double, draggedBy dy: Double) -> Double {
        min(max(start - dy, heightRange.lowerBound), heightRange.upperBound)
    }

    /// The bar opens when a run starts; when one ends it stays as the user left it.
    static func isOpen(_ open: Bool, afterBusyChange busy: Bool) -> Bool { open || busy }

    static func lines(_ run: StackRun?) -> [IaCModel.Line] {
        guard let run, !run.output.isEmpty else { return [] }
        return run.output.components(separatedBy: "\n").enumerated().map { IaCModel.Line(id: $0.offset, text: $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isOpen { handle }
            header
            if isOpen {
                TerminalPanel(lines: Self.lines(stack.lastRun))
                    .frame(height: Self.resized(from: height, draggedBy: 0))
            }
        }
        .onChange(of: isBusy) { _, busy in isOpen = Self.isOpen(isOpen, afterBusyChange: busy) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { isOpen.toggle() } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.up").frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(isOpen ? "Hide the output" : "Show the output")
            Text("Output").font(.callout.weight(.medium))
            if let run = stack.lastRun {
                Text(run.type.label).font(.callout).foregroundStyle(.secondary)
                Badge(text: run.status.rawValue.capitalized, color: run.status.color)
                Text(Fmt.dt(run.startedAt)).font(.caption).foregroundStyle(.tertiary)
            } else {
                Text("No runs yet").font(.callout).foregroundStyle(.tertiary)
            }
            Spacer()
            if isBusy { ProgressView().controlSize(.mini) }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { isOpen.toggle() }
    }

    /// A thin strip above the bar: drag it to change the bar's height.
    private var handle: some View {
        Divider()
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let start = dragStart ?? height
                    dragStart = start
                    height = Self.resized(from: start, draggedBy: v.translation.height)
                }
                .onEnded { _ in dragStart = nil })
            .help("Drag to resize the output")
    }
}

extension StackRunType {
    var label: String {
        switch self {
        case .importResources: "Import"
        case .initialize: "Init"
        case .fix: "Fix"
        case .plan: "Plan"
        case .apply: "Apply"
        case .fixDrift: "Fix drift"
        case .setup: "Container"
        }
    }
}

extension StackRunStatus {
    var color: Color {
        switch self {
        case .running: Palette.accent
        case .success: Palette.success
        case .failed: Palette.danger
        case .cancelled: Palette.neutral
        }
    }
}
