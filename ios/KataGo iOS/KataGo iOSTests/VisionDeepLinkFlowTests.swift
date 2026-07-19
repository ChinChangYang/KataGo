import Testing
import KataGoUICore

struct VisionDeepLinkFlowTests {
    @Test func noPendingLink_isNothingPending_regardlessOfEngineState() {
        // The 2x2 engine-state matrix with no latched link: always .nothingPending
        // (the drain sites call this unconditionally after boot and on onChange).
        for isReady in [false, true] {
            for isBooting in [false, true] {
                #expect(VisionDeepLinkFlow.disposition(
                    hasPending: false, isReady: isReady, isBooting: isBooting)
                    == .nothingPending)
            }
        }
    }

    @Test func pendingLink_appliesOnlyWhenReadyAndNotBooting() {
        // Warm path: engine ready, no boot in flight → apply now.
        #expect(VisionDeepLinkFlow.disposition(
            hasPending: true, isReady: true, isBooting: false) == .apply)
    }

    @Test func pendingLink_staysLatchedThroughBoot() {
        // Cold/mid-boot deliveries keep the latch; the boot resolver or the
        // post-ready drain applies it later. This is the Release cold-launch
        // race guard (the iOS handshake-split lesson): never switch games while
        // the engine is still booting or choosing a model.
        #expect(VisionDeepLinkFlow.disposition(
            hasPending: true, isReady: false, isBooting: true) == .keepLatched)
        #expect(VisionDeepLinkFlow.disposition(
            hasPending: true, isReady: false, isBooting: false) == .keepLatched)
        #expect(VisionDeepLinkFlow.disposition(
            hasPending: true, isReady: true, isBooting: true) == .keepLatched)
    }
}
