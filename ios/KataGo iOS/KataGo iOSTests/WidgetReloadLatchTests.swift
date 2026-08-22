import Testing
import KataGoUICore

// Mutating calls are hoisted into locals: `#expect` captures its operands
// immutably, so `latch.gameSwitched(...)` can't appear inside the macro.
struct WidgetReloadLatchTests {
    @Test func switchToGame_armsAndConsumesExactlyOnce() {
        // A game switch arms the latch; the reload fires when the switched
        // game's state lands (stones-ready edge) — and only once, so later
        // per-move stones-ready edges never burn widget reload budget.
        var latch = WidgetReloadLatch()
        #expect(!latch.isArmed)
        let action = latch.gameSwitched(hasNewGame: true)
        #expect(action == .armed)
        #expect(latch.isArmed)
        let firstConsume = latch.consumeDataLanded()
        let secondConsume = latch.consumeDataLanded()
        #expect(firstConsume)
        #expect(!latch.isArmed)
        #expect(!secondConsume)
    }

    @Test func consumeWhileUnarmed_neverFires() {
        // Stones-ready edges happen on every move; without a preceding switch
        // they must not reload.
        var latch = WidgetReloadLatch()
        let first = latch.consumeDataLanded()
        let second = latch.consumeDataLanded()
        #expect(!first)
        #expect(!second)
    }

    @Test func deselection_firesNowAndDropsAStaleArm() {
        // Deselecting (nil game) has no data to await: fire immediately, and a
        // stale arm from an abandoned switch must not fire later on some
        // unrelated stones-ready edge.
        var latch = WidgetReloadLatch()
        let armAction = latch.gameSwitched(hasNewGame: true)
        let deselectAction = latch.gameSwitched(hasNewGame: false)
        let consume = latch.consumeDataLanded()
        #expect(armAction == .armed)
        #expect(deselectAction == .fireNow)
        #expect(!latch.isArmed)
        #expect(!consume)
    }

    @Test func latchFiresOnFirstProjectionAfterSwitch() {
        // The trigger is no longer the engine's stones-ready edge: the board is
        // record-owned, so the switched game's position is PROJECTED (and
        // cached into the record) as soon as the record loads, engine or no
        // engine. That first projection is what must flush the App Group store
        // and reload the widgets — and every later projection of the same
        // switch (a re-render, a played move) must not.
        var latch = WidgetReloadLatch()
        let action = latch.gameSwitched(hasNewGame: true)
        let firstProjection = latch.consumeDataLanded()
        let laterProjection = latch.consumeDataLanded()
        let afterAMove = latch.consumeDataLanded()

        #expect(action == .armed)
        #expect(firstProjection)
        #expect(!laterProjection)
        #expect(!afterAMove)
    }

    @Test func reArm_worksAcrossCycles() {
        // Rapid A→B→C switching: each completed switch fires exactly once.
        var latch = WidgetReloadLatch()
        for _ in 0..<3 {
            let action = latch.gameSwitched(hasNewGame: true)
            let firstConsume = latch.consumeDataLanded()
            let secondConsume = latch.consumeDataLanded()
            #expect(action == .armed)
            #expect(firstConsume)
            #expect(!secondConsume)
        }
    }
}
