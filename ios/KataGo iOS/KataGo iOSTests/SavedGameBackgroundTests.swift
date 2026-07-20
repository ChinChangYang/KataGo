import Testing
import KataGoGameStore

struct SavedGameBackgroundTests {
    @Test func rawValuesAreStable() {
        // The raw values are the contract with the widget's AppEnum parameter
        // (SavedGameBackgroundOption shares them) and with any stored intent on
        // a user's device — renaming a case must never change these strings.
        #expect(SavedGameBackground.wood.rawValue == "wood")
        #expect(SavedGameBackground.glass.rawValue == "glass")
        #expect(SavedGameBackground.light.rawValue == "light")
        #expect(SavedGameBackground.dark.rawValue == "dark")
    }

    @Test func defaultIsWood() {
        // The full-bleed goban is the designed default on every platform.
        #expect(SavedGameBackground.default == .wood)
    }

    @Test func resolveFallsBackToTheDefault() {
        // Pre-upgrade widgets have no stored background parameter (nil), and a
        // corrupted or future raw value must degrade the same way: to Wood.
        #expect(SavedGameBackground.resolve(rawValue: nil) == .wood)
        #expect(SavedGameBackground.resolve(rawValue: "") == .wood)
        #expect(SavedGameBackground.resolve(rawValue: "sandstone") == .wood)
        #expect(SavedGameBackground.resolve(rawValue: "Wood") == .wood)
    }

    @Test func resolveRoundTripsEveryCase() {
        for background in SavedGameBackground.allCases {
            #expect(SavedGameBackground.resolve(rawValue: background.rawValue) == background)
        }
    }

    @Test func caseOrderMatchesThePicker() {
        // allCases drives nothing at runtime today, but it documents the Edit
        // Widget picker order: default first, then the pre-redesign glass look.
        #expect(SavedGameBackground.allCases == [.wood, .glass, .light, .dark])
    }
}
