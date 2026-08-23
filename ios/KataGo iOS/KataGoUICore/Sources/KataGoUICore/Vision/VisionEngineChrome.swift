//
//  VisionEngineChrome.swift
//  KataGoUICore
//
//  What the volume shows, and what it lets the user do, while the engine comes
//  and goes. Three answers, one rule, so the boot, the Max-Board-Size restart,
//  a model activation and a failed launch cannot drift apart — they are the
//  same question asked with a different availability.
//
//  The rule the whole change rests on: THE BOARD NEVER WAITS FOR THE ENGINE.
//  It is record-owned (replayed from the game's own SGF), so it renders as soon
//  as a game is mounted and keeps rendering through every launch, restart and
//  failure. Only the geometry can stop it: visionOS has no board asset outside
//  2...37, so there is genuinely nothing to draw.
//
//  Platform-agnostic and in the Vision/ folder so the iOS-simulator test target
//  covers it.
//

import Foundation

public struct VisionEngineChrome: Equatable, Sendable {
    /// The goban. The engine has no say in this.
    public let showsBoard: Bool

    /// Controls that SEND GTP commands: the analysis sparkle, the Human/AI
    /// chips (which rewrite the human-SL bundle and re-arm the search), and New
    /// Game (which creates a record and feeds it, sized by a buffer a launching
    /// engine has not settled yet). Only a ready engine can take those.
    ///
    /// *Held* counts as "cannot": the engine is up, but it refuses this board's
    /// size, so there is nothing for those controls to start.
    public let allowsEngineCommands: Bool

    /// Stepping (L1/R1), jumping (L2/R2), and opening another game from the
    /// Games list. Always allowed while a board is mounted: the cursor is
    /// record-owned, and the `play`/`undo` such a step would send is dropped by
    /// the command gate and repaid in full by the handshake's resync.
    public let allowsNavigation: Bool

    /// Creating a game (the Games list's + menu, the Custom panel's Create).
    /// Like the other command-senders it waits for a live engine — but unlike
    /// them it is allowed while *Held*: the engine is up and perfectly able to
    /// take a SMALLER board, and starting one is the natural way out of a hold
    /// (the alternative is a user stuck on a 37x37 record with the one control
    /// that would rescue them greyed out).
    public let allowsNewGame: Bool

    public static func make(hasMountedGame: Bool,
                            isGeometryRenderable: Bool,
                            availability: EngineAvailability) -> VisionEngineChrome {
        let showsBoard = hasMountedGame && isGeometryRenderable
        let isHeld: Bool
        if case .held = availability { isHeld = true } else { isHeld = false }
        return VisionEngineChrome(
            showsBoard: showsBoard,
            allowsEngineCommands: showsBoard && availability == .ready,
            allowsNavigation: showsBoard,
            allowsNewGame: showsBoard && (availability == .ready || isHeld))
    }
}
