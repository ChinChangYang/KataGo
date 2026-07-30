//
//  VoiceControlHelpView.swift
//  KataGoUICore
//
//  Feedback (2026-07-30): with Voice Control on, "it is not clear what
//  commands are available".
//
//  The app CANNOT list Voice Control's commands — Voice Control lists them
//  itself, contextually, and the set depends on the OS and the user's
//  Customize Commands choices. So this screen does the two things the app is
//  actually the authority on: it names the phrase that produces that list, and
//  it documents the part no system command can usefully show — a goban whose
//  hundreds of speakable targets are invisible, where the "Show names" overlay
//  is unreadable and naming a point directly is the only sane path.
//
//  Shared like `AcknowledgmentsView`: one view in the package, pushed by iOS
//  (Global Settings ▸ Accessibility) and hosted by macOS (Settings ▸ Voice
//  Control tab). tvOS and watchOS have no Voice Control; visionOS has it but
//  no voice-addressable board (controller-only input), so neither mounts this.
//

import SwiftUI

/// Voice Control's wording for one platform. iOS and macOS disagree on three
/// strings — the activation verb, the phrase that lists commands, and the
/// settings path — so a single hard-coded copy would be wrong on one of them.
///
/// A value type rather than `#if` inside the view on purpose: the test target
/// only ever runs on the iOS Simulator, so anything behind `#if os(macOS)` can
/// never be exercised. Both instances compile everywhere and both are asserted
/// in `BoardAccessibilityElementsTests`.
///
/// Sources: Apple, "Use Voice Control on your iPhone, iPad, or iPod touch"
/// (support.apple.com/en-us/111778) and "Use Voice Control commands to
/// interact with your Mac" (support.apple.com/guide/mac-help/mh40719).
public struct VoiceControlPhrasebook: Sendable, Equatable {
    /// The verb that activates a named element: "Tap" on iOS, "Click" on Mac.
    public let activate: String
    /// The command that lists what can be said on the current screen.
    public let listCommands: String
    /// Where Voice Control is switched on.
    public let enablePath: String
    /// Where the complete, user-editable command list lives.
    public let commandListPath: String

    public static let iOS = VoiceControlPhrasebook(
        activate: "Tap",
        listCommands: "Show me what to say",
        enablePath: "Settings ▸ Accessibility ▸ Voice Control",
        commandListPath: "Settings ▸ Accessibility ▸ Voice Control ▸ Customize Commands")

    public static let macOS = VoiceControlPhrasebook(
        activate: "Click",
        listCommands: "Show commands",
        enablePath: "System Settings ▸ Accessibility ▸ Voice Control",
        commandListPath: "System Settings ▸ Accessibility ▸ Voice Control ▸ Commands")

    /// The phrasebook for the platform this build runs on. The only `#if` in
    /// the feature, deliberately kept out of the view and off the data.
    public static var current: VoiceControlPhrasebook {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }

    /// One complete spoken command for a named element, e.g. "Tap K 10".
    public func command(_ elementName: String) -> String {
        "\(activate) \(elementName)"
    }
}

/// The board names this screen shows as examples, taken from
/// `BoardAccessibilityElement.elements(...)` — the same builder that names the
/// real overlay targets. Nothing here is a string literal, so the help text
/// cannot drift from what Voice Control actually hears, and it adapts to the
/// board in front of the user: a 37×37 shows its two-letter columns, a 9×9
/// shows its own corners, a rectangle stays correct.
public struct VoiceControlBoardExamples: Sendable, Equatable {
    public let boardWidth: Int
    public let boardHeight: Int
    /// Bottom-left intersection, e.g. "A 1".
    public let nearCorner: String
    /// Top-right intersection, e.g. "T 19".
    public let farCorner: String
    /// A central intersection, e.g. "K 10".
    public let center: String
    /// A two-letter-column name, present only on boards wider than 25 columns
    /// (where the labels run past Z), e.g. "AA 1".
    public let twoLetterColumn: String?
    /// How many intersections carry a speakable name — the number that makes
    /// the "Show names" overlay useless on a full board.
    public var namedPointCount: Int { boardWidth * boardHeight }

    /// `Coordinate.xLabelMap` covers 50 columns; a board of at least 2 is
    /// needed for two distinct corners. Callers pass whatever the live game
    /// says, including 0 before the first board arrives, so clamp rather than
    /// fail.
    public static func clamped(_ side: Int) -> Int { min(max(side, 2), 50) }

