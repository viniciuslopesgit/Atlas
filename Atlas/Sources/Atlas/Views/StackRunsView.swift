import SwiftUI
import AppKit

/// Which runs a stack tab lists.
enum StackRunScope: String, CaseIterable, Identifiable {
    case all = "Runs", plans = "Plans", applies = "Applies"
    var id: String { rawValue }

    func includes(_ run: StackRun) -> Bool {
        switch self {
        case .all: true
        case .plans: run.type == .plan
        case .applies: run.type == .apply || run.type == .fixDrift
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Init, Plan, Apply, drift checks and imports are recorded here, with their output."
        case .plans: "Plans and drift checks are recorded here, with their output."
        case .applies: "Applies and drift fixes are recorded here, with their output."
        }
    }
}

extension StackRunStatus {
    var label: String {
        switch self {
        case .running: "Running"
        case .success: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
    var icon: String {
        switch self {
        case .running: "play.circle.fill"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }
}

/// A stack's runs of one scope, newest first; selecting one opens its timeline.
struct StackRunList: View {
    let runs: [StackRun]
    let scope: StackRunScope
    let onOpen: (UUID) -> Void

    var body: some View {
        let shown = runs.filter(scope.includes)
        if shown.isEmpty {
            EmptyStateView(icon: "clock", title: "No \(scope.rawValue.lowercased()) yet", message: scope.emptyMessage)
        } else {
            List(shown) { run in
                Button { onOpen(run.id) } label: { StackRunRow(run: run) }
                    .buttonStyle(.plain)
            }
        }
    }
}

private struct StackRunRow: View {
    let run: StackRun

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.status.icon).font(.system(size: 18)).foregroundStyle(run.status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.type.label).font(.body.weight(.medium))
                Text(run.trigger).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.dts(run.startedAt)).font(.callout.monospacedDigit())
                RunClock(start: run.startedAt, end: run.completedAt).font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Elapsed time, ticking while the run or phase is going.
struct RunClock: View {
    let start: Date
    let end: Date?

    var body: some View {
        if let end {
            Text(StackRun.clock(end.timeIntervalSince(start))).monospacedDigit()
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(StackRun.clock(ctx.date.timeIntervalSince(start))).monospacedDigit()
            }
        }
    }
}

/// One run as a timeline of its phases, newest on top, each with its time and collapsible output.
struct StackRunDetail: View {
    let run: StackRun
    let stackName: String
    let onBack: () -> Void
    @State private var expanded: Set<Int> = []
    @State private var fullScreen: Int?

    /// Opened at first: the newest phase and any that failed.
    static func initiallyExpanded(_ run: StackRun) -> Set<Int> {
        let phases = run.timeline.map(\.phase)
        var open = Set(phases.indices.filter { phases[$0].status == .failed })
        if !phases.isEmpty { open.insert(phases.count - 1) }
        return open
    }

    var body: some View {
        let timeline = run.timeline
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onBack) { Label("All runs", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Button { LogExport.save(run, stackName: stackName) } label: { Label("Download Logs…", systemImage: "arrow.down.circle") }
                    .disabled(run.output.isEmpty)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(run.type.label).font(Typo.panelTitle)
                Badge(text: run.status.label, color: run.status.color)
                Text("\(run.trigger) · started \(Fmt.dts(run.startedAt))").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                RunClock(start: run.startedAt, end: run.completedAt).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let end = run.completedAt {
                        TimelineNode(icon: run.status.icon, color: run.status.color, title: run.status.label,
                                     detail: Fmt.dts(end), isLast: timeline.isEmpty) { EmptyView() }
                    }
                    ForEach(timeline.indices.reversed(), id: \.self) { i in
                        phaseNode(timeline[i], index: i, isLast: i == 0)
                    }
                }
                .padding(.top, 4)
            }
        }
        .onAppear { expanded = Self.initiallyExpanded(run) }
        .onChange(of: run.phases.count) { _, count in if count > 0 { expanded.insert(count - 1) } }
        .sheet(isPresented: Binding(present: $fullScreen)) {
            if let i = fullScreen, i < timeline.count {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(run.type.label) · \(timeline[i].phase.name)").font(Typo.panelTitle)
                        Spacer()
                        Button("Done") { fullScreen = nil }.keyboardShortcut(.defaultAction)
                    }
                    TerminalPanel(lines: Self.lines(timeline[i].output))
                }
                .padding(20)
                .frame(minWidth: 900, minHeight: 620)
            }
        }
    }

    private func phaseNode(_ item: (phase: StackRunPhase, output: String), index: Int, isLast: Bool) -> some View {
        let phase = item.phase
        let open = expanded.contains(index)
        return TimelineNode(icon: phase.status.icon, color: phase.status.color, title: phase.name, isLast: isLast,
                            clock: (phase.startedAt, phase.completedAt), detail: Fmt.dts(phase.startedAt),
                            chevron: open ? "chevron.down" : "chevron.right",
                            onToggle: { if open { expanded.remove(index) } else { expanded.insert(index) } }) {
            if open {
                let lines = Self.lines(item.output)
                TerminalPanel(lines: lines)
                    .frame(height: min(max(CGFloat(lines.count) * 15 + 24, 70), 380))
                    .overlay(alignment: .topTrailing) {
                        Button { fullScreen = index } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .buttonStyle(.borderless).padding(8).help("Show the whole output")
                    }
            }
        }
    }

    static func lines(_ text: String) -> [IaCModel.Line] {
        text.isEmpty ? [] : text.components(separatedBy: "\n").enumerated().map { IaCModel.Line(id: $0.offset, text: $0.element) }
    }
}

/// A status icon on a vertical line, a title row and what goes under it.
private struct TimelineNode<Content: View>: View {
    let icon: String
    let color: Color
    let title: String
    var isLast = false
    var clock: (Date, Date?)?
    var detail: String
    var chevron: String?
    var onToggle: (() -> Void)?
    @ViewBuilder var content: Content

    init(icon: String, color: Color, title: String, detail: String, isLast: Bool, @ViewBuilder content: () -> Content) {
        self.icon = icon; self.color = color; self.title = title; self.detail = detail; self.isLast = isLast
        self.content = content()
    }

    init(icon: String, color: Color, title: String, isLast: Bool, clock: (Date, Date?), detail: String, chevron: String,
         onToggle: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.icon = icon; self.color = color; self.title = title; self.isLast = isLast; self.clock = clock
        self.detail = detail; self.chevron = chevron; self.onToggle = onToggle; self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(color).frame(width: 24, height: 24)
                if !isLast { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Button { onToggle?() } label: {
                    HStack(spacing: 6) {
                        if let chevron { Image(systemName: chevron).font(.caption).foregroundStyle(.secondary).frame(width: 12) }
                        Text(title).font(.callout.weight(.medium))
                        if let clock {
                            Text("·").foregroundStyle(.tertiary)
                            RunClock(start: clock.0, end: clock.1).foregroundStyle(.secondary)
                        }
                        Text("·").foregroundStyle(.tertiary)
                        Text(detail).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onToggle == nil)
                content
            }
            .padding(.bottom, 16)
        }
    }
}

/// Saves a run's whole output to a text file the user chooses.
enum LogExport {
    static func fileName(_ run: StackRun, stackName: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let safe = stackName.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        return "\(String(safe))-\(run.type.rawValue)-\(f.string(from: run.startedAt)).log"
    }

    @MainActor
    static func save(_ run: StackRun, stackName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(run, stackName: stackName)
        panel.allowedContentTypes = [.log, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? run.output.write(to: url, atomically: true, encoding: .utf8)
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
