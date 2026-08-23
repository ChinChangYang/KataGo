//
//  EngineFeedTests.swift
//  KataGo iOSTests
//
//  The engine is fed move by move, never `loadsgf`. This pins the command
//  stream: the opening bundle's order, which setup command a position earns
//  (`set_free_handicap` for an all-Black setup, `set_position` otherwise),
//  and — the whole point of the change — that a move the replay refused is
//  never sent, so the engine and the display skip exactly the same indices.
//

import Testing
import Foundation
import GoRulesKit
@testable import KataGoUICore

@MainActor
struct EngineFeedTests {

    /// Builds the replay the app builds: the C++ parse behind `SgfOperations`,
    /// never a second parser.
    private func replay(_ sgf: String) throws -> SgfReplay {
        try #require(RecordReplayBuilder.replay(from: SgfOperations(sgf: sgf)))
    }

    private static let plain =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pp])"

    // MARK: - Opening bundle

    @Test("The opening bundle resets the engine, states the rules, then plays")
    func openingBundleOrder() throws {
        var r = try replay(Self.plain)
        let config = Config()
        let commands = EngineFeed.openingCommands(replay: &r, config: config, targetIndex: 3)

        #expect(commands.first == "rectangular_boardsize 19 19")
        #expect(commands.dropFirst().first == "clear_board")
        // Every rule/parameter command precedes the first `play`.
        let firstPlay = try #require(commands.firstIndex { $0.hasPrefix("play ") })
        let komi = try #require(commands.firstIndex { $0.hasPrefix("komi ") })
        let friendly = try #require(commands.firstIndex { $0 == "kata-set-rule friendlyPassOk false" })
        let ko = try #require(commands.firstIndex { $0.hasPrefix("kata-set-rule ko ") })
        let pda = try #require(commands.firstIndex { $0.hasPrefix("kata-set-param playoutDoublingAdvantage") })
        let wide = try #require(commands.firstIndex { $0.hasPrefix("kata-set-param analysisWideRootNoise") })
        #expect(ko < komi)
        #expect(komi < friendly)
        #expect(friendly < pda)
        #expect(pda < wide)
        #expect(wide < firstPlay)

        #expect(commands.filter { $0.hasPrefix("play ") } == ["play b Q16", "play w D4", "play b Q4"])
        // The whole point of the change: no loadsgf, and no printsgf echo.
        #expect(!commands.contains { $0.hasPrefix("loadsgf") })
        #expect(!commands.contains("printsgf"))
    }

    @Test("The feed stops at the target index, not at the tip")
    func feedStopsAtTarget() throws {
        var r = try replay(Self.plain)
        let commands = EngineFeed.openingCommands(replay: &r, config: Config(), targetIndex: 1)
        #expect(commands.filter { $0.hasPrefix("play ") } == ["play b Q16"])
    }

    @Test("Board size comes from the SGF, never from the Config")
    func sizeComesFromTheRecord() throws {
        var r = try replay("(;FF[4]GM[1]SZ[9]KM[7.5]RU[japanese];B[ee])")
        let config = Config()
        config.boardWidth = 19
        config.boardHeight = 19
        let commands = EngineFeed.openingCommands(replay: &r, config: config, targetIndex: 1)
        #expect(commands.first == "rectangular_boardsize 9 9")
    }

    @Test("A rectangular record keeps its own width and height")
    func rectangularSize() throws {
        var r = try replay("(;FF[4]GM[1]SZ[9:13]KM[7.5]RU[japanese])")
        let commands = EngineFeed.openingCommands(replay: &r, config: Config(), targetIndex: 0)
        #expect(commands.first == "rectangular_boardsize 9 13")
    }

    // MARK: - Setup

    @Test("A classic handicap (all-Black setup) uses set_free_handicap")
    func classicHandicapUsesFreeHandicap() throws {
        var r = try replay("(;FF[4]GM[1]SZ[19]KM[0.5]RU[japanese]AB[dd][pp][dp];W[pd])")
        let setup = try #require(EngineFeed.setupCommand(replay: &r))
        #expect(setup.hasPrefix("set_free_handicap "))
        let vertices = Set(setup.dropFirst("set_free_handicap ".count).split(separator: " ").map(String.init))
        #expect(vertices == ["D16", "Q4", "D4"])
    }

    @Test("A mixed setup uses set_position with a colour per stone")
    func mixedSetupUsesSetPosition() throws {
        var r = try replay("(;FF[4]GM[1]SZ[19]KM[0.5]RU[japanese]AB[dd]AW[pp];B[pd])")
        let setup = try #require(EngineFeed.setupCommand(replay: &r))
        #expect(setup == "set_position b D16 w Q4")
    }

    @Test("An AE removal is honoured — the engine is set up with what is left")
    func removalIsHonoured() throws {
        var r = try replay("(;FF[4]GM[1]SZ[19]KM[0.5]RU[japanese]AB[dd][pp]AE[pp];W[pd])")
        let setup = try #require(EngineFeed.setupCommand(replay: &r))
        #expect(setup == "set_free_handicap D16")
    }

    @Test("An empty opening position earns no set_ command at all")
    func emptySetupSendsNothing() throws {
        var r = try replay(Self.plain)
        #expect(EngineFeed.setupCommand(replay: &r) == nil)
        var bundle = try replay(Self.plain)
        let commands = EngineFeed.openingCommands(replay: &bundle, config: Config(), targetIndex: 3)
        #expect(!commands.contains { $0.hasPrefix("set_position") || $0.hasPrefix("set_free_handicap") })
    }

    /// `Board::setStonesFailIfNoLibs` refuses the whole placement, so a setup
    /// the engine would reject is skipped (and logged) rather than sent — the
    /// recorded moves still go out.
    @Test("A zero-liberty setup is skipped, and the plays still go out")
    func zeroLibertySetupIsSkipped() throws {
        // White A19 is surrounded by Black B19 and A18: no liberties.
        let sgf = "(;FF[4]GM[1]SZ[19]KM[0.5]RU[japanese]AW[aa]AB[ba][ab];B[pd])"
        var r = try replay(sgf)
        #expect(EngineFeed.setupCommand(replay: &r) == nil)

        var bundle = try replay(sgf)
        let commands = EngineFeed.openingCommands(replay: &bundle, config: Config(), targetIndex: 1)
        #expect(!commands.contains { $0.hasPrefix("set_position") || $0.hasPrefix("set_free_handicap") })
        #expect(commands.contains("play b Q16"))
    }

    // MARK: - Passes

    @Test("A recorded pass is fed as `play <colour> pass`")
    func passIsFed() throws {
        var r = try replay("(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[];W[tt];B[pd])")
        let commands = EngineFeed.forwardCommands(replay: &r, from: 0, to: 3)
        #expect(commands == ["play b pass", "play w pass", "play b Q16"])
    }

    // MARK: - Refusals

    /// The record plays Q16 twice. The replay refuses the second one (occupied),
    /// exactly as the engine's own `play` would — so it is never sent, and the
    /// two skip the same index.
    private static let refusing =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pd];W[pp])"

    @Test("A refused move is never sent")
    func refusedMoveIsNeverSent() throws {
        var r = try replay(Self.refusing)
        let commands = EngineFeed.openingCommands(replay: &r, config: Config(), targetIndex: 4)
        #expect(commands.filter { $0.hasPrefix("play ") } == ["play b Q16", "play w D4", "play w Q4"])
    }

    @Test("Forward navigation skips a refused index without losing the ones after it")
    func forwardSkipsRefused() throws {
        var r = try replay(Self.refusing)
        #expect(EngineFeed.forwardCommands(replay: &r, from: 2, to: 4) == ["play w Q4"])
        #expect(EngineFeed.forwardCommands(replay: &r, from: 2, to: 3) == [])
        #expect(EngineFeed.forwardCommands(replay: &r, from: 3, to: 4) == ["play w Q4"])
    }

    @Test("The undo count subtracts the refusals in the span")
    func undoCountSubtractsRefusals() throws {
        var r = try replay(Self.refusing)
        // Indices 0..<4 hold four recorded moves, one of which the engine never
        // received — so rewinding the whole game is three undos, not four.
        #expect(EngineFeed.undoCount(replay: &r, from: 4, to: 0) == 3)
        #expect(EngineFeed.undoCount(replay: &r, from: 4, to: 3) == 1)
        #expect(EngineFeed.undoCount(replay: &r, from: 3, to: 2) == 0)
        #expect(EngineFeed.undoCount(replay: &r, from: 2, to: 0) == 2)
        // A backwards or degenerate span is zero, never negative.
        #expect(EngineFeed.undoCount(replay: &r, from: 0, to: 4) == 0)
        #expect(EngineFeed.undoCount(replay: &r, from: 2, to: 2) == 0)
    }

    @Test("Out-of-range spans clamp instead of trapping")
    func spansClamp() throws {
        var r = try replay(Self.plain)
        #expect(EngineFeed.forwardCommands(replay: &r, from: -5, to: 99).count == 3)
        #expect(EngineFeed.undoCount(replay: &r, from: 99, to: -5) == 3)
        var bundle = try replay(Self.plain)
        #expect(EngineFeed.openingCommands(replay: &bundle, config: Config(), targetIndex: 99)
            .filter { $0.hasPrefix("play ") }.count == 3)
    }
}
