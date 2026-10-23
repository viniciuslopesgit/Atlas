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
    @Test func onlyIaCHasAHeader() {
        #expect(SidebarMenu.allCases.map(\.header) == [nil, nil, "IaC"])
    }

    @Test func stacksFollowsDashboardAndBillingIsAResource() {
        #expect(SidebarMenu.dashboard.pages == [.dashboard, .stacks])
        #expect(SidebarMenu.resources.pages.last == .billing)
        #expect(SidebarMenu.iac.pages == [.iac])
    }

    @Test func everyPageIsInOneMenuExceptTheFooterPages() {
        let listed = SidebarMenu.allCases.flatMap(\.pages)
        #expect(Set(listed).count == listed.count)
        #expect(Set(listed).union([.settings, .feedback]) == Set(Page.allCases))
        #expect(Page.settings.menu == nil && Page.feedback.menu == nil)
    }
}
