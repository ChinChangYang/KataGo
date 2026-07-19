import Testing
import KataGoGameStore

struct SavedGameWidgetLayoutTests {
    private let allFamilies: [SavedGameWidgetLayout.Family] = [.small, .medium, .large, .extraLarge]

    @Test func defaultPlans_reproduceCurrentPerFamilyLayouts() {
        // These pin EXACTLY the pre-spatial `SavedGameWidgetView` rules so the
        // plan-driven refactor is behaviorally identical at the default (nearby)
        // level of detail.
        // small: board + caption name only — never a comment or move count.
        let small = SavedGameWidgetLayout.plan(
            family: .small, isSimplified: false, hasComment: true, moveCount: 42)
        #expect(!small.isSimplified)
        #expect(!small.showsComment)
        #expect(!small.showsMoveCount)
        #expect(!small.nameIsProminent)

        // medium/large: comment shown iff the displayed move has one; no move count.
        for family in [SavedGameWidgetLayout.Family.medium, .large] {
            let withComment = SavedGameWidgetLayout.plan(
                family: family, isSimplified: false, hasComment: true, moveCount: 42)
            #expect(withComment.showsComment)
            #expect(!withComment.showsMoveCount)
            let withoutComment = SavedGameWidgetLayout.plan(
                family: family, isSimplified: false, hasComment: false, moveCount: 42)
            #expect(!withoutComment.showsComment)
        }

        // extraLarge: comment iff non-empty AND "Move N" iff moveCount > 0.
        let xl = SavedGameWidgetLayout.plan(
            family: .extraLarge, isSimplified: false, hasComment: true, moveCount: 42)
        #expect(xl.showsComment)
        #expect(xl.showsMoveCount)
        let xlEmptyGame = SavedGameWidgetLayout.plan(
            family: .extraLarge, isSimplified: false, hasComment: false, moveCount: 0)
        #expect(!xlEmptyGame.showsComment)
        #expect(!xlEmptyGame.showsMoveCount)
    }

    @Test func simplifiedPlans_showBoardAndProminentNameOnly() {
        // The visionOS distance threshold: every family collapses to board +
        // large game name. Comment and move count drop out even when present.
        for family in allFamilies {
            let plan = SavedGameWidgetLayout.plan(
                family: family, isSimplified: true, hasComment: true, moveCount: 42)
            #expect(plan.isSimplified)
            #expect(!plan.showsComment)
            #expect(!plan.showsMoveCount)
            #expect(plan.nameIsProminent)
        }
    }

    @Test func defaultPlans_neverMarkNameProminent() {
        // Prominent (large-type) naming is exclusively the simplified threshold's
        // treatment; nearby layouts keep their per-family fonts.
        for family in allFamilies {
            let plan = SavedGameWidgetLayout.plan(
                family: family, isSimplified: false, hasComment: false, moveCount: 0)
            #expect(!plan.nameIsProminent)
        }
    }
}
