import SwiftUI
import Testing
@testable import Atlas

struct DesignTests {
    @Test func statFiguresUseTextColorUnlessTheyCarryAState() {
        #expect(StatCard.figureColor(Palette.accent) == .primary)
        #expect(StatCard.figureColor(Palette.neutral) == .primary)
        #expect(StatCard.figureColor(Palette.danger) == Palette.danger)
        #expect(StatCard.figureColor(Palette.success) == Palette.success)
    }

    /// The old look, by pattern: bold or expanded titles, hard-coded radii and colors, filled selection pills.
    @Test func viewsUseTheMinimalDesignTokens() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Atlas/Views").standardizedFileURL
        let banned = [#"\.width\(\.expanded\)"#, #"\.(semibold|bold|heavy)\b"#, #"\.font\(\.(headline|title2?|largeTitle)\)"#,
                      #"cornerRadius: [0-9]"#, #"Color\((red|white):"#, #"\.foregroundColor\(\.(blue|red|green|orange)"#,
                      #"in: Capsule\(\)"#]
        let files = try #require(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 10)
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (n, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for pattern in banned where line.range(of: pattern, options: .regularExpression) != nil {
                    Issue.record("\(file.lastPathComponent):\(n + 1) uses the old look (\(pattern)): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    // Fonts are compared by what they are made of: two equal Fonts are not == on macOS 14 and 15.
    @Test func panelTitlesSitBelowThePageTitleWithoutBold() {
        #expect(Typo.panelTitleStyle.size == 15 && Typo.panelTitleStyle.weight == .medium)
    }

    @Test func figuresAreLight() {
        #expect(Typo.figureWeight == .light)
    }
}

struct SidebarTests {
    @Test func sidebarHasFourFixedMenusAndOnlyResourcesHasASubmenu() {
        #expect(SidebarMenu.allCases.map(\.title) == ["Dashboard", "Resources", "Stacks", "Infrastructure as Code"])
        #expect(SidebarMenu.allCases.filter(\.hasSubmenu) == [.resources])
        #expect(SidebarMenu.resources.pages == [.ec2, .s3, .iam, .cloudWatch, .guardDuty, .securityAudit, .billing])
        #expect(Page.iac.menu == .iac, "Infrastructure as Code is its own menu, below Stacks")
    }

    @Test func everyPageIsInOneMenuExceptTheFooterPages() {
        let listed = SidebarMenu.allCases.flatMap(\.pages)
        #expect(Set(listed).count == listed.count)
        #expect(Set(listed).union([.settings, .feedback]) == Set(Page.allCases))
        #expect(Page.settings.menu == nil && Page.feedback.menu == nil)
    }

    @Test @MainActor func resourcesReopensOnTheLastResourcePage() {
        let folder = TestTemp.root.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(store: AccountStore(folder: folder), secrets: InMemorySecretStore())
        state.open(.resources)
        #expect(state.page == .ec2)
        state.page = .billing
        state.open(.dashboard)
        #expect(state.page == .dashboard)
        state.open(.resources)
        #expect(state.page == .billing)
        state.open(.resources)
        #expect(state.page == .billing, "opening the current menu keeps its page")
    }
}

/// The Stacks figures are the filter: each counts exactly the stacks it shows, and the sidebar counts what needs attention.
struct StackFilterTests {
    @Test @MainActor func eachFigureCountsTheStacksItShows() throws {
        func stack(_ status: StackStatus, _ drift: DriftStatus = .unknown, acknowledged: Bool = false) -> StackEntry {
            var s = StackEntry(name: "s", projectPath: "/tmp/s", accountId: "a", region: "eu-west-1")
            s.status = status; s.driftStatus = drift; s.driftAcknowledged = acknowledged
            return s
        }
        let ready = stack(.finished), drifted = stack(.finished, .drifted), known = stack(.finished, .drifted, acknowledged: true)
        let failed = stack(.failed), checkFailed = stack(.finished, .error), running = stack(.running)
        let all = [ready, drifted, known, failed, checkFailed, running]
        let busy: Set<UUID> = [running.id]
        func shown(_ f: StacksView.Filter) -> [UUID] { all.filter { f.includes($0, busy: busy) }.map(\.id) }
        #expect(shown(.ready) == [ready.id, known.id], "acknowledged drift is ready")
        #expect(shown(.drifted) == [drifted.id])
        #expect(shown(.failed) == [failed.id, checkFailed.id])
        #expect(shown(.running) == [running.id])
        #expect(SidebarMenu.allCases.allSatisfy { !$0.icon.isEmpty })

        let folder = TestTemp.root.appendingPathComponent("attention-\(UUID().uuidString)")
        let model = StacksModel(store: StackStore(folder: folder, secrets: InMemorySecretStore()), clientFor: { _ in nil })
        #expect(model.needingAttention == 0)
    }

    @Test @MainActor func refreshShowsAPageLoadingEvenWithCachedData() async throws {
        let folder = TestTemp.root.appendingPathComponent("loading-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(store: AccountStore(folder: folder), secrets: InMemorySecretStore())
        var during = -1
        try await state.cached("x", show: { (_: Int) in }) { during = state.loading; return 1 }
        #expect(during == 1 && state.loading == 0)
    }
}
