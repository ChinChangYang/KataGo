import Foundation
import Testing
@testable import KataGo_Anytime

struct PrecompileProjectionTests {
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
}
