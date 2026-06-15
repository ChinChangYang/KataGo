import Foundation
import Testing
import KataGoUICore
@testable import KataGo_Anytime
@testable import KataGoUICore

struct CoreMLCacheReadinessProjectionTests {
    @Test func resolverReturnsNilForUnknownFileName() async throws {
        let inputs = makeProjectionResolver()("definitely-not-a-real-model.bin.gz")
        #expect(inputs == nil)
    }

    @Test func resolverReturnsInputsForBuiltInModel() async throws {
        let inputs = makeProjectionResolver()("default_model.bin.gz")
        #expect(inputs != nil)
        if let inputs {
            #expect(inputs.nnXLen > 0)
            #expect(inputs.nnYLen > 0)
            #expect(inputs.maxBatchSize >= 1)
            #expect(inputs.sourcePath.hasSuffix("default_model.bin.gz"))
        }
    }

    @Test func resolverReturnsInputsForHumanSLAux() async throws {
        let inputs = makeProjectionResolver()("b18c384nbt-humanv0.bin.gz")
        #expect(inputs != nil)
        guard let inputs else { return }
        #expect(inputs.sourcePath.hasSuffix("b18c384nbt-humanv0.bin.gz"))
        #expect(inputs.nnXLen > 0)
        #expect(inputs.nnYLen > 0)
        #expect(inputs.nnXLen == inputs.nnYLen)
        #expect(inputs.useFP16 == true)
        #expect(inputs.maxBatchSize == 1)

        // Aux projection must mirror the built-in's settings: same nnLen
        // and same requireExactNNLen so the cache key matches what the
        // engine launch will compute when the built-in is selected.
        let builtIn = makeProjectionResolver()("default_model.bin.gz")
        #expect(builtIn != nil)
        if let builtIn {
            #expect(inputs.nnXLen == builtIn.nnXLen)
            #expect(inputs.nnYLen == builtIn.nnYLen)
            #expect(inputs.requireExactNNLen == builtIn.requireExactNNLen)
        }
    }

    /// Contract test: the projection's digest must equal what
    /// `CoreMLModelCache.cacheKey(...)` produces for the same inputs the
    /// engine launch path passes through `katago_coreml_bridge`. The
    /// `useFP16` / `maxBatchSize` literals below are pinned to the C++
    /// defaults for iOS Apple Silicon. If those defaults drift in
    /// metalbackend.cpp without `makeProjectionResolver` being updated to
    /// match, the picker's green checkmark goes silently wrong; updating
    /// only one side fails this test.
    @Test func projectionDigestEqualsCacheKeyDigestForBuiltIn() async throws {
        guard let bundlePath = Bundle.main.path(forResource: "default_model",
                                                 ofType: "bin.gz")
        else {
            // Test bundle does not ship the built-in model. Skip cleanly.
            return
        }
        guard let builtIn = NeuralNetworkModel.builtInModel else {
            Issue.record("NeuralNetworkModel.builtInModel must exist")
            return
        }
        let settings = BackendSettings(model: builtIn)
        let nnLen = Int32(settings.effectiveMaxBoardLength)

        let launchKey = try await CoreMLModelCache.cacheKey(
            forSourcePath: bundlePath,
            nnXLen: nnLen, nnYLen: nnLen,
            requireExactNNLen: settings.requireExactNNLen,
            useFP16: true,          // C++ iOS Apple Silicon default
            maxBatchSize: 1)        // C++ iOS Apple Silicon default

        let projected = try await makeProjectionDigestFor()(builtIn.fileName)
        #expect(projected == launchKey.digest)
    }

    /// Same contract test for the bundled Human SL aux entry. Aux digest
    /// must match the built-in's settings since the engine loads them
    /// together with the same nnLen and the same fp16/maxBatchSize.
    @Test func projectionDigestEqualsCacheKeyDigestForHumanSLAux() async throws {
        guard let bundlePath = Bundle.main.path(forResource: "b18c384nbt-humanv0",
                                                 ofType: "bin.gz")
        else {
            return
        }
        guard let builtIn = NeuralNetworkModel.builtInModel else {
            Issue.record("NeuralNetworkModel.builtInModel must exist")
            return
        }
        let settings = BackendSettings(model: builtIn)
        let nnLen = Int32(settings.effectiveMaxBoardLength)

        // HumanSL aux is bundled but its path does not match the
        // built-in `default_model.bin.gz` switch in `sourceIdentity`,
        // so cacheKey routes through the downloaded-hasher path. Use
        // the same hasher the projection wires in production.
        let launchKey = try await CoreMLModelCache.cacheKey(
            forSourcePath: bundlePath,
            nnXLen: nnLen, nnYLen: nnLen,
            requireExactNNLen: settings.requireExactNNLen,
            useFP16: true,
            maxBatchSize: 1,
            downloadedHasher: BinFileHasher.shared.identityForDownloadedFile)

        let projected = try await makeProjectionDigestFor()("b18c384nbt-humanv0.bin.gz")
        #expect(projected == launchKey.digest)
    }
}
