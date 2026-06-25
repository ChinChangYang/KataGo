//
//  EngineDeviceAssignmentsTests.swift
//  KataGo AnytimeTests
//
//  The app always launches a fixed GPU+ANE inference mux. These tests run on
//  the iOS Simulator — exactly the platform whose Metal layer crashes inside
//  MLX GPU inference — so they directly verify the simulator variant of the
//  mux never includes the MLX/GPU device (0).
//

import Testing
import KataGoUICore

struct EngineDeviceAssignmentsTests {
    /// On the simulator the mux must be all-ANE: device 0 (MLX/GPU) crashes
    /// the simulator's Metal translation layer. Every code must be a valid
    /// device (0 = MLX/GPU, 100 = CoreML/ANE).
    @Test func platformMuxExcludesGPUOnSimulator() {
        let mux = EngineDeviceAssignments.platformMux
        #expect(!mux.isEmpty)
        #expect(!mux.contains(0))
        #expect(mux.allSatisfy { $0 == 0 || $0 == 100 })
    }

    /// The mux keeps a 2-NN-server-thread shape (1 GPU + 1 ANE on device →
    /// 2 ANE on the simulator), so the multi-server-thread path is exercised.
    @Test func platformMuxHasTwoThreads() {
        #expect(EngineDeviceAssignments.platformMux.count == 2)
    }
}
