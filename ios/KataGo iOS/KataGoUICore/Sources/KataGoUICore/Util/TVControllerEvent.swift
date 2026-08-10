//
//  TVControllerEvent.swift
//  KataGoUICore
//
//  The tvOS game-controller buttons the app is allowed to bind, and the legend
//  shown in Settings. Kept here so the "which buttons are focus-safe" rule and
//  the user-facing legend are unit-testable — the TV views are unreachable from
//  every test target in this project.
//
//  Named after the PHYSICAL button, not an action: the same button means
//  different things on the review screen and the live broadcast, and the screens
//  own that mapping.
//
//  Deliberately absent: A (arrives as UIPress .select, already consumed by the
//  window-level TVSelectPressCatcher), B / Menu (arrive as .menu, already
//  consumed by .onExitCommand), the D-pad (the focus engine's), Options (bound
//  to a system screenshot long-press, so its input is delayed or swallowed) and
//  Home. Binding any of them would double-fire.
//
//  On the review screen the navigation buttons (L1/R1/L2/R2) also work while
//  the play cursor is aiming — the cursor follows the last move as positions
//  change; X and Y stay aiming-suppressed there (the cursor owns the modes).
//

import Foundation

public enum TVControllerEvent: String, CaseIterable, Sendable, Equatable {
    case buttonX
    case buttonY
    case leftShoulder
    case rightShoulder
    case leftTrigger
    case rightTrigger
}

public struct TVControllerLegendRow: Identifiable, Sendable, Equatable {
    public let event: TVControllerEvent
    /// SF Symbol shown beside the row.
    public let symbol: String
    /// The button as a user names it.
    public let name: String
    /// What it does while reviewing a saved game.
    public let review: String
    /// What it does during the live broadcast.
    public let live: String

    public var id: String { event.rawValue }
}

public enum TVControllerLegend {
    public static let rows: [TVControllerLegendRow] = [
        TVControllerLegendRow(event: .buttonX,
                              symbol: "square.circle",
                              name: "X",
                              review: "Auto-Play",
                              live: "Pause / Resume"),
        TVControllerLegendRow(event: .buttonY,
                              symbol: "triangle.circle",
                              name: "Y",
                              review: "Analysis on / off",
                              live: "—"),
        TVControllerLegendRow(event: .leftShoulder,
                              symbol: "l1.rectangle.roundedbottom",
                              name: "L1",
                              review: "Back one move (hold to repeat)",
                              live: "Undo (while paused)"),
        TVControllerLegendRow(event: .rightShoulder,
                              symbol: "r1.rectangle.roundedbottom",
                              name: "R1",
                              review: "Forward one move (hold to repeat)",
                              live: "Skip the current slide"),
        TVControllerLegendRow(event: .leftTrigger,
                              symbol: "l2.rectangle.roundedtop",
                              name: "L2",
                              review: "Jump to the start",
                              live: "—"),
        TVControllerLegendRow(event: .rightTrigger,
                              symbol: "r2.rectangle.roundedtop",
                              name: "R2",
                              review: "Jump to the end",
                              live: "—"),
    ]
}
