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

    @Test func panelTitlesSitBelowThePageTitleWithoutBold() {
        #expect(Typo.panelTitle == Font.system(size: 15, weight: .medium))
    }

    @Test func figuresAreLightWithTabularDigits() {
        #expect(Typo.figure(28) == Font.system(size: 28, weight: .light).monospacedDigit())
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
