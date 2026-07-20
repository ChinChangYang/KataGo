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

    @Test func materialBackplatesPutAGobanOnTheMaterial() {
        // The four material backdrops all read as a goban resting on the
        // material: full-bleed texture backplate, the board as its OWN wood
        // card, and a pinned scheme chosen for legibility over that material —
        // ink text over the pale ones (tatami, sky), bright text over the
        // darker ones (grass, slate). The platform glass flag is irrelevant.
        let expectations: [(SavedGameBackground,
                            WidgetBackplateMaterial,
                            WidgetBackgroundPlan.SchemePin)] = [
            (.grass, .grass, .dark),
            (.tatami, .tatami, .light),
            (.slate, .slate, .dark),
            (.sky, .sky, .light),
        ]
        for glassDark in [false, true] {
            for (background, material, pin) in expectations {
                let plan = WidgetBackgroundPlan.resolve(background: background,
                                                        isAccented: false,
                                                        glassPrefersDarkScheme: glassDark)
                #expect(plan.backplate == .material(material))
                #expect(plan.colorSchemePin == pin)
                #expect(plan.boardDrawsOwnWood)
                #expect(plan.textIsInk == (pin == .light))
                #expect(plan.boardStyle == .goban(drawsOwnWood: true))
            }
        }
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
