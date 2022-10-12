import XCTest
import MetalPerformanceShadersGraph

final class SourceLayerTest: XCTestCase {

    func testNCHW() {
        let sourceLayer = SourceLayer(graph: MPSGraph(),
                                      tensor: nil,
                                      batchSize: 2,
                                      nnXLen: 5,
                                      nnYLen: 4,
                                      numChannels: 3,
                                      useFP16: false,
                                      useNHWC: false)

        XCTAssert(sourceLayer.tensor.shape == [2, 3, 4, 5])
        XCTAssert(sourceLayer.layout == .NCHW)
    }

    func testTensorNCHW() {
        let graph = MPSGraph()
        let tensor = graph.constant(1, shape: [2, 3, 4, 5], dataType: .float32)

        let sourceLayer = SourceLayer(graph: graph,
                                      tensor: tensor,
                                      batchSize: 2,
                                      nnXLen: 5,
                                      nnYLen: 4,
                                      numChannels: 3,
                                      useFP16: false,
                                      useNHWC: false)

        XCTAssert(sourceLayer.tensor === tensor)
        XCTAssert(sourceLayer.tensor.shape == [2, 3, 4, 5])
        XCTAssert(sourceLayer.layout == .NCHW)
    }

    func testNHWC() {
        let sourceLayer = SourceLayer(graph: MPSGraph(),
                                      tensor: nil,
                                      batchSize: 2,
                                      nnXLen: 5,
                                      nnYLen: 4,
                                      numChannels: 3,
                                      useFP16: false,
                                      useNHWC: true)

        XCTAssert(sourceLayer.tensor.shape == [2, 4, 5, 3])
        XCTAssert(sourceLayer.layout == .NHWC)
    }
}

final class InputGlobalLayerTest: XCTestCase {

    func testTensor() {
        let graph = MPSGraph()
        let tensor = graph.constant(1, shape: [2, 3], dataType: .float32)

        let inputGlobalLayer = InputGlobalLayer(graph: graph,
                                                tensor: tensor,
                                                batchSize: 2,
                                                numGlobalFeatures: 3,
                                                useFP16: false)

        XCTAssert(inputGlobalLayer.tensor === tensor)
        XCTAssert(inputGlobalLayer.tensor.shape == [2, 3])
    }

    func testNilTensor() {
        let inputGlobalLayer = InputGlobalLayer(graph: MPSGraph(),
                                                tensor: nil,
                                                batchSize: 2,
                                                numGlobalFeatures: 3,
                                                useFP16: false)

        XCTAssert(inputGlobalLayer.tensor.shape == [2, 3])
    }
}

final class MaskLayerTest: XCTestCase {

    func testTensorNHWC() {
        let graph = MPSGraph()
        let tensor = graph.constant(1, shape: [2, 3, 4, 1], dataType: .float32)

        let maskLayer = MaskLayer(graph: graph,
                                  tensor: tensor,
                                  batchSize: 2,
                                  nnXLen: 4,
                                  nnYLen: 3,
                                  useFP16: false,
                                  useNHWC: true)

        XCTAssert(maskLayer.tensor === tensor)
        XCTAssert(maskLayer.tensor.shape == [2, 3, 4, 1])
    }

    func testTensor() {
        let graph = MPSGraph()
        let tensor = graph.constant(1, shape: [2, 1, 3, 4], dataType: .float32)

        let maskLayer = MaskLayer(graph: graph,
                                  tensor: tensor,
                                  batchSize: 2,
                                  nnXLen: 4,
                                  nnYLen: 3,
                                  useFP16: false,
                                  useNHWC: false)

        XCTAssert(maskLayer.tensor === tensor)
        XCTAssert(maskLayer.tensor.shape == [2, 1, 3, 4])
    }

    func testNilTensor() {
        let graph = MPSGraph()

        let maskLayer = MaskLayer(graph: graph,
                                  tensor: nil,
                                  batchSize: 2,
                                  nnXLen: 4,
                                  nnYLen: 3,
                                  useFP16: false,
                                  useNHWC: false)

        XCTAssert(maskLayer.tensor.shape == [2, 1, 3, 4])
    }
}

final class MaskSumLayerTest: XCTestCase {

    func testTensorNHWC() {
        let graph = MPSGraph()
        let useNHWC = true
        let maskLayer = MaskLayer(graph: graph,
                                  tensor: nil,
                                  batchSize: 2,
                                  nnXLen: 4,
                                  nnYLen: 3,
                                  useFP16: false,
                                  useNHWC: useNHWC)

        let shape: [NSNumber] = [2, 1, 1, 1]
        let tensor = graph.constant(12, shape: shape, dataType: .float32)

        let maskSumLayer = MaskSumLayer(graph: graph,
                                        tensor: tensor,
                                        mask: maskLayer,
                                        useNHWC: useNHWC)

        let fetch = graph.run(feeds: [:],
                              targetTensors: [maskSumLayer.tensor],
                              targetOperations: nil)

        let length = Int(truncating: shape.product())
        let buffer = UnsafeMutablePointer<Float32>.allocate(capacity: length)

        fetch[maskSumLayer.tensor]?.mpsndarray().readBytes(buffer, strideBytes: nil)

        XCTAssert(maskSumLayer.tensor.shape == [2, 1, 1, 1])
        XCTAssertEqual(buffer[0], 12)
        XCTAssertEqual(buffer[1], 12)
    }

