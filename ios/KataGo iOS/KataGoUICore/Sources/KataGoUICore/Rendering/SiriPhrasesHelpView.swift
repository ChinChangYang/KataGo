//
//  SiriPhrasesHelpView.swift
//  KataGoUICore
//
//  What Siri accepts is registered at build time: App Shortcut phrases must be
//  string LITERALS in KataGoShortcuts.swift (the AppIntents metadata processor
//  extracts them during the build), so no screen can read them back at
//  runtime. This catalog therefore duplicates those phrases by hand.
//
//  PAIRED FILE: KataGo iOS/AppIntents/KataGoShortcuts.swift is the source of
//  truth. Change a phrase there → change it here AND in SiriPhrasebookTests,
//  which pins every phrase verbatim. Nothing can read the registration back,
//  so no test fails on a registration-side edit alone — these comments are
//  the guard in that direction; the pins force the catalog side to be a
//  deliberate, byte-exact change.
//
//  Shared like VoiceControlHelpView: one view in the package, pushed by iOS
//  (Global Settings ▸ Siri) and hosted by macOS (Settings ▸ Siri tab). The
//  Mac registers every shortcut except the three Listen ones; tvOS and
//  visionOS register no App Shortcuts at all (KataGoShortcuts.swift compiles
//  only into the iOS and Mac targets), so neither mounts this.
//

import SwiftUI
import AppIntents
import KataGoGameStore

/// The spoken phrases this app's App Shortcuts answer to, per platform. The
/// Mac registers no Listen shortcuts, so its catalog is the iOS one minus
/// that category — derived by filter, never a second hand-written list.
public struct SiriPhrasebook: Sendable, Equatable {

    /// The Shortcuts-app grouping, straight from each intent's
    /// `IntentDescription(categoryName:)`.
    public enum Category: String, Sendable, CaseIterable {
        case discover = "Discover"
        case open = "Open"
        case listen = "Listen"
    }

    /// One App Shortcut's teachable phrases. `primary` and `variants` hold
    /// templates: the app name is baked in (every App Shortcut phrase must
    /// name the app) and `SiriPhrasebook.gameSlot` marks the spoken
    /// game-name hole in the parameterized ones.
    public struct Entry: Sendable, Equatable, Identifiable {
        /// The intent type name, e.g. "OpenGame".
        public let id: String
        public let category: Category
        /// The AppShortcut's `shortTitle`.
        public let title: String
        /// True when the phrases carry the game parameter.
        public let isParameterized: Bool
        public let primary: String
        public let variants: [String]

        public func spokenPrimary(game: String) -> String {
            substitute(game, into: primary)
        }

        public func spokenVariants(game: String) -> [String] {
            variants.map { substitute(game, into: $0) }
        }

        private func substitute(_ game: String, into template: String) -> String {
            template.replacingOccurrences(of: SiriPhrasebook.gameSlot, with: game)
        }
    }

    /// The placeholder marking where a saved game's name is spoken.
    public static let gameSlot = "‹game›"

    public let entries: [Entry]

    public func entries(in category: Category) -> [Entry] {
        entries.filter { $0.category == category }
    }

    /// The categories this platform teaches, in declaration order, empty ones
    /// dropped (the Mac has no Listen shortcuts).
    public var categories: [Category] {
        Category.allCases.filter { !entries(in: $0).isEmpty }
    }

    /// The name shown inside the parameterized phrases: the caller's newest
    /// saved game, else `GameRecord.defaultName` — which reads naturally
    /// spoken and is literally true on a fresh install.
    public static func exampleGameName(from newest: String?) -> String {
        let trimmed = newest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? GameRecord.defaultName : trimmed
    }

    /// All seven shortcuts, in category order Discover → Open → Listen.
    public static let iOS = SiriPhrasebook(entries: [
        Entry(id: "GetGameInfo",
              category: .discover,
              title: "Get Go Game Information",
              isParameterized: true,
              primary: "Get ‹game› information with KataGo Anytime",
              variants: [
                  "Get information on ‹game› with KataGo Anytime",
                  "Show ‹game› details using KataGo Anytime",
                  "Find out about ‹game› with KataGo Anytime",
                  "Check ‹game› info using KataGo Anytime",
                  "Tell me about ‹game› with KataGo Anytime"
              ]),
        Entry(id: "GetLatestGameInfo",
              category: .discover,
              title: "Get Latest Go Game",
              isParameterized: false,
              primary: "Get the latest go game information with KataGo Anytime",
              variants: [
                  "Get information on the latest go game with KataGo Anytime",
                  "Show the most recent go game details with KataGo Anytime",
                  "Find the latest go game info using KataGo Anytime",
                  "What's the latest go game with KataGo Anytime?",
                  "Tell me the latest go game info with KataGo Anytime"
              ]),
        Entry(id: "OpenGame",
              category: .open,
              title: "Open Go Game",
              isParameterized: true,
              primary: "Open ‹game› with KataGo Anytime",
              variants: [
                  "Open ‹game› in KataGo Anytime",
                  "Show ‹game› in KataGo Anytime",
                  "Open the game ‹game› with KataGo Anytime",
                  "Continue ‹game› with KataGo Anytime"
              ]),
        Entry(id: "OpenLatestGame",
              category: .open,
              title: "Open Latest Go Game",
              isParameterized: false,
              primary: "Open the latest go game with KataGo Anytime",
              variants: [
                  "Open my latest go game in KataGo Anytime",
                  "Continue the latest go game with KataGo Anytime",
                  "Resume my go game with KataGo Anytime"
              ]),
        Entry(id: "ListenToGame",
              category: .listen,
              title: "Listen to Go Game",
              isParameterized: true,
              primary: "Listen to ‹game› with KataGo Anytime",
              variants: [
                  "Play ‹game› aloud with KataGo Anytime",
                  "Narrate ‹game› with KataGo Anytime"
              ]),
        Entry(id: "ListenToLatestGame",
              category: .listen,
              title: "Listen to Latest Go Game",
              isParameterized: false,
              primary: "Listen to the latest go game with KataGo Anytime",
              variants: [
                  "Listen to my latest go game with KataGo Anytime",
                  "Narrate my latest go game with KataGo Anytime"
              ]),
        Entry(id: "ResumeListening",
              category: .listen,
              title: "Resume Listening",
              isParameterized: false,
              primary: "Resume listening with KataGo Anytime",
              variants: [
                  "Keep listening with KataGo Anytime",
                  "Continue my go game narration with KataGo Anytime"
              ])
    ])

