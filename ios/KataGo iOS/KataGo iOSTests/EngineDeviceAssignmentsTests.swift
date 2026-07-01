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

/// The tvOS build restricts the model catalog to the built-in b18 net plus small
/// networks, so the constrained Apple TV memory budget is never blown by a large
/// (e.g. 40-block, ~864 MB) net synced in from another device. The `#if os(tvOS)`
/// arm can't run on the iOS-sim test host, so these exercise the extracted,
/// platform-agnostic predicate `NeuralNetworkModel.isEligible(...)` directly.
struct NeuralNetworkModelEligibilityTests {
    private func model(_ fileName: String) -> NeuralNetworkModel {
        NeuralNetworkModel.allCases.first { $0.fileName == fileName }!
    }

    private func eligibleOnTV(_ m: NeuralNetworkModel) -> Bool {
        NeuralNetworkModel.isEligible(builtIn: m.builtIn,
                                      fileSize: m.fileSize,
                                      restrictToSmallModels: true)
    }

    /// Off tvOS (iOS/visionOS/macOS) every model in the catalog is eligible.
    @Test func allModelsEligibleWhenUnrestricted() {
        for m in NeuralNetworkModel.allCases {
            #expect(NeuralNetworkModel.isEligible(builtIn: m.builtIn,
                                                  fileSize: m.fileSize,
                                                  restrictToSmallModels: false))
        }
    }

    /// The built-in b18 net is always eligible under the tvOS restriction, even if
    /// it were (hypothetically) larger than the cap — it's the guaranteed fallback.
    @Test func builtInAlwaysEligibleUnderRestriction() {
        #expect(NeuralNetworkModel.isEligible(builtIn: true,
                                              fileSize: 900_000_000,
                                              restrictToSmallModels: true))
    }

    /// The cap is inclusive: a model exactly at the limit passes; one byte over fails.
    @Test func thresholdBoundaryIsInclusive() {
        let cap = NeuralNetworkModel.tvOSMaxEligibleFileSize
        #expect(NeuralNetworkModel.isEligible(builtIn: false, fileSize: cap, restrictToSmallModels: true))
        #expect(!NeuralNetworkModel.isEligible(builtIn: false, fileSize: cap + 1, restrictToSmallModels: true))
    }

    /// Under the tvOS restriction the b18 + small nets pass; the large nets (which
    /// would jetsam an Apple TV) are blocked.
    @Test func tvOSRestrictionSplitsRealModelCatalog() {
        for name in ["default_model.bin.gz", "kata9x9.bin.gz", "lionffen.txt.gz",
                     "lionffen_b24c64_3x3_v3_12300.bin.gz", "rect15.bin.gz"] {
            #expect(eligibleOnTV(model(name)))
        }
        for name in ["official.bin.gz", "fd3.bin.gz", "m2.bin.gz", "igoh120latest.bin.gz"] {
            #expect(!eligibleOnTV(model(name)))
        }
    }
}
