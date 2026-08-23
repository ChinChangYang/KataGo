//
//  TVAutoPlayPolicyTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

struct TVAutoPlayPolicyTests {
    private func tick(hasNextMove: Bool = true,
                      isBranchActive: Bool = false,
                      stonesReady: Bool = true,
                      recordedGameIsFinished: Bool = false,
                      boardFitsEngine: Bool = true,
                      thermalState: ProcessInfo.ThermalState = .nominal) -> TVAutoPlayTick {
        TVAutoPlayPolicy.tick(hasNextMove: hasNextMove,
                              isBranchActive: isBranchActive,
                              stonesReady: stonesReady,
                              recordedGameIsFinished: recordedGameIsFinished,
                              boardFitsEngine: boardFitsEngine,
                              thermalState: thermalState)
    }

    @Test func theHappyPathAdvancesOneMove() {
        #expect(tick() == .advance)
    }

    /// The board refresh from the previous move is still in flight: skip this
    /// tick rather than piling GTP batches into the queue.
    @Test func anUnreadyBoardHoldsTheTick() {
        #expect(tick(stonesReady: false) == .hold)
    }

    /// A variation is throwaway state; the mainline is what replays.
    @Test func anActiveBranchStops() {
        #expect(tick(isBranchActive: true) == .stop(.branchActive))
    }

    /// A fanless Apple TV must not replay a 250-move game while hot. Reuses
    /// the attract-mode thermal rule so both features agree.
    @Test func seriousAndCriticalThermalStateStop() {
        #expect(tick(thermalState: .serious) == .stop(.thermal))
        #expect(tick(thermalState: .critical) == .stop(.thermal))
        #expect(tick(thermalState: .fair) == .advance)
    }

    /// Branch and thermal outrank readiness: neither should be masked by a
    /// board that happens to be mid-refresh.
    @Test func branchAndThermalOutrankAnUnreadyBoard() {
        #expect(tick(isBranchActive: true, stonesReady: false) == .stop(.branchActive))
        #expect(tick(stonesReady: false, thermalState: .critical) == .stop(.thermal))
    }

    @Test func runningOutOfMovesInAnUnfinishedGameContinuesLive() {
        #expect(tick(hasNextMove: false, recordedGameIsFinished: false)
                == .finish(continuesLive: true))
    }

    /// The user decision: a game that already ended just stops.
    @Test func runningOutOfMovesInAFinishedGameDoesNotContinueLive() {
        #expect(tick(hasNextMove: false, recordedGameIsFinished: true)
                == .finish(continuesLive: false))
    }

    /// An unready board must not be mistaken for the end of the game.
    @Test func endOfGameIsOnlyReportedOnceTheBoardIsSettled() {
        #expect(tick(hasNextMove: false, stonesReady: false) == .hold)
    }

    /// The live continuation seeds a NEW game from the reviewed position and
    /// hands it to the engine to play on. A board the running engine cannot
    /// hold (a 37x37 record on a 19 buffer — *Held*, which the review screen
    /// renders happily) must therefore never become one: the seeded record is
    /// created from the reviewed SGF, so nothing downstream can shrink it, and
    /// the engine would be handed a board it aborts on. The replay simply stops
    /// on the final position instead.
    @Test func anOversizedBoardNeverHandsOffToALiveContinuation() {
        #expect(tick(hasNextMove: false, boardFitsEngine: false)
                == .finish(continuesLive: false))
        // ...and the two reasons compose: a finished game does not continue
        // either way.
        #expect(tick(hasNextMove: false, recordedGameIsFinished: true, boardFitsEngine: false)
                == .finish(continuesLive: false))
    }

    /// The same decision, reachable on its own: `startAutoPlay` asks it
    /// directly when the user presses Play/Pause while already parked at the
    /// last recorded move, and that path never goes through `tick`.
    @Test func theContinuesLiveRuleIsOneRuleForBothCallers() {
        #expect(TVAutoPlayPolicy.continuesLive(recordedGameIsFinished: false,
                                               boardFitsEngine: true))
        #expect(!TVAutoPlayPolicy.continuesLive(recordedGameIsFinished: true,
                                                boardFitsEngine: true))
        #expect(!TVAutoPlayPolicy.continuesLive(recordedGameIsFinished: false,
                                                boardFitsEngine: false))
    }
}