    /// The Mac compiles KataGoShortcuts.swift with the three Listen shortcuts
    /// behind `#if os(iOS)`, so its catalog is the iOS one minus that
    /// category.
    public static let macOS = SiriPhrasebook(
        entries: iOS.entries.filter { $0.category != .listen })

    /// The catalog for the platform this build runs on — the data's single
    /// platform conditional, mirroring `VoiceControlPhrasebook.current` (the
    /// view carries one more, guarding the Shortcuts-app link).
    public static var current: SiriPhrasebook {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}

/// Everything you can say to Siri, in one place: one bold phrase per App
/// Shortcut, the alternatives Siri also accepts underneath, and a way into
/// the Shortcuts app.
public struct SiriPhrasesHelpView: View {
    private let phrasebook: SiriPhrasebook
    private let exampleGameName: String

    /// - Parameters:
    ///   - phrasebook: injectable for tests and previews; defaults to the
    ///     running platform's.
    ///   - exampleGameName: the user's newest saved game's name, shown inside
    ///     the phrases that take one. nil or blank falls back to
    ///     `GameRecord.defaultName`.
    public init(phrasebook: SiriPhrasebook = .current,
                exampleGameName: String? = nil) {
        self.phrasebook = phrasebook
        self.exampleGameName = SiriPhrasebook.exampleGameName(from: exampleGameName)
    }

    public var body: some View {
        List {
            Section("Getting Started") {
                Text("Say any of these phrases to Siri — from anywhere, even with the app closed. Every phrase names “KataGo Anytime” so Siri knows which app to ask.")
            }

            ForEach(phrasebook.categories, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(phrasebook.entries(in: category)) { entry in
                        phrase(entry.spokenPrimary(game: exampleGameName),
                               alsoDetail(for: entry))
                    }
                }
            }

            Section {
                shortcutsAppLink
            } footer: {
                // lineLimit(nil) + fixedSize is the pairing that makes this
                // wrap instead of truncating to one line in the Mac pane's
                // footer.
                Text("“\(exampleGameName)” stands in for a game's name — any saved game works in its place. These shortcuts also appear in the Shortcuts app.")
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Siri Phrases")
    }

    /// "Also: “…”  ·  “…”" — the remaining registered phrases, with the
    /// example game name substituted.
    private func alsoDetail(for entry: SiriPhrasebook.Entry) -> String {
        let quoted = entry.spokenVariants(game: exampleGameName).map { "“\($0)”" }
        return "Also: " + quoted.joined(separator: "  ·  ")
    }

    /// One row: the words to say, then the alternatives — the same helper as
    /// VoiceControlHelpView.phrase(_:_:), kept private in each file on
    /// purpose.
    private func phrase(_ spoken: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("“\(spoken)”")
                .font(.body.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Combined so VoiceOver reads "the phrase, then the alternatives" as
        // one stop instead of two.
        .accessibilityElement(children: .combine)
    }

    /// ShortcutsLink exists only in the iOS and visionOS SDKs (it is absent
    /// from _AppIntents_SwiftUI on macOS), so the Mac opens the Shortcuts app
    /// through its URL scheme instead — the guard names where the SYMBOL
    /// exists, not where the screen shows (only iOS and the Mac mount it).
    /// tvOS gets the empty branch, which is what keeps that scheme building.
    @ViewBuilder private var shortcutsAppLink: some View {
        #if os(iOS) || os(visionOS)
        ShortcutsLink()
        #elseif os(macOS)
        Link("Open the Shortcuts app", destination: URL(string: "shortcuts://")!)
        #endif
    }
}

#Preview("iOS catalog") {
    NavigationStack {
        SiriPhrasesHelpView(phrasebook: .iOS, exampleGameName: "Lee Sedol Game 4")
    }
}

#Preview("Mac catalog, fallback name") {
    NavigationStack {
        SiriPhrasesHelpView(phrasebook: .macOS)
    }
}
