//
//  VisionEngineController.swift
//  KataGo Anytime Vision
//

import Foundation
import KataGoUICore

/// Owns the one-shot engine C++ thread spawn (mirrors TVEngineController's
/// spawn, without the tvOS restart machinery).
@Observable
@MainActor
final class VisionEngineController {
    /// Vision renders only 9/13/19 boards; launching the NN buffer at 19
    /// (not COMPILE_MAX_BOARD_LEN 37) keeps the resident tensor pool small.
    let maxBoardLength = 19

    private var started = false

    func startInitial() {
        guard !started else { return }
        started = true

        let launchedMaxBoardLength = maxBoardLength
        let thread = Thread {
            // CoreML/ANE only — deliberately NOT EngineDeviceAssignments
            // .platformMux, which resolves to [0, 100] (one MLX/GPU server)
            // on a real visionOS device; the GPU belongs to the 90 Hz
            // compositor, so both NN server threads go to the Neural Engine.
            KataGoHelper.runGtp(deviceAssignments: [100, 100],
                                numSearchThreads: KataGoHelper.mlxNumSearchThreads,
                                maxBoardSizeForNNBuffer: launchedMaxBoardLength)
        }
        // Needs a >512 KB stack (BoardHistory copies) — match the iOS app's 1 MB.
        thread.stackSize = 4096 * 256
        thread.start()
    }
}