    func testTensor() {
        let graph = MPSGraph()
        let useNHWC = false
        let maskLayer = MaskLayer(graph: graph,
                                  tensor: nil,
                                  batchSize: 2,
                                  nnXLen: 4,
                                  nnYLen: 3,
                                  useFP16: false,
                                  useNHWC: useNHWC)

        let shape: [NSNumber] = [2, 1, 1, 1]
        let tensor = graph.constant(12, shape: shape, dataType: .float32)

        let maskSumLayer = MaskSumLayer(graph: graph,
                                        tensor: tensor,
                                        mask: maskLayer,
                                        useNHWC: useNHWC)

        let fetch = graph.run(feeds: [:],
                              targetTensors: [maskSumLayer.tensor],
                              targetOperations: nil)

        let length = Int(truncating: shape.product())
        let buffer = UnsafeMutablePointer<Float32>.allocate(capacity: length)

        fetch[maskSumLayer.tensor]?.mpsndarray().readBytes(buffer, strideBytes: nil)

        XCTAssert(maskSumLayer.tensor.shape == [2, 1, 1, 1])
        XCTAssertEqual(buffer[0], 12)
        XCTAssertEqual(buffer[1], 12)
    }

    func testNilTensor() {
        let graph = MPSGraph()
        let shape: [NSNumber] = [2, 1, 3, 4]
        let tensor = graph.constant(1, shape: shape, dataType: .float32)
        let useNHWC = false
        let maskLayer = MaskLayer(graph: graph,
                                  tensor: tensor,
                                  batchSize: 2,
                                  nnXLen: 4,
                                  nnYLen: 3,
                                  useFP16: false,
                                  useNHWC: useNHWC)

        let maskSumLayer = MaskSumLayer(graph: graph,
                                        tensor: nil,
                                        mask: maskLayer,
                                        useNHWC: useNHWC)

        XCTAssert(maskSumLayer.tensor.shape == [2, 1, 1, 1])

        let fetch = graph.run(feeds: [:],
                              targetTensors: [maskSumLayer.tensor],
                              targetOperations: nil)

        let length = Int(truncating: shape.product())
        let buffer = UnsafeMutablePointer<Float32>.allocate(capacity: length)

        fetch[maskSumLayer.tensor]?.mpsndarray().readBytes(buffer, strideBytes: nil)

        XCTAssertEqual(buffer[0], 12)
        XCTAssertEqual(buffer[1], 12)
    }
}

final class MaskSumSqrtS14M01LayerTest: XCTestCase {

    func testTensor() {
        let graph = MPSGraph()
        let maskLayer = MaskLayer(graph: graph,
                                  tensor: nil,
                                  batchSize: 2,
                                  nnXLen: 4,
                                  nnYLen: 3,
                                  useFP16: false,
                                  useNHWC: false)

        let maskSumLayer = MaskSumLayer(graph: graph,
                                        tensor: nil,
                                        mask: maskLayer,
                                        useNHWC: false)

        let shape: [NSNumber] = [2, 1, 1, 1]

        let tensor = graph.constant(-1.053589838486225,
                                     shape: shape,
                                     dataType: .float32)

        let maskSumSqrtS14M01Layer = MaskSumSqrtS14M01Layer(graph: graph,
                                                            tensor: tensor,
                                                            maskSum: maskSumLayer,
                                                            useFP16: false)

        let fetch = graph.run(feeds: [:],
                              targetTensors: [maskSumSqrtS14M01Layer.tensor],
                              targetOperations: nil)

        let length = Int(truncating: shape.product())
        let buffer = UnsafeMutablePointer<Float32>.allocate(capacity: length)

        fetch[maskSumSqrtS14M01Layer.tensor]?.mpsndarray().readBytes(buffer,
                                                                     strideBytes: nil)

        XCTAssert(maskSumSqrtS14M01Layer.tensor.shape == [2, 1, 1, 1])
        XCTAssertEqual(buffer[0], -1.053589838486225, accuracy: 1e-8)
        XCTAssertEqual(buffer[1], -1.053589838486225, accuracy: 1e-8)
    }

