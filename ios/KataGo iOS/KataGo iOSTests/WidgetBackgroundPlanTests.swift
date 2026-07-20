import Testing
import KataGoGameStore

struct WidgetBackgroundPlanTests {
    @Test func accentedIgnoresEveryBackground() {
        // Tint wins: while the system renders the widget accented, the user's
        // background choice is set aside entirely — neutral backplate, the
        // two-tone accent board, no full-bleed wood, bright (non-ink) text.
        for background in SavedGameBackground.allCases {
            let plan = WidgetBackgroundPlan.resolve(background: background,
                                                    isAccented: true,
                                                    glassPrefersDarkScheme: false)
            #expect(plan.backplate == .neutralAccent)
            #expect(plan.colorSchemePin == nil)
            #expect(!plan.boardDrawsOwnWood)
            #expect(!plan.textIsInk)
            #expect(plan.boardStyle == .accented)
        }
    }

    @Test func accentedPinsDarkWhereGlassIsDark() {
        // On visionOS the accented widget still composites over dark glass, so
        // the pre-redesign dark-scheme pin must survive there (and only there).
        for background in SavedGameBackground.allCases {
            let plan = WidgetBackgroundPlan.resolve(background: background,
                                                    isAccented: true,
                                                    glassPrefersDarkScheme: true)
            #expect(plan.backplate == .neutralAccent)
            #expect(plan.colorSchemePin == .dark)
            #expect(plan.boardStyle == .accented)
        }
    }

    @Test func woodIsTheFullBleedGoban() {
        // Wood makes the whole widget one goban: the backplate carries the wood,
        // the board draws NO wood card of its own (no seam by construction),
        // and text is dark ink regardless of platform or system dark mode.
        for glassDark in [false, true] {
            let plan = WidgetBackgroundPlan.resolve(background: .wood,
                                                    isAccented: false,
                                                    glassPrefersDarkScheme: glassDark)
            #expect(plan.backplate == .wood)
            #expect(plan.colorSchemePin == .light)
            #expect(!plan.boardDrawsOwnWood)
            #expect(plan.textIsInk)
            #expect(plan.boardStyle == .goban(drawsOwnWood: false))
        }
    }

    @Test func glassReproducesThePreRedesignLook() {
        // Glass is the shipped look: translucent system backplate, the board as
        // its own wood card, and the visionOS-only dark pin (commit 340df0cd —
        // content over dark glass with a light inherited scheme rendered
        // black-on-black). Elsewhere the scheme stays adaptive (no pin).
        let vision = WidgetBackgroundPlan.resolve(background: .glass,
                                                  isAccented: false,
                                                  glassPrefersDarkScheme: true)
        #expect(vision.backplate == .glass)
        #expect(vision.colorSchemePin == .dark)
        #expect(vision.boardDrawsOwnWood)
        #expect(!vision.textIsInk)
        #expect(vision.boardStyle == .goban(drawsOwnWood: true))

        let phone = WidgetBackgroundPlan.resolve(background: .glass,
                                                 isAccented: false,
                                                 glassPrefersDarkScheme: false)
        #expect(phone.backplate == .glass)
        #expect(phone.colorSchemePin == nil)
        #expect(phone.boardDrawsOwnWood)
    }

    @Test func lightAndDarkPinTheirSchemes() {
        // The neutral choices pin the scheme on every platform so the text
        // contrast is deterministic: ink on Light, bright on Dark.
        for glassDark in [false, true] {
            let light = WidgetBackgroundPlan.resolve(background: .light,
                                                     isAccented: false,
                                                     glassPrefersDarkScheme: glassDark)
            #expect(light.backplate == .light)
            #expect(light.colorSchemePin == .light)
            #expect(light.boardDrawsOwnWood)
            #expect(light.textIsInk)
            #expect(light.boardStyle == .goban(drawsOwnWood: true))

            let dark = WidgetBackgroundPlan.resolve(background: .dark,
                                                    isAccented: false,
                                                    glassPrefersDarkScheme: glassDark)
            #expect(dark.backplate == .dark)
            #expect(dark.colorSchemePin == .dark)
            #expect(dark.boardDrawsOwnWood)
            #expect(!dark.textIsInk)
            #expect(dark.boardStyle == .goban(drawsOwnWood: true))
        }
    }
}