    public init(boardWidth: Int, boardHeight: Int) {
        let width = Self.clamped(boardWidth)
        let height = Self.clamped(boardHeight)
        self.boardWidth = width
        self.boardHeight = height

        let elements = BoardAccessibilityElement.elements(width: width,
                                                          height: height,
                                                          includePass: false)
        func label(x: Int, y: Int) -> String? {
            elements.first { $0.coordinate.x == x && $0.coordinate.y == y }?.label
        }

        // `elements` is never empty for a clamped board, so the fallbacks are
        // unreachable; they exist so this stays a non-failable initializer.
        nearCorner = label(x: 0, y: 1) ?? ""
        farCorner = label(x: width - 1, y: height) ?? ""
        center = label(x: (width - 1) / 2, y: (height + 1) / 2) ?? ""
        // Column index 25 is the first that needs two letters ("AA").
        twoLetterColumn = width > 25 ? label(x: 25, y: 1) : nil
    }
}

/// How to drive this app by voice: the system phrase that lists the available
/// commands, plus the app's own naming rules for a board that draws its targets
/// instead of using controls.
public struct VoiceControlHelpView: View {
    private let phrasebook: VoiceControlPhrasebook
    private let examples: VoiceControlBoardExamples

    /// - Parameters:
    ///   - boardWidth: the board in front of the user, so the examples name
    ///     points that actually exist. Defaults to 19×19 for the case where no
    ///     game is open.
    ///   - phrasebook: injectable for tests and previews; defaults to the
    ///     running platform's.
    public init(boardWidth: Int = 19,
                boardHeight: Int = 19,
                phrasebook: VoiceControlPhrasebook = .current) {
        self.phrasebook = phrasebook
        self.examples = VoiceControlBoardExamples(boardWidth: boardWidth,
                                                  boardHeight: boardHeight)
    }

    public var body: some View {
        List {
            Section("Getting Started") {
                Text("Turn Voice Control on in \(phrasebook.enablePath). Once it is listening, you can play, review, and navigate this app without touching the screen.")
            }

            Section("Seeing What You Can Say") {
                phrase(phrasebook.listCommands,
                       "Lists the commands available right now. The list changes with the screen, so ask again after opening a game or a sheet.")
                phrase("Show names",
                       "Labels every control on screen. Say “\(phrasebook.command("‹name›"))” to use one — for example “\(phrasebook.command("More"))”.")
                phrase("Show numbers",
                       "Numbers the controls instead, for anything whose name is awkward to say. “Show grid” overlays a numbered grid for the rest.")
            }

            Section {
                phrase(phrasebook.command(examples.center),
                       "Every intersection is named by its coordinate: the column letter, a brief pause, then the row number.")
                phrase("\(phrasebook.command(examples.nearCorner))  ·  \(phrasebook.command(examples.farCorner))",
                       cornerDetail)
                phrase(phrasebook.command("Pass"),
                       "Passes the turn. The pass tile has to be on screen — Show pass, under Board.")
            } header: {
                Text("Playing on the Board")
            } footer: {
                Text("On the board, name the point instead of saying “Show names”: this \(examples.boardWidth)×\(examples.boardHeight) board has \(examples.namedPointCount) named intersections and the overlay labels them all at once. The letters and numbers drawn around the board are decoration — the intersections themselves carry the names.")
            }

            Section("If a Spoken Move Does Nothing") {
                Text("A spoken move runs the same checks as a tap, so Voice Control did hear you. A move is refused when it is not your turn, when the point is already occupied, while the opponent is thinking or auto-play is running, and while the board is still loading.")
                Text("Playing on top of an existing move asks first: say “\(phrasebook.command("Overwrite"))” to replace it, or “\(phrasebook.command("Cancel"))” to leave the game as it is.")
            }

            Section("Every Command") {
                Text("Voice Control’s complete list — including the commands this app does not define, and any you add yourself — is in \(phrasebook.commandListPath).")
            }
        }
        .navigationTitle("Voice Control")
    }

    /// The column-letter rules, stated only where they apply: every board skips
    /// I, and only boards past 25 columns need the two-letter form.
    private var cornerDetail: String {
        let base = "Opposite corners of this board. Column letters skip I, the way they do on a printed board."
        guard let twoLetterColumn = examples.twoLetterColumn else { return base }
        return base + " Past Z the letters double up, so this board also has “\(phrasebook.command(twoLetterColumn))”."
    }

    /// One row: the words to say, then what they do.
    private func phrase(_ spoken: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("“\(spoken)”")
                .font(.body.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Combined so VoiceOver reads "the phrase, then what it does" as one
        // stop instead of two. Left in the accessibility tree deliberately —
        // this is the screen a VoiceOver user reads to learn the commands.
        .accessibilityElement(children: .combine)
    }
}

#Preview("iOS, 19x19") {
    NavigationStack {
        VoiceControlHelpView(boardWidth: 19, boardHeight: 19, phrasebook: .iOS)
    }
}

#Preview("Mac wording, 37x37") {
    NavigationStack {
        VoiceControlHelpView(boardWidth: 37, boardHeight: 37, phrasebook: .macOS)
    }
}
