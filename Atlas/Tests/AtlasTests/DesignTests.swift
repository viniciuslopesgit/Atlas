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

    @Test func figuresAreLightWithTabularDigits() {
        #expect(Typo.figure(28) == Font.system(size: 28, weight: .light).monospacedDigit())
    }
}

struct SidebarTests {
    @Test func sidebarHasThreeFixedMenusAndOnlyResourcesHasASubmenu() {
        #expect(SidebarMenu.allCases.map(\.title) == ["Dashboard", "Resources", "Stacks"])
        #expect(SidebarMenu.allCases.filter(\.hasSubmenu) == [.resources])
        #expect(SidebarMenu.resources.pages == [.ec2, .s3, .iam, .cloudWatch, .guardDuty, .securityAudit, .billing, .iac])
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
