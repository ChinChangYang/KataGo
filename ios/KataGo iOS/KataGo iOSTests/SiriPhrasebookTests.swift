//
//  SiriPhrasebookTests.swift
//  KataGo AnytimeTests
//
//  Pins the SiriPhrasebook catalog — the hand-maintained duplicate of the
//  phrases registered in KataGoShortcuts.swift (App Shortcut phrases are
//  build-time string literals, so no test can read the registration back;
//  editing KataGoShortcuts.swift alone therefore keeps this suite green, and
//  the PAIRED FILE comments carry the discipline in that direction). What
//  the pins buy: changing the catalog is forced to be a deliberate,
//  byte-exact three-way change — registration, catalog, tests — and a
//  shortcut added or removed IS caught at runtime, by the count check.
//  Offline; reads no source files.
//

import Testing
import KataGoUICore
@testable import KataGo_Anytime

struct SiriPhrasebookTests {

    // MARK: - Catalog shape

    @Test func catalogShapeIsPinnedPerPlatform() {
        // iOS: all seven shortcuts, in category order Discover → Open → Listen.
        #expect(SiriPhrasebook.iOS.entries.map(\.id) == [
            "GetGameInfo",
            "GetLatestGameInfo",
            "OpenGame",
            "OpenLatestGame",
            "ListenToGame",
            "ListenToLatestGame",
            "ResumeListening"
        ])
        // Per-shortcut phrase totals (primary + variants), matching the
        // registration in KataGoShortcuts.swift: 30 phrases in all. NOTE:
        // this list is in CATALOG (category) order — read against the
        // registration file the totals run [6, 6, 5, 3, 3, 3, 4], because
        // OpenLatestGame is declared last there, after the Listen block.
        #expect(SiriPhrasebook.iOS.entries.map { 1 + $0.variants.count } ==
                [6, 6, 5, 4, 3, 3, 3])

        // The Mac catalog is the iOS one minus Listen — asserted as VALUE
        // equality with the filtered iOS entries so the two can never drift.
        #expect(SiriPhrasebook.macOS.entries ==
                SiriPhrasebook.iOS.entries.filter { $0.category != .listen })
        #expect(SiriPhrasebook.macOS.entries.count == 4)
        #expect(SiriPhrasebook.macOS.entries.reduce(0) { $0 + 1 + $1.variants.count } == 21)

        // The test target runs on the iOS Simulator only.
        #expect(SiriPhrasebook.current == .iOS)
        #expect(SiriPhrasebook.iOS != SiriPhrasebook.macOS)
    }

    /// The one cross-file check that is runtime-readable: the app registers
    /// exactly as many App Shortcuts as the phrasebook teaches. (The phrases
    /// themselves are not readable — that is the whole reason the catalog
    /// exists.)
    @MainActor
    @Test func registeredShortcutCountMatchesTheCatalog() {
        #expect(KataGoShortcuts.appShortcuts.count ==
                SiriPhrasebook.current.entries.count)
    }

    // MARK: - Phrase invariants

    @Test func everyPhraseNamesTheApp() {
        for book in [SiriPhrasebook.iOS, SiriPhrasebook.macOS] {
            for entry in book.entries {
                for phrase in [entry.primary] + entry.variants {
                    #expect(phrase.contains("KataGo Anytime"),
                            "\(entry.id): \(phrase)")
                }
            }
        }
    }

    @Test func categoriesGroupDiscoverOpenListen() {
        let categoryByID = Dictionary(uniqueKeysWithValues:
            SiriPhrasebook.iOS.entries.map { ($0.id, $0.category) })
        #expect(categoryByID == [
            "GetGameInfo": .discover,
            "GetLatestGameInfo": .discover,
            "OpenGame": .open,
            "OpenLatestGame": .open,
            "ListenToGame": .listen,
            "ListenToLatestGame": .listen,
            "ResumeListening": .listen
        ])
        #expect(SiriPhrasebook.iOS.categories == [.discover, .open, .listen])
        #expect(SiriPhrasebook.macOS.categories == [.discover, .open])
        #expect(SiriPhrasebook.iOS.entries(in: .listen).count == 3)
        #expect(SiriPhrasebook.macOS.entries(in: .listen).isEmpty)
    }

    // MARK: - Parameterization

    @Test func parameterizedPhrasesSubstituteTheGameName() {
        let parameterized = SiriPhrasebook.iOS.entries.filter(\.isParameterized)
        #expect(parameterized.map(\.id) == ["GetGameInfo", "OpenGame", "ListenToGame"])

        for entry in SiriPhrasebook.iOS.entries {
            for template in [entry.primary] + entry.variants {
                #expect(template.contains(SiriPhrasebook.gameSlot) == entry.isParameterized,
                        "\(entry.id): \(template)")
            }
            let rendered = [entry.spokenPrimary(game: "Ear-Reddening Game")]
                + entry.spokenVariants(game: "Ear-Reddening Game")
            for phrase in rendered {
                #expect(!phrase.contains(SiriPhrasebook.gameSlot), "\(entry.id): \(phrase)")
                #expect(phrase.contains("Ear-Reddening Game") == entry.isParameterized,
                        "\(entry.id): \(phrase)")
            }
        }
    }

    /// Every one of the 30 templates, byte for byte — primary first, then the
    /// variants in declared order. The most realistic drift is a variant
    /// mirrored wrongly (or reordered) while every count stays intact, which
    /// only a verbatim pin catches.
    @Test func allPhrasesArePinnedVerbatim() {
        let phrasesByID = Dictionary(uniqueKeysWithValues:
            SiriPhrasebook.iOS.entries.map { ($0.id, [$0.primary] + $0.variants) })
        #expect(phrasesByID == [
            "GetGameInfo": [
                "Get ‹game› information with KataGo Anytime",
                "Get information on ‹game› with KataGo Anytime",
                "Show ‹game› details using KataGo Anytime",
                "Find out about ‹game› with KataGo Anytime",
                "Check ‹game› info using KataGo Anytime",
                "Tell me about ‹game› with KataGo Anytime"
            ],
            "GetLatestGameInfo": [
                "Get the latest go game information with KataGo Anytime",
                "Get information on the latest go game with KataGo Anytime",
                "Show the most recent go game details with KataGo Anytime",
                "Find the latest go game info using KataGo Anytime",
                "What's the latest go game with KataGo Anytime?",
                "Tell me the latest go game info with KataGo Anytime"
            ],
            "OpenGame": [
                "Open ‹game› with KataGo Anytime",
                "Open ‹game› in KataGo Anytime",
                "Show ‹game› in KataGo Anytime",
                "Open the game ‹game› with KataGo Anytime",
                "Continue ‹game› with KataGo Anytime"
            ],
            "OpenLatestGame": [
                "Open the latest go game with KataGo Anytime",
                "Open my latest go game in KataGo Anytime",
                "Continue the latest go game with KataGo Anytime",
                "Resume my go game with KataGo Anytime"
            ],
            "ListenToGame": [
                "Listen to ‹game› with KataGo Anytime",
                "Play ‹game› aloud with KataGo Anytime",
                "Narrate ‹game› with KataGo Anytime"
            ],
            "ListenToLatestGame": [
                "Listen to the latest go game with KataGo Anytime",
                "Listen to my latest go game with KataGo Anytime",
                "Narrate my latest go game with KataGo Anytime"
            ],
            "ResumeListening": [
                "Resume listening with KataGo Anytime",
                "Keep listening with KataGo Anytime",
                "Continue my go game narration with KataGo Anytime"
            ]
        ])
    }

    // MARK: - Example game name

    @Test func exampleNameFallsBackToTheDefaultGameName() {
        #expect(SiriPhrasebook.exampleGameName(from: nil) == GameRecord.defaultName)
        #expect(SiriPhrasebook.exampleGameName(from: "") == GameRecord.defaultName)
        #expect(SiriPhrasebook.exampleGameName(from: "  \n") == GameRecord.defaultName)
        #expect(SiriPhrasebook.exampleGameName(from: " Kifu 42 ") == "Kifu 42")
    }
}
