import Testing
import KataGoGameStore

struct SavedGameBackgroundTests {
    @Test func rawValuesAreStable() {
        // The raw values are the contract with the widget's stored intent
        // parameter AND the strings the Edit sheet displays for a
        // never-configured widget (the sheet shows the raw value until the
        // user picks from the options list) — so they are the capitalized
        // display names, and renaming a case must never change them.
        #expect(SavedGameBackground.wood.rawValue == "Wood")
        #expect(SavedGameBackground.glass.rawValue == "Glass")
        #expect(SavedGameBackground.light.rawValue == "Light")
        #expect(SavedGameBackground.dark.rawValue == "Dark")
    }

    @Test func defaultIsWood() {
        // The full-bleed goban is the designed default on every platform.
        #expect(SavedGameBackground.default == .wood)
    }

    @Test func resolveFallsBackToTheDefault() {
        // Pre-upgrade widgets have no stored background parameter (nil), and a
        // corrupted, case-mismatched, or future raw value must degrade the
        // same way: to Wood.
        #expect(SavedGameBackground.resolve(rawValue: nil) == .wood)
        #expect(SavedGameBackground.resolve(rawValue: "") == .wood)
        #expect(SavedGameBackground.resolve(rawValue: "sandstone") == .wood)
        #expect(SavedGameBackground.resolve(rawValue: "WOOD") == .wood)
        #expect(SavedGameBackground.resolve(rawValue: "glass") == .wood)
    }

    @Test func resolveRoundTripsEveryCase() {
        for background in SavedGameBackground.allCases {
            #expect(SavedGameBackground.resolve(rawValue: background.rawValue) == background)
        }
    }

    @Test func caseOrderMatchesThePicker() {
        // allCases drives the Edit Widget picker order: default first, then
        // the pre-redesign glass look.
        #expect(SavedGameBackground.allCases == [.wood, .glass, .light, .dark])
    }

    @Test func displayNamesAreTheHumanPickerTitles() {
        // The Background options provider shows these in the Edit Widget
        // picker (the raw values stay lowercase persistence keys).
        #expect(SavedGameBackground.wood.displayName == "Wood")
        #expect(SavedGameBackground.glass.displayName == "Glass")
        #expect(SavedGameBackground.light.displayName == "Light")
        #expect(SavedGameBackground.dark.displayName == "Dark")
    }
}
