import Foundation
import Testing
@testable import KataGo_Anytime

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
}