    func testNilTensor() {
        let graph = MPSGraph()

        let shape: [NSNumber] = [2, 1, 3, 4]

        let tensor = graph.constant(1,
                                    shape: shape,
                                    dataType: .float32)

        let maskLayer = MaskLayer(graph: graph,
                                  tensor: tensor,
                                  batchSize: 2,
                                  nnXLen: 4,
                                  nnYLen: 3,
                                  useFP16: false,
                                  useNHWC: false)

        let maskSumLayer = MaskSumLayer(graph: graph,
                                        tensor: nil,
                                        mask: maskLayer,
                                        useNHWC: false)

        let maskSumSqrtS14M01Layer = MaskSumSqrtS14M01Layer(graph: graph,
                                                            tensor: nil,
                                                            maskSum: maskSumLayer,
                                                            useFP16: false)

        let fetch = graph.run(feeds: [:],
                              targetTensors: [maskSumSqrtS14M01Layer.tensor],
                              targetOperations: nil)

        let length = Int(truncating: shape.product())
        let buffer = UnsafeMutablePointer<Float32>.allocate(capacity: length)

        fetch[maskSumSqrtS14M01Layer.tensor]?.mpsndarray().readBytes(buffer,
                                                                     strideBytes: nil)

        XCTAssert(maskSumSqrtS14M01Layer.tensor.shape == [2, 1, 1, 1])
        XCTAssertEqual(buffer[0], -1.053589838486225, accuracy: 1e-8)
        XCTAssertEqual(buffer[1], -1.053589838486225, accuracy: 1e-8)
    }
}

final class MaskSumSqrtS14M01SquareS01LayerTest: XCTestCase {

    func testTensor() {
        let graph = MPSGraph()
        let maskLayer = MaskLayer(graph: graph,
                                  tensor: nil,
                                  batchSize: 2,
                                  nnXLen: 4,
                                  nnYLen: 3,
                                  useFP16: false,
                                  useNHWC: false)

        let maskSumLayer = MaskSumLayer(graph: graph,
                                        tensor: nil,
                                        mask: maskLayer,
                                        useNHWC: false)

        let maskSumSqrtS14M01Layer = MaskSumSqrtS14M01Layer(graph: graph,
                                                            tensor: nil,
                                                            maskSum: maskSumLayer,
                                                            useFP16: false)

        let shape: [NSNumber] = [2, 1, 1, 1]

        let tensor = graph.constant(1.010051547761429,
                                    shape: shape,
                                    dataType: .float32)

        let maskSumSqrtS14M01SquareS01Layer = MaskSumSqrtS14M01SquareS01Layer(graph: graph,
                                                                              tensor: tensor,
                                                                              maskSumSqrtS14M01: maskSumSqrtS14M01Layer,
                                                                              useFP16: false)

        let fetch = graph.run(feeds: [:],
                              targetTensors: [maskSumSqrtS14M01SquareS01Layer.tensor],
                              targetOperations: nil)

        let length = Int(truncating: shape.product())
        let buffer = UnsafeMutablePointer<Float32>.allocate(capacity: length)

        fetch[maskSumSqrtS14M01SquareS01Layer.tensor]?.mpsndarray().readBytes(buffer,
                                                                     strideBytes: nil)

        XCTAssert(maskSumSqrtS14M01SquareS01Layer.tensor.shape == [2, 1, 1, 1])
        XCTAssertEqual(buffer[0], 1.010051547761429, accuracy: 1e-8)
        XCTAssertEqual(buffer[1], 1.010051547761429, accuracy: 1e-8)
    }

    func testNilTensor() {
        let graph = MPSGraph()

        let shape: [NSNumber] = [2, 1, 3, 4]

        let tensor = graph.constant(1,
                                    shape: shape,
                                    dataType: .float32)

        let maskLayer = MaskLayer(graph: graph,
                                  tensor: tensor,
                                  batchSize: 2,
                                  nnXLen: 4,
                                  nnYLen: 3,
                                  useFP16: false,
                                  useNHWC: false)

        let maskSumLayer = MaskSumLayer(graph: graph,
                                        tensor: nil,
                                        mask: maskLayer,
                                        useNHWC: false)

        let maskSumSqrtS14M01Layer = MaskSumSqrtS14M01Layer(graph: graph,
                                                            tensor: nil,
                                                            maskSum: maskSumLayer,
                                                            useFP16: false)

        let maskSumSqrtS14M01SquareS01Layer = MaskSumSqrtS14M01SquareS01Layer(graph: graph,
                                                                              tensor: nil,
                                                                              maskSumSqrtS14M01: maskSumSqrtS14M01Layer,
                                                                              useFP16: false)

        let fetch = graph.run(feeds: [:],
                              targetTensors: [maskSumSqrtS14M01SquareS01Layer.tensor],
                              targetOperations: nil)

        let length = Int(truncating: shape.product())
        let buffer = UnsafeMutablePointer<Float32>.allocate(capacity: length)

        fetch[maskSumSqrtS14M01SquareS01Layer.tensor]?.mpsndarray().readBytes(buffer,
                                                                     strideBytes: nil)

        XCTAssert(maskSumSqrtS14M01SquareS01Layer.tensor.shape == [2, 1, 1, 1])
        XCTAssertEqual(buffer[0], 1.010051547761429, accuracy: 1e-8)
        XCTAssertEqual(buffer[1], 1.010051547761429, accuracy: 1e-8)
    }
}
