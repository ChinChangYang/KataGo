import Testing
import KataGoGameStore

struct SavedGameWidgetLayoutTests {
    private let allFamilies: [SavedGameWidgetLayout.Family] = [.small, .medium, .large, .extraLarge]

    @Test func defaultPlans_reproduceCurrentPerFamilyLayouts() {
        // These pin EXACTLY the pre-spatial `SavedGameWidgetView` rules so the
        // plan-driven refactor is behaviorally identical at the default (nearby)
        // level of detail, with the "Show Comment" switch at its default ON.
        // small: board + caption name only — never a comment or move count.
        let small = SavedGameWidgetLayout.plan(
            family: .small, isSimplified: false, commentIsEnabled: true,
            hasComment: true, moveCount: 42)
        #expect(!small.isSimplified)
        #expect(!small.showsComment)
        #expect(!small.showsMoveCount)
        #expect(!small.nameIsProminent)

        // medium/large: comment shown iff the displayed move has one; no move count.
        for family in [SavedGameWidgetLayout.Family.medium, .large] {
            let withComment = SavedGameWidgetLayout.plan(
                family: family, isSimplified: false, commentIsEnabled: true,
                hasComment: true, moveCount: 42)
            #expect(withComment.showsComment)
            #expect(!withComment.showsMoveCount)
            let withoutComment = SavedGameWidgetLayout.plan(
                family: family, isSimplified: false, commentIsEnabled: true,
                hasComment: false, moveCount: 42)
            #expect(!withoutComment.showsComment)
        }

        // extraLarge: comment iff non-empty AND "Move N" iff moveCount > 0.
        let xl = SavedGameWidgetLayout.plan(
            family: .extraLarge, isSimplified: false, commentIsEnabled: true,
            hasComment: true, moveCount: 42)
        #expect(xl.showsComment)
        #expect(xl.showsMoveCount)
        let xlEmptyGame = SavedGameWidgetLayout.plan(
            family: .extraLarge, isSimplified: false, commentIsEnabled: true,
            hasComment: false, moveCount: 0)
        #expect(!xlEmptyGame.showsComment)
        #expect(!xlEmptyGame.showsMoveCount)
    }

    @Test func simplifiedPlans_showBoardAndProminentNameOnly() {
        // The visionOS distance threshold: every family collapses to board +
        // large game name. Comment and move count drop out even when present.
        for family in allFamilies {
            let plan = SavedGameWidgetLayout.plan(
                family: family, isSimplified: true, commentIsEnabled: true,
                hasComment: true, moveCount: 42)
            #expect(plan.isSimplified)
            #expect(!plan.showsComment)
            #expect(!plan.showsMoveCount)
            #expect(plan.nameIsProminent)
        }
    }

    @Test func coordinates_areWantedNearbyAndDroppedAtDistance() {
        // Nearby: every family ASKS for coordinates; WidgetBoardView's cell-pitch
        // gate is what actually withholds them on a board too small to draw them
        // without truncating, so the plan must not second-guess it per family.
        for family in allFamilies {
            let nearby = SavedGameWidgetLayout.plan(
                family: family, isSimplified: false, commentIsEnabled: true,
                hasComment: false, moveCount: 0)
            #expect(nearby.showsCoordinates)
            // Across the room a 5-10 pt label is noise on a board-plus-name view.
            let distant = SavedGameWidgetLayout.plan(
                family: family, isSimplified: true, commentIsEnabled: true,
                hasComment: false, moveCount: 0)
            #expect(!distant.showsCoordinates)
        }
    }

    @Test func defaultPlans_neverMarkNameProminent() {
        // Prominent (large-type) naming is exclusively the simplified threshold's
        // treatment; nearby layouts keep their per-family fonts.
        for family in allFamilies {
            let plan = SavedGameWidgetLayout.plan(
                family: family, isSimplified: false, commentIsEnabled: true,
                hasComment: false, moveCount: 0)
            #expect(!plan.nameIsProminent)
        }
    }

    // MARK: - The "Show Comment" switch

    @Test func commentSwitchOff_hidesTheCommentAndTheMoveCountEverywhere() {
        // The headline rule: OFF hides the comment AND the extraLarge "Move N"
        // line, in every family, even for a game that HAS both.
        for family in allFamilies {
            let off = SavedGameWidgetLayout.plan(
                family: family, isSimplified: false, commentIsEnabled: false,
                hasComment: true, moveCount: 42)
            #expect(!off.showsComment)
            #expect(!off.showsMoveCount)
        }
    }

    @Test func commentSwitchOff_expandsOnlyTheWideFamilies() {
        // medium/extraLarge are ~2:1, so their board shares an HStack with the
        // info column and needs the flag to claim the row. small never showed a
        // comment, and large's board is already the only height-flexible child
        // of its VStack — both reclaim nothing and stay laid out as they are.
        for family in [SavedGameWidgetLayout.Family.medium, .extraLarge] {
            let off = SavedGameWidgetLayout.plan(
                family: family, isSimplified: false, commentIsEnabled: false,
                hasComment: true, moveCount: 42)
            #expect(off.boardFillsHeight)
        }
        for family in [SavedGameWidgetLayout.Family.small, .large] {
            let off = SavedGameWidgetLayout.plan(
                family: family, isSimplified: false, commentIsEnabled: false,
                hasComment: true, moveCount: 42)
            #expect(!off.boardFillsHeight)
        }
    }

    @Test func commentSwitchOn_neverExpands_evenWhenTheMoveHasNoComment() {
        // Pins the deliberate decision NOT to relayout on a merely comment-less
        // move: `boardFillsHeight` keys on the SETTING, not on the outcome. If
        // someone later "simplifies" the rule to `!showsComment`, this fails —
        // which is the point, because that would silently move the name beside
        // the board for every uncommented move on medium/extraLarge.
        for family in allFamilies {
            for hasComment in [false, true] {
                let on = SavedGameWidgetLayout.plan(
                    family: family, isSimplified: false, commentIsEnabled: true,
                    hasComment: hasComment, moveCount: 42)
                #expect(!on.boardFillsHeight)
            }
        }
    }

    @Test func commentSwitchOff_isNarrow_keepingCoordinatesAndTheNearbyName() {
        // The switch is a comment veto, not a second distance threshold: the
        // board keeps asking for coordinates (the pitch gate still decides) and
        // the name keeps its per-family font.
        for family in allFamilies {
            let off = SavedGameWidgetLayout.plan(
                family: family, isSimplified: false, commentIsEnabled: false,
                hasComment: true, moveCount: 42)
            #expect(!off.isSimplified)
            #expect(off.showsCoordinates)
            #expect(!off.nameIsProminent)
        }
    }

    @Test func distanceThreshold_isUnaffectedByTheCommentSwitch() {
        // Pins the RULE ORDER: the `isSimplified` early return comes BEFORE the
        // switch is consulted, so the switch can never leak into the
        // prominent-name / no-coordinates distance treatment.
        for family in allFamilies {
            let on = SavedGameWidgetLayout.plan(
                family: family, isSimplified: true, commentIsEnabled: true,
                hasComment: true, moveCount: 42)
            let off = SavedGameWidgetLayout.plan(
                family: family, isSimplified: true, commentIsEnabled: false,
                hasComment: true, moveCount: 42)
            #expect(on == off)
            #expect(on.nameIsProminent)
            #expect(!on.boardFillsHeight)
        }
    }
}
