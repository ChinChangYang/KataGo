import Testing
import KataGoGameStore

struct SavedGameBackgroundTests {
    @Test func rawValuesAreStable() {
        // The raw values are the contract with the widget's stored intent
        // parameter AND the strings the Edit sheet displays for a
        // never-configured widget (the sheet shows the raw value until the
        // user picks from the options list) — so they are the capitalized
        // display names, and renaming a case must never change them.
        #expect(SavedGameBackground.light.rawValue == "Light")
        #expect(SavedGameBackground.dark.rawValue == "Dark")
        #expect(SavedGameBackground.wood.rawValue == "Wood")
        #expect(SavedGameBackground.grass.rawValue == "Grass")
        #expect(SavedGameBackground.tatami.rawValue == "Tatami")
        #expect(SavedGameBackground.slate.rawValue == "Slate")
        #expect(SavedGameBackground.sky.rawValue == "Sky")
    }

    @Test func defaultIsLight() {
        // The neutral light backplate is the designed default on every platform.
        #expect(SavedGameBackground.default == .light)
    }

    @Test func resolveFallsBackToTheDefault() {
        // Pre-upgrade widgets have no stored background parameter (nil), and a
        // corrupted, case-mismatched, or future raw value must degrade the
        // same way: to Light. "Glass" is the concrete dropped-case instance —
        // a widget configured before the option was retired must degrade too,
        // never fail.
        #expect(SavedGameBackground.resolve(rawValue: nil) == .light)
        #expect(SavedGameBackground.resolve(rawValue: "") == .light)
        #expect(SavedGameBackground.resolve(rawValue: "sandstone") == .light)
        #expect(SavedGameBackground.resolve(rawValue: "WOOD") == .light)
        #expect(SavedGameBackground.resolve(rawValue: "Glass") == .light)
        #expect(SavedGameBackground.resolve(rawValue: "glass") == .light)
    }

    @Test func resolveRoundTripsEveryCase() {
        for background in SavedGameBackground.allCases {
            #expect(SavedGameBackground.resolve(rawValue: background.rawValue) == background)
        }
    }

    @Test func caseOrderMatchesThePicker() {
        // allCases drives the Edit Widget picker order: the neutral defaults
        // first, then the goban wood, then the four material backdrops.
        #expect(SavedGameBackground.allCases == [.light, .dark, .wood,
                                                 .grass, .tatami, .slate, .sky])
    }

    @Test func displayNamesAreTheHumanPickerTitles() {
        // The Background options provider shows these in the Edit Widget
        // picker; identical to the raw values by design (see the type comment).
        for background in SavedGameBackground.allCases {
            #expect(background.displayName == background.rawValue)
        }
        #expect(SavedGameBackground.tatami.displayName == "Tatami")
    }
}
