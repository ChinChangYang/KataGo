//
//  EngineFeed.swift
//  KataGoUICore
//
//  The engine is told the record's moves ONE AT A TIME — never `loadsgf`.
//
//  Why: `loadsgf` throws away the whole file the moment one move is illegal,
//  and it is the only command that can put the engine somewhere the display
//  cannot follow. `play` refuses exactly one move and leaves the engine
//  unchanged, which is the same thing `GoRulesKit.SgfReplay` does when it
//  replays the record for the board. So the feed never sends a move the replay
//  refused, and engine and display skip precisely the same indices.
//
//  Everything here is pure: it builds command strings out of a replay and a
//  config, and sends nothing. `GobanState.syncEngine(to:)` is what puts the
//  strings on the wire.
//

import Foundation
import GoRulesKit

public enum EngineFeed {

    /// Everything the engine needs to stand where the record stands: a reset to
    /// the record's own board size, the rules, the setup stones, and one `play`
    /// per ACCEPTED recorded move below `targetIndex`.
    ///
    /// The board size comes from the replay (i.e. the SGF's `SZ`), never from
    /// `config`: the record is the authority on its own geometry, and a config
    /// that disagrees would feed the moves onto the wrong grid.
    ///
    /// `replay` is `inout` because forcing it forward is what discovers the
    /// refusals — the caller keeps the memoized checkpoints for the next call.
    public static func openingCommands(replay: inout SgfReplay,
                                       config: Config,
                                       targetIndex: Int) -> [String] {
        var commands: [String] = [
            GtpCommandBuilder.boardSizeCommand(width: replay.width, height: replay.height),
            // `set_free_handicap` refuses a non-empty board, and a stale
            // position under the new rules would be fed the record's moves on
            // top of it. Explicit beats relying on boardsize's own reset.
            "clear_board",
        ]
        commands.append(contentsOf: GtpCommandBuilder.ruleCommandsBundle(
            ko: config.koRuleText,
            scoring: config.scoringRuleText,
            tax: config.taxRuleText,
            multiStoneSuicide: config.multiStoneSuicideLegal,
            hasButton: config.hasButton,
            whiteHandicapBonus: config.whiteHandicapBonusRuleText))
        commands.append(GtpCommandBuilder.komiCommand(config.komi))
        // Disable friendly pass to avoid a memory shortage problem.
        commands.append("kata-set-rule friendlyPassOk false")
        commands.append(GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))
        commands.append(GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))
        commands.append(contentsOf: GtpCommandBuilder.symmetricHumanAnalysisCommands(
            humanSLProfile: config.effectiveHumanProfileForBlack,
            humanProfileForWhite: config.effectiveHumanProfileForWhite,
            humanRatioForBlack: config.humanRatioForBlack,
            humanRatioForWhite: config.humanRatioForWhite))

        if let setup = setupCommand(replay: &replay) {
            commands.append(setup)
        }
        commands.append(contentsOf: forwardCommands(replay: &replay, from: 0, to: targetIndex))
        return commands
    }

    /// The `play` arguments for the recorded move at `index`, or nil when the
    /// replay refused it — the engine was never given that move.
    ///
    /// THE single answer to "was this index sent, and as what". Navigation asks
    /// it too (`GobanState.engineMove`), so the vertex a forward step plays and
    /// the vertex the opening feed played are the same string by construction,
    /// and the count of moves an `undo` walk has to take back can never drift
    /// from the count that went out.
    ///
    /// Deriving the vertex from the REPLAY, not from `BoardSize`, is the point:
    /// a `BoardSize` that disagreed with the record (a stale size mid-switch)
    /// used to silence the `play` while the refusal bookkeeping still counted
    /// the move as sent — one `undo` too many, and permanent skew.
    ///
    /// Colours are lower-case, matching every other `play` the app sends
    /// (`GobanState.play` is handed "b"/"w" by its callers) so one transcript
    /// does not mix two spellings. `PlayerIO::tryParsePlayer` lower-cases its
    /// argument, so the engine reads both alike.
    public static func playArguments(replay: inout SgfReplay,
                                     at index: Int) -> (turn: String, vertex: String)? {
        guard index >= 0, index < replay.moveCount else { return nil }
        // Refusals are discovered by replaying, so force the replay PAST the
        // index before asking about it.
        _ = replay.acceptedMoveCount(upTo: index + 1)
        guard !replay.isRefused(index), let move = replay.move(at: index) else { return nil }
        return (turn: move.color == .black ? "b" : "w",
                vertex: move.point.map { $0.gtpVertex(boardHeight: replay.height) } ?? "pass")
    }

    /// The GTP line for `playArguments`. One formatter, so the feed and
    /// navigation cannot spell the same move differently.
    public static func playCommand(turn: String, vertex: String) -> String {
        "play \(turn) \(vertex)"
    }

    /// One `play` per accepted recorded move in `from..<to`. A refused index
    /// contributes nothing — the engine never received it, so the display and
    /// the engine stay on the same index.
    public static func forwardCommands(replay: inout SgfReplay, from: Int, to: Int) -> [String] {
        let start = min(max(from, 0), replay.moveCount)
        let end = min(max(to, 0), replay.moveCount)
        guard end > start else { return [] }

        var commands: [String] = []
        commands.reserveCapacity(end - start)
        for index in start..<end {
            guard let move = playArguments(replay: &replay, at: index) else { continue }
            commands.append(playCommand(turn: move.turn, vertex: move.vertex))
        }
        return commands
    }

    /// How many `undo`s take the engine from index `from` back to index `to`.
    /// Refused moves were never sent, so they are not there to take back —
    /// which is the whole reason this is not `from - to`.
    public static func undoCount(replay: inout SgfReplay, from: Int, to: Int) -> Int {
        let high = min(max(from, 0), replay.moveCount)
        let low = min(max(to, 0), replay.moveCount)
        guard high > low else { return 0 }
        return replay.acceptedMoveCount(upTo: high) - replay.acceptedMoveCount(upTo: low)
    }

    /// The `set_free_handicap` / `set_position` command for the record's setup
    /// stones (AB/AW with AE already applied), or nil when there is nothing to
    /// set up — or when the engine would refuse the placement outright.
    ///
    /// `Board::setStonesFailIfNoLibs` rejects the WHOLE placement if any group
    /// has no liberties, and a rejected setup would leave the engine on an
    /// empty board silently. A problem record like that is rare enough to log
    /// and step over: the recorded moves still go out, so the engine ends up as
    /// close to the record as it can get.
    public static func setupCommand(replay: inout SgfReplay) -> String? {
        let position = replay.position(at: 0)
        guard !position.blackVertices.isEmpty || !position.whiteVertices.isEmpty else {
            return nil
        }
        guard !hasZeroLibertyGroup(blackVertices: position.blackVertices,
                                   whiteVertices: position.whiteVertices,
                                   width: replay.width,
                                   height: replay.height) else {
            printError("EngineFeed: the record's setup stones include a group with no liberties "
                       + "(\(position.blackVertices.count)B/\(position.whiteVertices.count)W on "
                       + "\(replay.width)x\(replay.height)); skipping the set_ command and feeding the moves alone")
            return nil
        }
        return GtpCommandBuilder.setupStonesCommand(blackVertices: position.blackVertices,
                                                    whiteVertices: position.whiteVertices)
    }

    // MARK: - Setup legality

    /// Whether any setup group would reach the engine with zero liberties —
    /// what `Board::setStonesFailIfNoLibs` refuses. Rebuilt on a `GoBoard`
    /// rather than asked of the replay, because setup stones are PLACED (no
    /// capture resolution), which is exactly what the engine does with them.
    private static func hasZeroLibertyGroup(blackVertices: [String],
                                            whiteVertices: [String],
                                            width: Int,
                                            height: Int) -> Bool {
        var board = GoBoard(width: width, height: height)
        for vertex in blackVertices {
            guard let point = goPoint(vertex: vertex, width: width, height: height) else { continue }
            board.placeSetupStone(at: point, color: .black)
        }
        for vertex in whiteVertices {
            guard let point = goPoint(vertex: vertex, width: width, height: height) else { continue }
            board.placeSetupStone(at: point, color: .white)
        }
        for index in 0..<board.area where board.grid[index] != .empty {
            if board.libertyCount(ofChainAt: index) == 0 { return true }
        }
        return false
    }

    /// GTP vertex -> `GoPoint`. `BoardPoint` counts rows from the BOTTOM (it is
    /// built straight off the vertex's own row number); `GoPoint` counts them
    /// from the top, as the SGF and the C++ parser do.
    private static func goPoint(vertex: String, width: Int, height: Int) -> GoPoint? {
        guard let point = BoardPoint(move: vertex, width: width, height: height),
              !point.isPass(width: width, height: height) else { return nil }
        return GoPoint(x: point.x, y: height - 1 - point.y)
    }
}
