import Foundation
import MetalPerformanceShaders
import MetalPerformanceShadersGraph

extension UnsafeMutablePointer<Float32> {
    func toFP16(length: Int) -> UnsafeMutablePointer<Float16> {
        let fp16Pointer = UnsafeMutablePointer<Float16>.allocate(capacity: length)

        for i in 0..<length {
            fp16Pointer[i] = Float16(self[i])
        }

        return fp16Pointer
    }

    func toFP16(_ fp16Pointer: UnsafeMutablePointer<Float16>, length: Int) {
        for i in 0..<length {
            fp16Pointer[i] = Float16(self[i])
        }
    }
}

extension UnsafeMutablePointer<Float16> {
    func toFP32(_ fp32Pointer: UnsafeMutablePointer<Float32>, length: Int) {
        for i in 0..<length {
            fp32Pointer[i] = Float32(self[i])
        }
    }
}

extension MPSNDArray {
    convenience init(device: MTLDevice, tensor: MPSGraphTensor) {
        // Metal backend uses a fixed batch size,
        // so every shape is determined at compile time.
        let descriptor = MPSNDArrayDescriptor(dataType: tensor.dataType,
                                              shape: tensor.shape!)

        self.init(device: device, descriptor: descriptor)
    }

    func writeBytes(_ buffer: UnsafeMutableRawPointer) {
        self.writeBytes(buffer, strideBytes: nil)
    }

    func readBytes(_ buffer: UnsafeMutableRawPointer) {
        self.readBytes(buffer, strideBytes: nil)
    }
}

extension MPSGraphTensor {
    func countElements() -> Int {
        var result = shape![0].intValue
        for i in 1..<shape!.count {
            result *= shape![i].intValue
        }
        return result
    }
}

extension MPSDataType {
    init(useFP16: Bool) {
        if useFP16 {
            self.init(rawValue: MPSDataType.float16.rawValue)!
        } else {
            self.init(rawValue: MPSDataType.float32.rawValue)!
        }
    }

    func toMemoryLayoutSize() -> Int {
        let memoryLayoutSize: Int
        switch self {
        case .float16:
            memoryLayoutSize = MemoryLayout<Float16>.size
        default:
            precondition(self == .float32)
            memoryLayoutSize = MemoryLayout<Float32>.size
        }
        return memoryLayoutSize
    }
}

extension Array where Element == NSNumber {
    func countElements() -> Int {
        var result = 1.0
        for x in self {
            result *= x.doubleValue
        }
        return Int(result)
    }

    func countBytes(of dataType: MPSDataType) -> Int {
        return countElements() * dataType.toMemoryLayoutSize()
    }
}

class InputShape {
    class func create(batchSize: NSNumber,
                      numChannels: NSNumber,
                      nnYLen: NSNumber,
                      nnXLen: NSNumber,
                      useNHWC: Bool) -> [NSNumber] {
        let shape: [NSNumber]
        if useNHWC {
            shape = [batchSize,
                     nnYLen,
                     nnXLen,
                     numChannels]
        } else {
            shape = [batchSize,
                     numChannels,
                     nnYLen,
                     nnXLen]
        }
        return shape
    }

    class func getChannelAxis(useNHWC: Bool) -> Int {
        return useNHWC ? 3 : 1
    }

    class func getHWAxes(useNHWC: Bool) -> [NSNumber] {
        let hwAxes: [NSNumber]
        if useNHWC {
            hwAxes = [1, 2]
        } else {
            hwAxes = [2, 3]
        }
        return hwAxes
    }
}

class InputLayer {
    let tensor: MPSGraphTensor

    init(graph: MPSGraph,
         batchSize: NSNumber,
         nnXLen: NSNumber,
         nnYLen: NSNumber,
         numChannels: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {
        let shape = InputShape.create(batchSize: batchSize,
                                      numChannels: numChannels,
                                      nnYLen: nnYLen,
                                      nnXLen: nnXLen,
                                      useNHWC: useNHWC)

        let dataType = MPSDataType.init(useFP16: useFP16)

        self.tensor = graph.placeholder(shape: shape,
                                        dataType: dataType,
                                        name: nil)

        assert(self.tensor.shape?.count == 4)
    }
}

class InputGlobalLayer {
    let tensor: MPSGraphTensor

    init(tensor: MPSGraphTensor) {
        self.tensor = tensor
        assert(self.tensor.shape?.count == 4)
    }

    init(graph: MPSGraph,
         batchSize: NSNumber,
         numGlobalFeatures: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {
        let shape = InputShape.create(batchSize: batchSize,
                                      numChannels: numGlobalFeatures,
                                      nnYLen: 1,
                                      nnXLen: 1,
                                      useNHWC: useNHWC)

        let dataType = MPSDataType.init(useFP16: useFP16)

        self.tensor = graph.placeholder(shape: shape,
                                        dataType: dataType,
                                        name: nil)

        assert(self.tensor.shape?.count == 4)
    }
}

class MaskLayer {
    let tensor: MPSGraphTensor

    init(tensor: MPSGraphTensor) {
        self.tensor = tensor
        assert(self.tensor.shape?.count == 4)
    }

    init(graph: MPSGraph,
         batchSize: NSNumber,
         nnXLen: NSNumber,
         nnYLen: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {
        let shape = InputShape.create(batchSize: batchSize,
                                      numChannels: 1,
                                      nnYLen: nnYLen,
                                      nnXLen: nnXLen,
                                      useNHWC: useNHWC)

        let dataType = MPSDataType.init(useFP16: useFP16)

        self.tensor = graph.placeholder(shape: shape,
                                        dataType: dataType,
                                        name: nil)

        assert(self.tensor.shape?.count == 4)
        assert(self.tensor.shape == shape)
    }
}

class MaskSumLayer {
    let tensor: MPSGraphTensor

    init(tensor: MPSGraphTensor) {
        self.tensor = tensor
        assert(self.tensor.shape?.count == 4)
    }

    init(graph: MPSGraph,
         mask: MaskLayer,
         useNHWC: Bool) {
        let hwAxes = InputShape.getHWAxes(useNHWC: useNHWC)

        self.tensor = graph.reductionSum(with: mask.tensor,
                                         axes: hwAxes,
                                         name: nil)

        assert(self.tensor.shape?.count == 4)
    }
}

class MaskSumSqrtS14M01Layer {
    let tensor: MPSGraphTensor

    init(tensor: MPSGraphTensor) {
        self.tensor = tensor
        assert(self.tensor.shape?.count == 4)
    }

    init(graph: MPSGraph,
         maskSum: MaskSumLayer,
         useFP16: Bool) {
        let dataType = MPSDataType.init(useFP16: useFP16)
        let sqrtMaskSum = graph.squareRoot(with: maskSum.tensor, name: nil)

        let fourTeen = graph.constant(14.0,
                                      shape: sqrtMaskSum.shape!,
                                      dataType: dataType)

        let subtracted = graph.subtraction(sqrtMaskSum, fourTeen, name: nil)

        let zeroPointone = graph.constant(0.1,
                                          shape: sqrtMaskSum.shape!,
                                          dataType: dataType)

        self.tensor = graph.multiplication(subtracted,
                                           zeroPointone,
                                           name: nil)

        assert(self.tensor.shape?.count == 4)
    }
}

class MaskSumSqrtS14M01SquareS01Layer {
    let tensor: MPSGraphTensor

    init(tensor: MPSGraphTensor) {
        self.tensor = tensor
        assert(self.tensor.shape?.count == 4)
    }

    init(graph: MPSGraph,
         maskSumSqrtS14M01: MaskSumSqrtS14M01Layer,
         useFP16: Bool) {
        let dataType = MPSDataType.init(useFP16: useFP16)
        let squared = graph.square(with: maskSumSqrtS14M01.tensor, name: nil)

        let zeroPointone = graph.constant(0.1,
                                          shape: squared.shape!,
                                          dataType: dataType)

        self.tensor = graph.subtraction(squared,
                                        zeroPointone,
                                        name: nil)

        assert(self.tensor.shape?.count == 4)
    }
}

@objc
class SWConvLayerDesc: NSObject {
    let convYSize: NSNumber
    let convXSize: NSNumber
    let inChannels: NSNumber
    let outChannels: NSNumber
    let dilationY: Int
    let dilationX: Int
    let weights: UnsafeMutablePointer<Float32>

    @objc
    init(convYSize: NSNumber,
         convXSize: NSNumber,
         inChannels: NSNumber,
         outChannels: NSNumber,
         dilationY: Int,
         dilationX: Int,
         weights: UnsafeMutablePointer<Float32>) {
        self.convYSize = convYSize
        self.convXSize = convXSize
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.dilationY = dilationY
        self.dilationX = dilationX
        self.weights = weights
    }
}

@objc
class ConvLayer: NSObject {
    let resultTensor: MPSGraphTensor

    @objc
    class func test(descriptor: SWConvLayerDesc,
                    nnXLen: NSNumber,
                    nnYLen: NSNumber,
                    batchSize: NSNumber,
                    useFP16: Bool,
                    useNHWC: Bool,
                    input: UnsafeMutablePointer<Float32>,
                    output: UnsafeMutablePointer<Float32>) {
        let device = MPSGraphDevice(mtlDevice: MTLCreateSystemDefaultDevice()!)
        let graph = MPSGraph()

        let source = InputLayer(graph: graph,
                                batchSize: batchSize,
                                nnXLen: nnXLen,
                                nnYLen: nnYLen,
                                numChannels: descriptor.inChannels,
                                useFP16: useFP16,
                                useNHWC: useNHWC)

        let conv = ConvLayer(graph: graph,
                             sourceTensor: source.tensor,
                             descriptor: descriptor,
                             batchSize: batchSize,
                             nnXLen: nnXLen,
                             nnYLen: nnYLen,
                             useFP16: useFP16,
                             useNHWC: useNHWC)

        let sourceArray = MPSNDArray(device: device.metalDevice!,
                                     tensor: source.tensor)

        if useFP16 {
            let inLength = source.tensor.countElements()

            sourceArray.writeBytes(input.toFP16(length: inLength))
        } else {
            sourceArray.writeBytes(input)
        }

        let sourceTensorData = MPSGraphTensorData(sourceArray)

        let fetch = graph.run(feeds: [source.tensor: sourceTensorData],
                              targetTensors: [conv.resultTensor],
                              targetOperations: nil)

        if useFP16 {
            let outLength = conv.resultTensor.countElements()
            let outputFP16 = UnsafeMutablePointer<Float16>.allocate(capacity: outLength)

            fetch[conv.resultTensor]?.mpsndarray().readBytes(outputFP16)

            for i in 0..<outLength {
                output[i] = Float32(outputFP16[i])
            }
        } else {
            fetch[conv.resultTensor]?.mpsndarray().readBytes(output)
        }
    }

    init(graph: MPSGraph,
         sourceTensor: MPSGraphTensor,
         descriptor: SWConvLayerDesc,
         batchSize: NSNumber,
         nnXLen: NSNumber,
         nnYLen: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {
        let dataType = MPSDataType.init(useFP16: useFP16)

        let dataLayout: MPSGraphTensorNamedDataLayout = useNHWC ? .NHWC : .NCHW

        let weightsShape = [descriptor.outChannels,
                            descriptor.inChannels,
                            descriptor.convYSize,
                            descriptor.convXSize]

        let convDescriptor =
        MPSGraphConvolution2DOpDescriptor(strideInX: 1,
                                          strideInY: 1,
                                          dilationRateInX: descriptor.dilationX,
                                          dilationRateInY: descriptor.dilationY,
                                          groups: 1,
                                          paddingStyle: .TF_SAME,
                                          dataLayout: dataLayout,
                                          weightsLayout: .OIHW)!

        let byteCount = weightsShape.countBytes(of: dataType)
        let weightsData: Data

        if useFP16 {
            let length = weightsShape.countElements()

            weightsData = Data(bytesNoCopy: descriptor.weights.toFP16(length: length),
                               count: byteCount,
                               deallocator: .free)
        } else {
            weightsData = Data(bytesNoCopy: descriptor.weights,
                               count: byteCount,
                               deallocator: .none)
        }

        let weightsTensor = graph.constant(weightsData,
                                           shape: weightsShape,
                                           dataType: dataType)

        resultTensor = graph.convolution2D(sourceTensor,
                                           weights: weightsTensor,
                                           descriptor: convDescriptor,
                                           name: nil)

        assert(resultTensor.shape?.count == 4)
    }
}

@objc
class SWBatchNormLayerDesc: NSObject {
    let numChannels: NSNumber
    let epsilon: Float32
    let hasScale: NSNumber
    let hasBias: NSNumber
    let mean: UnsafeMutablePointer<Float32>
    let variance: UnsafeMutablePointer<Float32>
    let scale: UnsafeMutablePointer<Float32>
    let bias: UnsafeMutablePointer<Float32>

    @objc
    init(numChannels: NSNumber,
         epsilon: Float32,
         hasScale: NSNumber,
         hasBias: NSNumber,
         mean: UnsafeMutablePointer<Float32>,
         variance: UnsafeMutablePointer<Float32>,
         scale: UnsafeMutablePointer<Float32>,
         bias: UnsafeMutablePointer<Float32>) {
        self.numChannels = numChannels
        self.epsilon = epsilon
        self.hasScale = hasScale
        self.hasBias = hasBias
        self.mean = mean
        self.variance = variance
        self.scale = scale
        self.bias = bias
    }
}

@objc
class BatchNormLayer: NSObject {
    let resultTensor: MPSGraphTensor

    @objc
    class func test(descriptor: SWBatchNormLayerDesc,
                    nnXLen: NSNumber,
                    nnYLen: NSNumber,
                    batchSize: NSNumber,
                    useFP16: Bool,
                    useNHWC: Bool,
                    input: UnsafeMutablePointer<Float32>,
                    mask maskPointer: UnsafeMutablePointer<Float32>,
                    output: UnsafeMutablePointer<Float32>) {

        let device = MPSGraphDevice(mtlDevice: MTLCreateSystemDefaultDevice()!)
        let graph = MPSGraph()

        let source = InputLayer(graph: graph,
                                batchSize: batchSize,
                                nnXLen: nnXLen,
                                nnYLen: nnYLen,
                                numChannels: descriptor.numChannels,
                                useFP16: useFP16,
                                useNHWC: useNHWC)

        let mask = MaskLayer(graph: graph,
                             batchSize: batchSize,
                             nnXLen: nnXLen,
                             nnYLen: nnYLen,
                             useFP16: useFP16,
                             useNHWC: useNHWC)

        let batchNorm = BatchNormLayer(graph: graph,
                                       sourceTensor: source.tensor,
                                       maskTensor: mask.tensor,
                                       descriptor: descriptor,
                                       nnXLen: nnXLen,
                                       nnYLen: nnYLen,
                                       batchSize: batchSize,
                                       useFP16: useFP16,
                                       useNHWC: useNHWC)

        let sourceArray = MPSNDArray(device: device.metalDevice!,
                                     tensor: source.tensor)

        let maskArray = MPSNDArray(device: device.metalDevice!,
                                   tensor: mask.tensor)

        if useFP16 {
            let inLength = source.tensor.countElements()
            let maskLength = mask.tensor.countElements()

            sourceArray.writeBytes(input.toFP16(length: inLength))

            maskArray.writeBytes(maskPointer.toFP16(length: maskLength))
        } else {
            sourceArray.writeBytes(input)
            maskArray.writeBytes(maskPointer)
        }

        let sourceTensorData = MPSGraphTensorData(sourceArray)
        let maskTensorData = MPSGraphTensorData(maskArray)

        let fetch = graph.run(feeds: [source.tensor: sourceTensorData,
                                      mask.tensor: maskTensorData],
                              targetTensors: [batchNorm.resultTensor],
                              targetOperations: nil)

        if useFP16 {
            let outLength = batchNorm.resultTensor.countElements()
            let outputFP16 = UnsafeMutablePointer<Float16>.allocate(capacity: outLength)

            fetch[batchNorm.resultTensor]?.mpsndarray().readBytes(outputFP16)

            for i in 0..<outLength {
                output[i] = Float32(outputFP16[i])
            }
        } else {
            fetch[batchNorm.resultTensor]?.mpsndarray().readBytes(output)
        }
    }

    init(graph: MPSGraph,
         sourceTensor: MPSGraphTensor,
         maskTensor: MPSGraphTensor,
         descriptor: SWBatchNormLayerDesc,
         nnXLen: NSNumber,
         nnYLen: NSNumber,
         batchSize: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {
        let meanShape = InputShape.create(batchSize: 1,
                                          numChannels: descriptor.numChannels,
                                          nnYLen: 1,
                                          nnXLen: 1,
                                          useNHWC: useNHWC)

        let dataType = MPSDataType.init(useFP16: useFP16)
        let byteCount = meanShape.countBytes(of: dataType)
        let meanData: Data
        let varianceData: Data
        let scaleData: Data
        let biasData: Data

        if useFP16 {
            let length = meanShape.countElements()

            meanData = Data(bytesNoCopy: descriptor.mean.toFP16(length: length),
                            count: byteCount,
                            deallocator: .free)

            varianceData = Data(bytesNoCopy: descriptor.variance.toFP16(length: length),
                                count: byteCount,
                                deallocator: .free)

            scaleData = Data(bytesNoCopy: descriptor.scale.toFP16(length: length),
                             count: byteCount,
                             deallocator: .free)

            biasData = Data(bytesNoCopy: descriptor.bias.toFP16(length: length),
                            count: byteCount,
                            deallocator: .free)
        } else {
            meanData = Data(bytesNoCopy: descriptor.mean,
                            count: byteCount,
                            deallocator: .none)

            varianceData = Data(bytesNoCopy: descriptor.variance,
                                count: byteCount,
                                deallocator: .none)

            scaleData = Data(bytesNoCopy: descriptor.scale,
                             count: byteCount,
                             deallocator: .none)

            biasData = Data(bytesNoCopy: descriptor.bias,
                            count: byteCount,
                            deallocator: .none)
        }

        let meanTensor = graph.constant(meanData,
                                        shape: meanShape,
                                        dataType: dataType)

        let varianceTensor = graph.constant(varianceData,
                                            shape: meanShape,
                                            dataType: dataType)

        let scaleTensor = graph.constant(scaleData,
                                         shape: meanShape,
                                         dataType: dataType)

        let biasTensor = graph.constant(biasData,
                                        shape: meanShape,
                                        dataType: dataType)

        let normalized = graph.normalize(sourceTensor,
                                         mean: meanTensor,
                                         variance: varianceTensor,
                                         gamma: scaleTensor,
                                         beta: biasTensor,
                                         epsilon: descriptor.epsilon,
                                         name: nil)

        resultTensor = graph.multiplication(normalized,
                                            maskTensor,
                                            name: nil)

        assert(resultTensor.shape?.count == 4)
    }
}

@objc
class SWResidualBlockDesc: NSObject {
    let preBN: SWBatchNormLayerDesc
    let preActivation: NSString?
    let regularConv: SWConvLayerDesc
    let midBN: SWBatchNormLayerDesc
    let midActivation: NSString?
    let finalConv: SWConvLayerDesc

    @objc
    init(preBN: SWBatchNormLayerDesc,
         preActivation: NSString?,
         regularConv: SWConvLayerDesc,
         midBN: SWBatchNormLayerDesc,
         midActivation: NSString?,
         finalConv: SWConvLayerDesc) {
        self.preBN = preBN
        self.preActivation = preActivation
        self.regularConv = regularConv
        self.midBN = midBN
        self.midActivation = midActivation
        self.finalConv = finalConv
    }
}

@objc
class ResidualBlock: NSObject {
    let resultTensor: MPSGraphTensor

    @objc
    class func test(descriptor: SWResidualBlockDesc,
                    batchSize: NSNumber,
                    nnXLen: NSNumber,
                    nnYLen: NSNumber,
                    useFP16: Bool,
                    useNHWC: Bool,
                    input: UnsafeMutablePointer<Float32>,
                    mask maskPointer: UnsafeMutablePointer<Float32>,
                    output: UnsafeMutablePointer<Float32>) {

        let device = MPSGraphDevice(mtlDevice: MTLCreateSystemDefaultDevice()!)
        let graph = MPSGraph()

        let source = InputLayer(graph: graph,
                                batchSize: batchSize,
                                nnXLen: nnXLen,
                                nnYLen: nnYLen,
                                numChannels: descriptor.preBN.numChannels,
                                useFP16: useFP16,
                                useNHWC: useNHWC)

        let mask = MaskLayer(graph: graph,
                             batchSize: batchSize,
                             nnXLen: nnXLen,
                             nnYLen: nnYLen,
                             useFP16: useFP16,
                             useNHWC: useNHWC)

        let block = ResidualBlock(graph: graph,
                                  sourceTensor: source.tensor,
                                  maskTensor: mask.tensor,
                                  descriptor: descriptor,
                                  nnXLen: nnXLen,
                                  nnYLen: nnYLen,
                                  batchSize: batchSize,
                                  useFP16: useFP16,
                                  useNHWC: useNHWC)

        let sourceArray = MPSNDArray(device: device.metalDevice!,
                                     tensor: source.tensor)

        let maskArray = MPSNDArray(device: device.metalDevice!,
                                   tensor: mask.tensor)

        if useFP16 {
            let inLength = source.tensor.countElements()
            let maskLength = mask.tensor.countElements()

            sourceArray.writeBytes(input.toFP16(length: inLength))

            maskArray.writeBytes(maskPointer.toFP16(length: maskLength))
        } else {
            sourceArray.writeBytes(input)
            maskArray.writeBytes(maskPointer)
        }

        let sourceTensorData = MPSGraphTensorData(sourceArray)
        let maskTensorData = MPSGraphTensorData(maskArray)

        let fetch = graph.run(feeds: [source.tensor: sourceTensorData,
                                      mask.tensor: maskTensorData],
                              targetTensors: [block.resultTensor],
                              targetOperations: nil)

        if useFP16 {
            let outLength = block.resultTensor.countElements()
            let outputFP16 = UnsafeMutablePointer<Float16>.allocate(capacity: outLength)

            fetch[block.resultTensor]?.mpsndarray().readBytes(outputFP16)

            for i in 0..<outLength {
                output[i] = Float32(outputFP16[i])
            }
        } else {
            fetch[block.resultTensor]?.mpsndarray().readBytes(output)
        }
    }

    init(graph: MPSGraph,
         sourceTensor: MPSGraphTensor,
         maskTensor: MPSGraphTensor,
         descriptor: SWResidualBlockDesc,
         nnXLen: NSNumber,
         nnYLen: NSNumber,
         batchSize: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {
        let preBN = BatchNormLayer(graph: graph,
                                   sourceTensor: sourceTensor,
                                   maskTensor: maskTensor,
                                   descriptor: descriptor.preBN,
                                   nnXLen: nnXLen,
                                   nnYLen: nnYLen,
                                   batchSize: batchSize,
                                   useFP16: useFP16,
                                   useNHWC: useNHWC)

        let preReLU = graph.reLU(with: preBN.resultTensor, name: nil)
        assert(sourceTensor.shape == preReLU.shape)

        let regularConv = ConvLayer(graph: graph,
                                    sourceTensor: preReLU,
                                    descriptor: descriptor.regularConv,
                                    batchSize: batchSize,
                                    nnXLen: nnXLen,
                                    nnYLen: nnYLen,
                                    useFP16: useFP16,
                                    useNHWC: useNHWC)

        let midBN = BatchNormLayer(graph: graph,
                                   sourceTensor: regularConv.resultTensor,
                                   maskTensor: maskTensor,
                                   descriptor: descriptor.midBN,
                                   nnXLen: nnXLen,
                                   nnYLen: nnYLen,
                                   batchSize: batchSize,
                                   useFP16: useFP16,
                                   useNHWC: useNHWC)

        let midReLU = graph.reLU(with: midBN.resultTensor, name: nil)
        assert(regularConv.resultTensor.shape == midReLU.shape)

        let finalConv = ConvLayer(graph: graph,
                                  sourceTensor: midReLU,
                                  descriptor: descriptor.finalConv,
                                  batchSize: batchSize,
                                  nnXLen: nnXLen,
                                  nnYLen: nnYLen,
                                  useFP16: useFP16,
                                  useNHWC: useNHWC)

        resultTensor = graph.addition(sourceTensor,
                                      finalConv.resultTensor,
                                      name: nil)

        assert(resultTensor.shape?.count == 4)
    }
}

class GlobalPoolingLayer {
    let resultTensor: MPSGraphTensor

    init(graph: MPSGraph,
         sourceTensor: MPSGraphTensor,
         maskSumTensor: MPSGraphTensor,
         maskSumSqrtS14M01Tensor: MPSGraphTensor,
         useFP16: Bool,
         useNHWC: Bool) {
        let hwAxes = InputShape.getHWAxes(useNHWC: useNHWC)
        let channelAxis = InputShape.getChannelAxis(useNHWC: useNHWC)

        let sumTensor = graph.reductionSum(with: sourceTensor,
                                           axes: hwAxes,
                                           name: nil)

        let meanTensor = graph.division(sumTensor, maskSumTensor, name: nil)

        let meanMaskTensor = graph.multiplication(meanTensor,
                                                  maskSumSqrtS14M01Tensor,
                                                  name: nil)

        let maxTensor = graph.reductionMaximum(with: sourceTensor,
                                               axes: hwAxes,
                                               name: nil)

        resultTensor = graph.concatTensors([meanTensor,
                                            meanMaskTensor,
                                            maxTensor],
                                           dimension: channelAxis,
                                           name: nil)

        assert(resultTensor.shape?.count == 4)
        assert(useNHWC || (resultTensor.shape?[2] == 1))
        assert(useNHWC || (resultTensor.shape?[3] == 1))
        assert(!useNHWC || (resultTensor.shape?[1] == 1))
        assert(!useNHWC || (resultTensor.shape?[2] == 1))
    }
}

class GlobalPoolingValueLayer {
    let resultTensor: MPSGraphTensor

    init(graph: MPSGraph,
         sourceTensor: MPSGraphTensor,
         maskSumTensor: MPSGraphTensor,
         maskSumSqrtS14M01Tensor: MPSGraphTensor,
         maskSumSqrtS14M01SquareS01Tensor: MPSGraphTensor,
         useFP16: Bool,
         useNHWC: Bool) {
        let hwAxes = InputShape.getHWAxes(useNHWC: useNHWC)
        let channelAxis = InputShape.getChannelAxis(useNHWC: useNHWC)

        let sumTensor = graph.reductionSum(with: sourceTensor,
                                           axes: hwAxes,
                                           name: nil)

        let meanTensor = graph.division(sumTensor, maskSumTensor, name: nil)

        let meanMaskTensor = graph.multiplication(meanTensor,
                                                  maskSumSqrtS14M01Tensor,
                                                  name: nil)

        let meanMaskSquareTensor = graph.multiplication(meanTensor,
                                                        maskSumSqrtS14M01SquareS01Tensor,
                                                        name: nil)

        resultTensor = graph.concatTensors([meanTensor,
                                            meanMaskTensor,
                                            meanMaskSquareTensor],
                                           dimension: channelAxis,
                                           name: nil)

        assert(resultTensor.shape?.count == 4)
        assert(useNHWC || (resultTensor.shape?[2] == 1))
        assert(useNHWC || (resultTensor.shape?[3] == 1))
        assert(!useNHWC || (resultTensor.shape?[1] == 1))
        assert(!useNHWC || (resultTensor.shape?[2] == 1))
    }
}

@objc
class SWMatMulLayerDesc: NSObject {
    let inChannels: NSNumber
    let outChannels: NSNumber
    let weights: UnsafeMutablePointer<Float32>

    @objc
    init(inChannels: NSNumber,
         outChannels: NSNumber,
         weights: UnsafeMutablePointer<Float32>) {
        self.inChannels = inChannels
        self.outChannels = outChannels
        self.weights = weights
    }
}

class MatMulLayer {
    let resultTensor: MPSGraphTensor

    init(graph: MPSGraph,
         descriptor: SWMatMulLayerDesc,
         sourceTensor: MPSGraphTensor,
         useFP16: Bool,
         useNHWC: Bool) {

        assert(useNHWC ||
               (descriptor.outChannels == 1) ||
               (sourceTensor.shape?.count == 2) ||
               ((sourceTensor.shape?.count == 4) &&
                (sourceTensor.shape?[2] == 1) && (sourceTensor.shape?[3] == 1)))

        assert((sourceTensor.shape?.count == 4) || (sourceTensor.shape?[1] == descriptor.inChannels))

        assert((sourceTensor.shape?.count == 2) || useNHWC || (sourceTensor.shape?[1] == descriptor.inChannels))

        assert((sourceTensor.shape?.count == 2) || (!useNHWC) || (sourceTensor.shape?[3] == descriptor.inChannels))

        let dataType = MPSDataType.init(useFP16: useFP16)

        let weightsShape = [descriptor.inChannels,
                            descriptor.outChannels]

        let byteCount = weightsShape.countBytes(of: dataType)
        let weightsData: Data

        if useFP16 {
            let length = weightsShape.countElements()

            weightsData = Data(bytesNoCopy: descriptor.weights.toFP16(length: length),
                               count: byteCount,
                               deallocator: .free)
        } else {
            weightsData = Data(bytesNoCopy: descriptor.weights,
                               count: byteCount,
                               deallocator: .none)
        }

        let weightsTensor = graph.constant(weightsData,
                                           shape: weightsShape,
                                           dataType: dataType)

        let shape = [-1, descriptor.inChannels]

        let reshapedSource = graph.reshape(sourceTensor,
                                           shape: shape,
                                           name: nil)

        resultTensor = graph.matrixMultiplication(primary: reshapedSource,
                                                  secondary: weightsTensor,
                                                  name: nil)

        assert(resultTensor.shape?.count == 2)
    }
}

@objc
class SWMatBiasLayerDesc: NSObject {
    let numChannels: NSNumber
    let weights: UnsafeMutablePointer<Float32>

    @objc
    init(numChannels: NSNumber,
         weights: UnsafeMutablePointer<Float32>) {
        self.numChannels = numChannels
        self.weights = weights
    }
}

class MatBiasLayer {
    let resultTensor: MPSGraphTensor

    init(graph: MPSGraph,
         descriptor: SWMatBiasLayerDesc,
         sourceTensor: MPSGraphTensor,
         useFP16: Bool,
         useNHWC: Bool) {

        assert((sourceTensor.shape?.count == 2) && (sourceTensor.shape?[1] == descriptor.numChannels))

        let dataType = MPSDataType.init(useFP16: useFP16)
        let weightsShape = [1, descriptor.numChannels]
        let byteCount = weightsShape.countBytes(of: dataType)
        let weightsData: Data

        if useFP16 {
            let length = weightsShape.countElements()

            weightsData = Data(bytesNoCopy: descriptor.weights.toFP16(length: length),
                               count: byteCount,
                               deallocator: .free)
        } else {
            weightsData = Data(bytesNoCopy: descriptor.weights,
                               count: byteCount,
                               deallocator: .none)
        }

        let weightsTensor = graph.constant(weightsData,
                                           shape: weightsShape,
                                           dataType: dataType)

        resultTensor = graph.addition(sourceTensor,
                                      weightsTensor,
                                      name: nil)
    }
}

class AddNCBiasLayer {
    let resultTensor: MPSGraphTensor

    init(graph: MPSGraph,
         sourceTensor: MPSGraphTensor,
         biasTensor: MPSGraphTensor,
         batchSize: NSNumber,
         nnXLen: NSNumber,
         nnYLen: NSNumber,
         numChannels: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {
        let shape = InputShape.create(batchSize: batchSize,
                                      numChannels: numChannels,
                                      nnYLen: 1,
                                      nnXLen: 1,
                                      useNHWC: useNHWC)

        assert(biasTensor.countElements() == shape.countElements())
        let reshaped = graph.reshape(biasTensor, shape: shape, name: nil)
        resultTensor = graph.addition(sourceTensor, reshaped, name: nil)

        assert(resultTensor.shape?.count == 4)
        assert(useNHWC || resultTensor.shape?[2] == nnYLen)
        assert(useNHWC || resultTensor.shape?[3] == nnXLen)
        assert(!useNHWC || resultTensor.shape?[1] == nnYLen)
        assert(!useNHWC || resultTensor.shape?[2] == nnXLen)
    }
}

@objc
class SWGlobalPoolingResidualBlockDesc: NSObject {
    let preBN: SWBatchNormLayerDesc
    let preActivation: NSString?
    let regularConv: SWConvLayerDesc
    let gpoolConv: SWConvLayerDesc
    let gpoolBN: SWBatchNormLayerDesc
    let gpoolActivation: NSString?
    let gpoolToBiasMul: SWMatMulLayerDesc
    let midBN: SWBatchNormLayerDesc
    let midActivation: NSString?
    let finalConv: SWConvLayerDesc

    @objc
    init(preBN: SWBatchNormLayerDesc,
         preActivation: NSString?,
         regularConv: SWConvLayerDesc,
         gpoolConv: SWConvLayerDesc,
         gpoolBN: SWBatchNormLayerDesc,
         gpoolActivation: NSString?,
         gpoolToBiasMul: SWMatMulLayerDesc,
         midBN: SWBatchNormLayerDesc,
         midActivation: NSString?,
         finalConv: SWConvLayerDesc) {
        self.preBN = preBN
        self.preActivation = preActivation
        self.regularConv = regularConv
        self.gpoolConv = gpoolConv
        self.gpoolBN = gpoolBN
        self.gpoolActivation = gpoolActivation
        self.gpoolToBiasMul = gpoolToBiasMul
        self.midBN = midBN
        self.midActivation = midActivation
        self.finalConv = finalConv
    }
}

@objc
class GlobalPoolingResidualBlock: NSObject {
    let resultTensor: MPSGraphTensor

    @objc
    class func test(descriptor: SWGlobalPoolingResidualBlockDesc,
                    batchSize: NSNumber,
                    nnXLen: NSNumber,
                    nnYLen: NSNumber,
                    useFP16: Bool,
                    useNHWC: Bool,
                    input: UnsafeMutablePointer<Float32>,
                    mask maskPointer: UnsafeMutablePointer<Float32>,
                    output: UnsafeMutablePointer<Float32>) {

        let device = MPSGraphDevice(mtlDevice: MTLCreateSystemDefaultDevice()!)
        let graph = MPSGraph()

        let source = InputLayer(graph: graph,
                                batchSize: batchSize,
                                nnXLen: nnXLen,
                                nnYLen: nnYLen,
                                numChannels: descriptor.preBN.numChannels,
                                useFP16: useFP16,
                                useNHWC: useNHWC)

        let mask = MaskLayer(graph: graph,
                             batchSize: batchSize,
                             nnXLen: nnXLen,
                             nnYLen: nnYLen,
                             useFP16: useFP16,
                             useNHWC: useNHWC)

        let maskSum = MaskSumLayer(graph: graph, mask: mask, useNHWC: useNHWC)

        let maskSumSqrtS14M01 = MaskSumSqrtS14M01Layer(graph: graph,
                                                       maskSum: maskSum,
                                                       useFP16: useFP16)

        let block =
        GlobalPoolingResidualBlock(graph: graph,
                                   sourceTensor: source.tensor,
                                   maskTensor: mask.tensor,
                                   maskSumTensor: maskSum.tensor,
                                   maskSumSqrtS14M01Tensor: maskSumSqrtS14M01.tensor,
                                   descriptor: descriptor,
                                   nnXLen: nnXLen,
                                   nnYLen: nnYLen,
                                   batchSize: batchSize,
                                   useFP16: useFP16,
                                   useNHWC: useNHWC)

        let sourceArray = MPSNDArray(device: device.metalDevice!,
                                     tensor: source.tensor)

        let maskArray = MPSNDArray(device: device.metalDevice!,
                                   tensor: mask.tensor)

        if useFP16 {
            let inLength = source.tensor.countElements()
            let maskLength = mask.tensor.countElements()

            sourceArray.writeBytes(input.toFP16(length: inLength))

            maskArray.writeBytes(maskPointer.toFP16(length: maskLength))
        } else {
            sourceArray.writeBytes(input)
            maskArray.writeBytes(maskPointer)
        }

        let sourceTensorData = MPSGraphTensorData(sourceArray)
        let maskTensorData = MPSGraphTensorData(maskArray)

        let fetch = graph.run(feeds: [source.tensor: sourceTensorData,
                                      mask.tensor: maskTensorData],
                              targetTensors: [block.resultTensor],
                              targetOperations: nil)

        if useFP16 {
            let outLength = block.resultTensor.countElements()
            let outputFP16 = UnsafeMutablePointer<Float16>.allocate(capacity: outLength)

            fetch[block.resultTensor]?.mpsndarray().readBytes(outputFP16)

            for i in 0..<outLength {
                output[i] = Float32(outputFP16[i])
            }
        } else {
            fetch[block.resultTensor]?.mpsndarray().readBytes(output)
        }
    }

    init(graph: MPSGraph,
         sourceTensor: MPSGraphTensor,
         maskTensor: MPSGraphTensor,
         maskSumTensor: MPSGraphTensor,
         maskSumSqrtS14M01Tensor: MPSGraphTensor,
         descriptor: SWGlobalPoolingResidualBlockDesc,
         nnXLen: NSNumber,
         nnYLen: NSNumber,
         batchSize: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {
        let mask = MaskLayer(tensor: maskTensor)
        let maskSum = MaskSumLayer(tensor: maskSumTensor)
        let maskSumSqrtS14M01 = MaskSumSqrtS14M01Layer(tensor: maskSumSqrtS14M01Tensor)

        let preBN = BatchNormLayer(graph: graph,
                                   sourceTensor: sourceTensor,
                                   maskTensor: mask.tensor,
                                   descriptor: descriptor.preBN,
                                   nnXLen: nnXLen,
                                   nnYLen: nnYLen,
                                   batchSize: batchSize,
                                   useFP16: useFP16,
                                   useNHWC: useNHWC)

        let preReLU = graph.reLU(with: preBN.resultTensor, name: nil)

        let regularConv = ConvLayer(graph: graph,
                                    sourceTensor: preReLU,
                                    descriptor: descriptor.regularConv,
                                    batchSize: batchSize,
                                    nnXLen: nnXLen,
                                    nnYLen: nnYLen,
                                    useFP16: useFP16,
                                    useNHWC: useNHWC)

        let gpoolConv = ConvLayer(graph: graph,
                                  sourceTensor: preReLU,
                                  descriptor: descriptor.gpoolConv,
                                  batchSize: batchSize,
                                  nnXLen: nnXLen,
                                  nnYLen: nnYLen,
                                  useFP16: useFP16,
                                  useNHWC: useNHWC)

        let gpoolBN = BatchNormLayer(graph: graph,
                                     sourceTensor: gpoolConv.resultTensor,
                                     maskTensor: mask.tensor,
                                     descriptor: descriptor.gpoolBN,
                                     nnXLen: nnXLen,
                                     nnYLen: nnYLen,
                                     batchSize: batchSize,
                                     useFP16: useFP16,
                                     useNHWC: useNHWC)

        let gpoolReLU = graph.reLU(with: gpoolBN.resultTensor, name: nil)

        let gpoolConcat = GlobalPoolingLayer(graph: graph,
                                             sourceTensor: gpoolReLU,
                                             maskSumTensor: maskSum.tensor,
                                             maskSumSqrtS14M01Tensor: maskSumSqrtS14M01.tensor,
                                             useFP16: useFP16,
                                             useNHWC: useNHWC)

        assert(useNHWC || (gpoolConcat.resultTensor.shape?[1] == descriptor.gpoolToBiasMul.inChannels))
        assert(!useNHWC || (gpoolConcat.resultTensor.shape?[3] == descriptor.gpoolToBiasMul.inChannels))

        let gpoolToBiasMul = MatMulLayer(graph: graph,
                                         descriptor: descriptor.gpoolToBiasMul,
                                         sourceTensor: gpoolConcat.resultTensor,
                                         useFP16: useFP16,
                                         useNHWC: useNHWC)

        let added = AddNCBiasLayer(graph: graph,
                                   sourceTensor: regularConv.resultTensor,
                                   biasTensor: gpoolToBiasMul.resultTensor,
                                   batchSize: batchSize,
                                   nnXLen: nnXLen,
                                   nnYLen: nnYLen,
                                   numChannels: descriptor.gpoolToBiasMul.outChannels,
                                   useFP16: useFP16,
                                   useNHWC: useNHWC)

        let midBN = BatchNormLayer(graph: graph,
                                   sourceTensor: added.resultTensor,
                                   maskTensor: mask.tensor,
                                   descriptor: descriptor.midBN,
                                   nnXLen: nnXLen,
                                   nnYLen: nnYLen,
                                   batchSize: batchSize,
                                   useFP16: useFP16,
                                   useNHWC: useNHWC)

        let midReLU = graph.reLU(with: midBN.resultTensor, name: nil)

        let finalConv = ConvLayer(graph: graph,
                                  sourceTensor: midReLU,
                                  descriptor: descriptor.finalConv,
                                  batchSize: batchSize,
                                  nnXLen: nnXLen,
                                  nnYLen: nnYLen,
                                  useFP16: useFP16,
                                  useNHWC: useNHWC)

        resultTensor = graph.addition(sourceTensor,
                                      finalConv.resultTensor,
                                      name: nil)

        assert(resultTensor.shape?.count == 4)
    }
}

@objc
enum BlockKind: Int {
    case ordinary
    case dilated
    case globalPooling
}

@objc
class BlockDescriptor: NSObject {
    let kind: BlockKind
    let ordinary: SWResidualBlockDesc?
    let globalPooling: SWGlobalPoolingResidualBlockDesc?

    @objc
    init(kind: BlockKind,
         ordinary: SWResidualBlockDesc?,
         globalPooling: SWGlobalPoolingResidualBlockDesc?) {
        self.kind = kind
        self.ordinary = ordinary
        self.globalPooling = globalPooling
    }
}

@objc
class SWTrunkDesc: NSObject {
    let version: Int
    let trunkNumChannels: NSNumber
    let midNumChannels: NSNumber
    let regularNumChannels: NSNumber
    let dilatedNumChannels: NSNumber
    let gpoolNumChannels: NSNumber
    let initialConv: SWConvLayerDesc
    let initialMatMul: SWMatMulLayerDesc
    let blocks: [BlockDescriptor]
    let trunkTipBN: SWBatchNormLayerDesc

    @objc
    init(version: Int,
         trunkNumChannels: NSNumber,
         midNumChannels: NSNumber,
         regularNumChannels: NSNumber,
         dilatedNumChannels: NSNumber,
         gpoolNumChannels: NSNumber,
         initialConv: SWConvLayerDesc,
         initialMatMul: SWMatMulLayerDesc,
         blocks: [BlockDescriptor],
         trunkTipBN: SWBatchNormLayerDesc) {
        self.version = version
        self.trunkNumChannels = trunkNumChannels
        self.midNumChannels = midNumChannels
        self.regularNumChannels = regularNumChannels
        self.dilatedNumChannels = dilatedNumChannels
        self.gpoolNumChannels = gpoolNumChannels
        self.initialConv = initialConv
        self.initialMatMul = initialMatMul
        self.blocks = blocks
        self.trunkTipBN = trunkTipBN
    }
}

class Trunk {
    let resultTensor: MPSGraphTensor

    init(graph: MPSGraph,
         descriptor: SWTrunkDesc,
         inputTensor: MPSGraphTensor,
         inputGlobalTensor: MPSGraphTensor,
         maskTensor: MPSGraphTensor,
         maskSumTensor: MPSGraphTensor,
         maskSumSqrtS14M01Tensor: MPSGraphTensor,
         nnXLen: NSNumber,
         nnYLen: NSNumber,
         batchSize: NSNumber,
         numSpatialFeatures: NSNumber,
         numGlobalFeatures: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {

        let initialConv = ConvLayer(graph: graph,
                                    sourceTensor: inputTensor,
                                    descriptor: descriptor.initialConv,
                                    batchSize: batchSize,
                                    nnXLen: nnXLen,
                                    nnYLen: nnYLen,
                                    useFP16: useFP16,
                                    useNHWC: useNHWC)

        let initialMatMul = MatMulLayer(graph: graph,
                                        descriptor: descriptor.initialMatMul,
                                        sourceTensor: inputGlobalTensor,
                                        useFP16: useFP16,
                                        useNHWC: useNHWC)

        let added = AddNCBiasLayer(graph: graph,
                                   sourceTensor: initialConv.resultTensor,
                                   biasTensor: initialMatMul.resultTensor,
                                   batchSize: batchSize,
                                   nnXLen: nnXLen,
                                   nnYLen: nnYLen,
                                   numChannels: descriptor.initialMatMul.outChannels,
                                   useFP16: useFP16,
                                   useNHWC: useNHWC)

        var blockInput = added.resultTensor

        for block in descriptor.blocks {
            assert((block.kind == .ordinary) || (block.kind == .globalPooling))

            switch block.kind {
            case .ordinary:
                let ordinary = ResidualBlock(graph: graph,
                                             sourceTensor: blockInput,
                                             maskTensor: maskTensor,
                                             descriptor: block.ordinary!,
                                             nnXLen: nnXLen,
                                             nnYLen: nnYLen,
                                             batchSize: batchSize,
                                             useFP16: useFP16,
                                             useNHWC: useNHWC)

                blockInput = ordinary.resultTensor
            default:
                let globalPooling =
                GlobalPoolingResidualBlock(graph: graph,
                                           sourceTensor: blockInput,
                                           maskTensor: maskTensor,
                                           maskSumTensor: maskSumTensor,
                                           maskSumSqrtS14M01Tensor: maskSumSqrtS14M01Tensor,
                                           descriptor: block.globalPooling!,
                                           nnXLen: nnXLen,
                                           nnYLen: nnYLen,
                                           batchSize: batchSize,
                                           useFP16: useFP16,
                                           useNHWC: useNHWC)

                blockInput = globalPooling.resultTensor
            }
        }

        let trunkTipBN = BatchNormLayer(graph: graph,
                                        sourceTensor: blockInput,
                                        maskTensor: maskTensor,
                                        descriptor: descriptor.trunkTipBN,
                                        nnXLen: nnXLen,
                                        nnYLen: nnYLen,
                                        batchSize: batchSize,
                                        useFP16: useFP16,
                                        useNHWC: useNHWC)

        let trunkTipReLU = graph.reLU(with: trunkTipBN.resultTensor, name: nil)

        resultTensor = trunkTipReLU

        assert(resultTensor.shape?.count == 4)
    }
}

@objc
class SWPolicyHeadDesc: NSObject {
    let version: Int
    let p1Conv: SWConvLayerDesc
    let g1Conv: SWConvLayerDesc
    let g1BN: SWBatchNormLayerDesc
    let gpoolToBiasMul: SWMatMulLayerDesc
    let p1BN: SWBatchNormLayerDesc
    let p2Conv: SWConvLayerDesc
    let gpoolToPassMul: SWMatMulLayerDesc

    @objc
    init(version: Int,
         p1Conv: SWConvLayerDesc,
         g1Conv: SWConvLayerDesc,
         g1BN: SWBatchNormLayerDesc,
         gpoolToBiasMul: SWMatMulLayerDesc,
         p1BN: SWBatchNormLayerDesc,
         p2Conv: SWConvLayerDesc,
         gpoolToPassMul: SWMatMulLayerDesc) {
        self.version = version
        self.p1Conv = p1Conv
        self.g1Conv = g1Conv
        self.g1BN = g1BN
        self.gpoolToBiasMul = gpoolToBiasMul
        self.p1BN = p1BN
        self.p2Conv = p2Conv
        self.gpoolToPassMul = gpoolToPassMul
    }
}

class PolicyHead {
    let policyTensor: MPSGraphTensor
    let policyPassTensor: MPSGraphTensor

    init(graph: MPSGraph,
         descriptor: SWPolicyHeadDesc,
         sourceTensor: MPSGraphTensor,
         maskTensor: MPSGraphTensor,
         maskSumTensor: MPSGraphTensor,
         maskSumSqrtS14M01Tensor: MPSGraphTensor,
         nnXLen: NSNumber,
         nnYLen: NSNumber,
         batchSize: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {

        let p1Conv = ConvLayer(graph: graph,
                               sourceTensor: sourceTensor,
                               descriptor: descriptor.p1Conv,
                               batchSize: batchSize,
                               nnXLen: nnXLen,
                               nnYLen: nnYLen,
                               useFP16: useFP16,
                               useNHWC: useNHWC)

        let g1Conv = ConvLayer(graph: graph,
                               sourceTensor: sourceTensor,
                               descriptor: descriptor.g1Conv,
                               batchSize: batchSize,
                               nnXLen: nnXLen,
                               nnYLen: nnYLen,
                               useFP16: useFP16,
                               useNHWC: useNHWC)

        let g1BN = BatchNormLayer(graph: graph,
                                  sourceTensor: g1Conv.resultTensor,
                                  maskTensor: maskTensor,
                                  descriptor: descriptor.g1BN,
                                  nnXLen: nnXLen,
                                  nnYLen: nnYLen,
                                  batchSize: batchSize,
                                  useFP16: useFP16,
                                  useNHWC: useNHWC)

        let g1ReLU = graph.reLU(with: g1BN.resultTensor, name: nil)

        let g1Concat = GlobalPoolingLayer(graph: graph,
                                          sourceTensor: g1ReLU,
                                          maskSumTensor: maskSumTensor,
                                          maskSumSqrtS14M01Tensor: maskSumSqrtS14M01Tensor,
                                          useFP16: useFP16,
                                          useNHWC: useNHWC)

        assert(useNHWC || (g1Concat.resultTensor.shape?[1] == descriptor.gpoolToBiasMul.inChannels))
        assert(!useNHWC || (g1Concat.resultTensor.shape?[3] == descriptor.gpoolToBiasMul.inChannels))

        let gpoolToBiasMul = MatMulLayer(graph: graph,
                                         descriptor: descriptor.gpoolToBiasMul,
                                         sourceTensor: g1Concat.resultTensor,
                                         useFP16: useFP16,
                                         useNHWC: useNHWC)

        let added = AddNCBiasLayer(graph: graph,
                                   sourceTensor: p1Conv.resultTensor,
                                   biasTensor: gpoolToBiasMul.resultTensor,
                                   batchSize: batchSize,
                                   nnXLen: nnXLen,
                                   nnYLen: nnYLen,
                                   numChannels: descriptor.gpoolToBiasMul.outChannels,
                                   useFP16: useFP16,
                                   useNHWC: useNHWC)

        let p1BN = BatchNormLayer(graph: graph,
                                  sourceTensor: added.resultTensor,
                                  maskTensor: maskTensor,
                                  descriptor: descriptor.p1BN,
                                  nnXLen: nnXLen,
                                  nnYLen: nnYLen,
                                  batchSize: batchSize,
                                  useFP16: useFP16,
                                  useNHWC: useNHWC)

        let p1ReLU = graph.reLU(with: p1BN.resultTensor, name: nil)

        let p2Conv = ConvLayer(graph: graph,
                               sourceTensor: p1ReLU,
                               descriptor: descriptor.p2Conv,
                               batchSize: batchSize,
                               nnXLen: nnXLen,
                               nnYLen: nnYLen,
                               useFP16: useFP16,
                               useNHWC: useNHWC)

        assert(useNHWC || (g1Concat.resultTensor.shape?[1] == descriptor.gpoolToPassMul.inChannels))
        assert(!useNHWC || (g1Concat.resultTensor.shape?[3] == descriptor.gpoolToPassMul.inChannels))

        let gpoolToPassMul = MatMulLayer(graph: graph,
                                         descriptor: descriptor.gpoolToPassMul,
                                         sourceTensor: g1Concat.resultTensor,
                                         useFP16: useFP16,
                                         useNHWC: useNHWC)

        policyTensor = p2Conv.resultTensor
        policyPassTensor = gpoolToPassMul.resultTensor

        assert(policyTensor.shape?.count == 4)
        assert(policyPassTensor.shape?.count == 2)
    }
}

@objc
class SWValueHeadDesc: NSObject {
    let version: Int
    let v1Conv: SWConvLayerDesc
    let v1BN: SWBatchNormLayerDesc
    let v2Mul: SWMatMulLayerDesc
    let v2Bias: SWMatBiasLayerDesc
    let v3Mul: SWMatMulLayerDesc
    let v3Bias: SWMatBiasLayerDesc
    let sv3Mul: SWMatMulLayerDesc
    let sv3Bias: SWMatBiasLayerDesc
    let vOwnershipConv: SWConvLayerDesc

    @objc
    init(version: Int, v1Conv: SWConvLayerDesc, v1BN: SWBatchNormLayerDesc, v2Mul: SWMatMulLayerDesc, v2Bias: SWMatBiasLayerDesc, v3Mul: SWMatMulLayerDesc, v3Bias: SWMatBiasLayerDesc, sv3Mul: SWMatMulLayerDesc, sv3Bias: SWMatBiasLayerDesc, vOwnershipConv: SWConvLayerDesc) {
        self.version = version
        self.v1Conv = v1Conv
        self.v1BN = v1BN
        self.v2Mul = v2Mul
        self.v2Bias = v2Bias
        self.v3Mul = v3Mul
        self.v3Bias = v3Bias
        self.sv3Mul = sv3Mul
        self.sv3Bias = sv3Bias
        self.vOwnershipConv = vOwnershipConv
    }
}

class ValueHead {
    let valueTensor: MPSGraphTensor
    let scoreValueTensor: MPSGraphTensor
    let ownershipTensor: MPSGraphTensor

    init(graph: MPSGraph,
         descriptor: SWValueHeadDesc,
         sourceTensor: MPSGraphTensor,
         maskTensor: MPSGraphTensor,
         maskSumTensor: MPSGraphTensor,
         maskSumSqrtS14M01Tensor: MPSGraphTensor,
         maskSumSqrtS14M01SquareS01Tensor: MPSGraphTensor,
         nnXLen: NSNumber,
         nnYLen: NSNumber,
         batchSize: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {

        let v1Conv = ConvLayer(graph: graph,
                               sourceTensor: sourceTensor,
                               descriptor: descriptor.v1Conv,
                               batchSize: batchSize,
                               nnXLen: nnXLen,
                               nnYLen: nnYLen,
                               useFP16: useFP16,
                               useNHWC: useNHWC)

        let v1BN = BatchNormLayer(graph: graph,
                                  sourceTensor: v1Conv.resultTensor,
                                  maskTensor: maskTensor,
                                  descriptor: descriptor.v1BN,
                                  nnXLen: nnXLen,
                                  nnYLen: nnYLen,
                                  batchSize: batchSize,
                                  useFP16: useFP16,
                                  useNHWC: useNHWC)

        let v1ReLU = graph.reLU(with: v1BN.resultTensor, name: nil)

        let v1Mean =
        GlobalPoolingValueLayer(graph: graph,
                                sourceTensor: v1ReLU,
                                maskSumTensor: maskSumTensor,
                                maskSumSqrtS14M01Tensor: maskSumSqrtS14M01Tensor,
                                maskSumSqrtS14M01SquareS01Tensor: maskSumSqrtS14M01SquareS01Tensor,
                                useFP16: useFP16,
                                useNHWC: useNHWC)

        assert(useNHWC || (v1Mean.resultTensor.shape?[1] == descriptor.v2Mul.inChannels))
        assert(!useNHWC || (v1Mean.resultTensor.shape?[3] == descriptor.v2Mul.inChannels))

        let v2Mul = MatMulLayer(graph: graph,
                                descriptor: descriptor.v2Mul,
                                sourceTensor: v1Mean.resultTensor,
                                useFP16: useFP16,
                                useNHWC: useNHWC)

        let v2Bias = MatBiasLayer(graph: graph,
                                  descriptor: descriptor.v2Bias,
                                  sourceTensor: v2Mul.resultTensor,
                                  useFP16: useFP16,
                                  useNHWC: useNHWC)

        let v2ReLU = graph.reLU(with: v2Bias.resultTensor, name: nil)

        let v3Mul = MatMulLayer(graph: graph,
                                descriptor: descriptor.v3Mul,
                                sourceTensor: v2ReLU,
                                useFP16: useFP16,
                                useNHWC: useNHWC)

        let v3Bias = MatBiasLayer(graph: graph,
                                  descriptor: descriptor.v3Bias,
                                  sourceTensor: v3Mul.resultTensor,
                                  useFP16: useFP16,
                                  useNHWC: useNHWC)

        let sv3Mul = MatMulLayer(graph: graph,
                                 descriptor: descriptor.sv3Mul,
                                 sourceTensor: v2ReLU,
                                 useFP16: useFP16,
                                 useNHWC: useNHWC)

        let sv3Bias = MatBiasLayer(graph: graph,
                                   descriptor: descriptor.sv3Bias,
                                   sourceTensor: sv3Mul.resultTensor,
                                   useFP16: useFP16,
                                   useNHWC: useNHWC)

        let vOwnershipConv = ConvLayer(graph: graph,
                                       sourceTensor: v1ReLU,
                                       descriptor: descriptor.vOwnershipConv,
                                       batchSize: batchSize,
                                       nnXLen: nnXLen,
                                       nnYLen: nnYLen,
                                       useFP16: useFP16,
                                       useNHWC: useNHWC)

        valueTensor = v3Bias.resultTensor
        scoreValueTensor = sv3Bias.resultTensor
        ownershipTensor = vOwnershipConv.resultTensor

        assert(valueTensor.shape?.count == 2)
        assert(scoreValueTensor.shape?.count == 2)
        assert(ownershipTensor.shape?.count == 4)
    }
}

@objc
class SWModelDesc : NSObject {
    let version: Int
    let name: String
    let numInputChannels: NSNumber
    let numInputGlobalChannels: NSNumber
    let numValueChannels: NSNumber
    let numScoreValueChannels: NSNumber
    let numOwnershipChannels: NSNumber
    let trunk: SWTrunkDesc
    let policyHead: SWPolicyHeadDesc
    let valueHead: SWValueHeadDesc

    @objc
    init(version: Int,
         name: String,
         numInputChannels: NSNumber,
         numInputGlobalChannels: NSNumber,
         numValueChannels: NSNumber,
         numScoreValueChannels: NSNumber,
         numOwnershipChannels: NSNumber,
         trunk: SWTrunkDesc,
         policyHead: SWPolicyHeadDesc,
         valueHead: SWValueHeadDesc) {
        self.version = version
        self.name = name
        self.numInputChannels = numInputChannels
        self.numInputGlobalChannels = numInputGlobalChannels
        self.numValueChannels = numValueChannels
        self.numScoreValueChannels = numScoreValueChannels
        self.numOwnershipChannels = numOwnershipChannels
        self.trunk = trunk
        self.policyHead = policyHead
        self.valueHead = valueHead
    }
}

class Model {
    let graph: MPSGraph
    let nnXLen: NSNumber
    let nnYLen: NSNumber
    let batchSize: NSNumber
    let useFP16: Bool
    let version: Int
    let numInputChannels: NSNumber
    let numInputGlobalChannels: NSNumber
    let numValueChannels: NSNumber
    let numScoreValueChannels: NSNumber
    let numOwnershipChannels: NSNumber
    let commandQueue: MTLCommandQueue
    let input: InputLayer
    let inputGlobal: InputGlobalLayer
    let trunk: Trunk
    let policyHead: PolicyHead
    let valueHead: ValueHead
    let inputCount: Int
    let inputFP16: UnsafeMutablePointer<Float16>?
    let inputGlobalCount: Int
    let inputGlobalFP16: UnsafeMutablePointer<Float16>?
    let policyCount: Int
    let policyFP16: UnsafeMutablePointer<Float16>?
    let policyPassCount: Int
    let policyPassFP16: UnsafeMutablePointer<Float16>?
    let valueCount: Int
    let valueFP16: UnsafeMutablePointer<Float16>?
    let scoreValueCount: Int
    let scoreValueFP16: UnsafeMutablePointer<Float16>?
    let ownershipCount: Int
    let ownershipFP16: UnsafeMutablePointer<Float16>?
    let inputArray: MPSNDArray
    let inputGlobalArray: MPSNDArray
    let feeds: [MPSGraphTensor: MPSGraphTensorData]
    let targetTensors: [MPSGraphTensor]

    init(device: MPSGraphDevice,
         graph: MPSGraph,
         descriptor: SWModelDesc,
         nnXLen: NSNumber,
         nnYLen: NSNumber,
         batchSize: NSNumber,
         useFP16: Bool,
         useNHWC: Bool) {
        self.graph = graph
        self.nnXLen = nnXLen
        self.nnYLen = nnYLen
        self.batchSize = batchSize
        self.useFP16 = useFP16
        self.version = descriptor.version
        self.numInputChannels = descriptor.numInputChannels
        self.numInputGlobalChannels = descriptor.numInputGlobalChannels
        self.numValueChannels = descriptor.numValueChannels
        self.numScoreValueChannels = descriptor.numScoreValueChannels
        self.numOwnershipChannels = descriptor.numOwnershipChannels
        commandQueue = (device.metalDevice?.makeCommandQueue())!

        input = InputLayer(graph: graph,
                           batchSize: batchSize,
                           nnXLen: nnXLen,
                           nnYLen: nnYLen,
                           numChannels: descriptor.numInputChannels,
                           useFP16: useFP16,
                           useNHWC: useNHWC)

        inputGlobal = InputGlobalLayer(graph: graph,
                                       batchSize: batchSize,
                                       numGlobalFeatures: descriptor.numInputGlobalChannels,
                                       useFP16: useFP16,
                                       useNHWC: useNHWC)

        let startOfMask: [NSNumber] = [0, 0, 0, 0]

        let endOfMask = InputShape.create(batchSize: batchSize,
                                          numChannels: 1,
                                          nnYLen: nnYLen,
                                          nnXLen: nnXLen,
                                          useNHWC: useNHWC)

        let maskTensor = graph.sliceTensor(input.tensor,
                                           starts: startOfMask,
                                           ends: endOfMask,
                                           strides: [1, 1, 1, 1],
                                           name: nil)

        let mask = MaskLayer(tensor: maskTensor)

        let maskSum = MaskSumLayer(graph: graph,
                                   mask: mask,
                                   useNHWC: useNHWC)

        let maskSumSqrtS14M01 = MaskSumSqrtS14M01Layer(graph: graph,
                                                       maskSum: maskSum,
                                                       useFP16: useFP16)

        let maskSumSqrtS14M01SquareS01 = MaskSumSqrtS14M01SquareS01Layer(graph: graph,
                                                                         maskSumSqrtS14M01: maskSumSqrtS14M01,
                                                                         useFP16: useFP16)

        trunk = Trunk(graph: graph,
                      descriptor: descriptor.trunk,
                      inputTensor: input.tensor,
                      inputGlobalTensor: inputGlobal.tensor,
                      maskTensor: mask.tensor,
                      maskSumTensor: maskSum.tensor,
                      maskSumSqrtS14M01Tensor: maskSumSqrtS14M01.tensor,
                      nnXLen: nnXLen,
                      nnYLen: nnYLen,
                      batchSize: batchSize,
                      numSpatialFeatures: descriptor.numInputChannels,
                      numGlobalFeatures: descriptor.numInputGlobalChannels,
                      useFP16: useFP16,
                      useNHWC: useNHWC)

        policyHead = PolicyHead(graph: graph,
                                descriptor: descriptor.policyHead,
                                sourceTensor: trunk.resultTensor,
                                maskTensor: mask.tensor,
                                maskSumTensor: maskSum.tensor,
                                maskSumSqrtS14M01Tensor: maskSumSqrtS14M01.tensor,
                                nnXLen: nnXLen,
                                nnYLen: nnYLen,
                                batchSize: batchSize,
                                useFP16: useFP16,
                                useNHWC: useNHWC)

        valueHead = ValueHead(graph: graph,
                              descriptor: descriptor.valueHead,
                              sourceTensor: trunk.resultTensor,
                              maskTensor: mask.tensor,
                              maskSumTensor: maskSum.tensor,
                              maskSumSqrtS14M01Tensor: maskSumSqrtS14M01.tensor,
                              maskSumSqrtS14M01SquareS01Tensor: maskSumSqrtS14M01SquareS01.tensor,
                              nnXLen: nnXLen,
                              nnYLen: nnYLen,
                              batchSize: batchSize,
                              useFP16: useFP16,
                              useNHWC: useNHWC)

        inputCount = input.tensor.countElements()
        inputGlobalCount = inputGlobal.tensor.countElements()
        policyCount = policyHead.policyTensor.countElements()
        policyPassCount = policyHead.policyPassTensor.countElements()
        valueCount = valueHead.valueTensor.countElements()
        scoreValueCount = valueHead.scoreValueTensor.countElements()
        ownershipCount = valueHead.ownershipTensor.countElements()

        if useFP16 {
            inputFP16 = UnsafeMutablePointer<Float16>.allocate(capacity: inputCount)
            inputGlobalFP16 = UnsafeMutablePointer<Float16>.allocate(capacity: inputGlobalCount)
            policyFP16 = UnsafeMutablePointer<Float16>.allocate(capacity: policyCount)
            policyPassFP16 = UnsafeMutablePointer<Float16>.allocate(capacity: policyPassCount)
            valueFP16 = UnsafeMutablePointer<Float16>.allocate(capacity: valueCount)
            scoreValueFP16 = UnsafeMutablePointer<Float16>.allocate(capacity: scoreValueCount)
            ownershipFP16 = UnsafeMutablePointer<Float16>.allocate(capacity: ownershipCount)
        } else {
            inputFP16 = nil
            inputGlobalFP16 = nil
            policyFP16 = nil
            policyPassFP16 = nil
            valueFP16 = nil
            scoreValueFP16 = nil
            ownershipFP16 = nil
        }

        inputArray = MPSNDArray(device: device.metalDevice!,
                                tensor: input.tensor)

        inputGlobalArray = MPSNDArray(device: device.metalDevice!,
                                      tensor: inputGlobal.tensor)

        feeds = [input.tensor: MPSGraphTensorData(inputArray),
                 inputGlobal.tensor: MPSGraphTensorData(inputGlobalArray)]

        targetTensors = [policyHead.policyTensor,
                         policyHead.policyPassTensor,
                         valueHead.valueTensor,
                         valueHead.scoreValueTensor,
                         valueHead.ownershipTensor]
    }

    func apply(input inputPointer: UnsafeMutablePointer<Float32>,
               inputGlobal inputGlobalPointer: UnsafeMutablePointer<Float32>,
               policy: UnsafeMutablePointer<Float32>,
               policyPass: UnsafeMutablePointer<Float32>,
               value: UnsafeMutablePointer<Float32>,
               scoreValue: UnsafeMutablePointer<Float32>,
               ownership: UnsafeMutablePointer<Float32>) {
        if let inputFP16 {
            assert(useFP16)
            inputPointer.toFP16(inputFP16, length: inputCount)
            inputArray.writeBytes(inputFP16)
        } else {
            assert(!useFP16)
            inputArray.writeBytes(inputPointer)
        }

        if let inputGlobalFP16 {
            inputGlobalPointer.toFP16(inputGlobalFP16, length: inputGlobalCount)
            inputGlobalArray.writeBytes(inputGlobalFP16)
        } else {
            inputGlobalArray.writeBytes(inputGlobalPointer)
        }

        let commandBuffer = MPSCommandBuffer(commandBuffer: commandQueue.makeCommandBuffer()!)

        let fetch = graph.encode(to: commandBuffer,
                                 feeds: feeds,
                                 targetTensors: targetTensors,
                                 targetOperations: nil,
                                 executionDescriptor: nil)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let policyFP16 {
            fetch[policyHead.policyTensor]?.mpsndarray().readBytes(policyFP16)

            policyFP16.toFP32(policy, length: policyCount)
        } else {
            fetch[policyHead.policyTensor]?.mpsndarray().readBytes(policy)

        }

        if let policyPassFP16 {
            fetch[policyHead.policyPassTensor]?.mpsndarray().readBytes(policyPassFP16)

            policyPassFP16.toFP32(policyPass, length: policyPassCount)
        } else {
            fetch[policyHead.policyPassTensor]?.mpsndarray().readBytes(policyPass)
        }

        if let valueFP16 {
            fetch[valueHead.valueTensor]?.mpsndarray().readBytes(valueFP16)

            valueFP16.toFP32(value, length: valueCount)
        } else {
            fetch[valueHead.valueTensor]?.mpsndarray().readBytes(value)
        }

        if let scoreValueFP16 {
            fetch[valueHead.scoreValueTensor]?.mpsndarray().readBytes(scoreValueFP16)

            scoreValueFP16.toFP32(scoreValue, length: scoreValueCount)
        } else {
            fetch[valueHead.scoreValueTensor]?.mpsndarray().readBytes(scoreValue)
        }

        if let ownershipFP16 {
            fetch[valueHead.ownershipTensor]?.mpsndarray().readBytes(ownershipFP16)

            ownershipFP16.toFP32(ownership, length: ownershipCount)
        } else {
            fetch[valueHead.ownershipTensor]?.mpsndarray().readBytes(ownership)
        }
    }
}

// A enum to represent enabled/disabled/auto option of a feature.
@objc enum SWEnable: Int {
    case False
    case True
    case Auto
}

/// A class that represents context of GPU devices.
@objc class ComputeContext: NSObject {
    static var instance = ComputeContext()
    let nnXLen: NSNumber
    let nnYLen: NSNumber
    let useFP16Mode: SWEnable
    let useNHWCMode: SWEnable

    /// Create a context.
    /// - Parameters:
    ///   - nnXLen: The width of the input tensor.
    ///   - nnYLen: The height of the input tensor.
    ///   - useFP16Mode: use FP16 mode or not.
    ///   - useNHWCMode: use NHWC mode or not.
    @objc class func createInstance(nnXLen: NSNumber,
                                    nnYLen: NSNumber,
                                    useFP16Mode: SWEnable,
                                    useNHWCMode: SWEnable) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        instance = ComputeContext(nnXLen: nnXLen,
                                  nnYLen: nnYLen,
                                  useFP16Mode: useFP16Mode,
                                  useNHWCMode: useNHWCMode)
    }

    /// Get the context.
    /// - Returns: The context.
    @objc class func getInstance() -> ComputeContext {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return instance
    }

    /// Initialize a context.
    private convenience override init() {
        self.init(nnXLen: 19, nnYLen: 19, useFP16Mode: .Auto, useNHWCMode: .Auto)
    }

    /// Initialize a context.
    /// - Parameters:
    ///   - nnXLen: The width of the input tensor.
    ///   - nnYLen: The height of the input tensor.
    ///   - useFP16Mode: use FP16 mode or not.
    ///   - useNHWCMode: use NHWC mode or not.
    private init(nnXLen: NSNumber,
                 nnYLen: NSNumber,
                 useFP16Mode: SWEnable,
                 useNHWCMode: SWEnable) {
        self.nnXLen = nnXLen
        self.nnYLen = nnYLen
        self.useFP16Mode = useFP16Mode
        self.useNHWCMode = useNHWCMode
    }
}

/// A class that represents a handle of GPU device.
@objc class ComputeHandle: NSObject {
    static var handles: [Int: ComputeHandle] = [:]
    let model: Model

    /// Creates a new handle of GPU device.
    /// - Parameters:
    ///   - gpuIdxForThisThread: The index of GPU device.
    ///   - descriptor: The descriptor of the model.
    ///   - batchSize: The batch size.
    ///   - serverThreadIdx: The index of the server thread.
    @objc class func createInstance(at gpuIdxForThisThread: Int,
                                    descriptor: SWModelDesc,
                                    batchSize: NSNumber,
                                    serverThreadIdx: Int) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        handles[gpuIdxForThisThread] = ComputeHandle(descriptor: descriptor,
                                                     batchSize: batchSize,
                                                     gpuIdxForThisThread: gpuIdxForThisThread,
                                                     serverThreadIdx: serverThreadIdx)
    }

    /// Gets the handle of GPU device.
    /// - Parameter gpuIdxForThisThread: The index of GPU device.
    /// - Returns: The handle of GPU device.
    @objc class func getInstance(at gpuIdxForThisThread: Int) -> ComputeHandle {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return handles[gpuIdxForThisThread]!
    }

    /// Initializes a new instance of the `ComputeHandle` class.
    /// - Parameters:
    ///   - descriptor: The descriptor of the model.
    ///   - batchSize: The batch size.
    ///   - gpuIdx: The index of GPU device.
    ///   - threadIdx: The index of the server thread.
    private init(descriptor: SWModelDesc,
                 batchSize: NSNumber,
                 gpuIdxForThisThread gpuIdx: Int,
                 serverThreadIdx threadIdx: Int) {

        let context = ComputeContext.getInstance()
        let useFP16: Bool
        let useNHWC: Bool
        let devices = MTLCopyAllDevices()
        let mtlDevice: MTLDevice

        // Select a GPU device.
        if ((gpuIdx >= 0) && (gpuIdx < devices.count)) {
            mtlDevice = devices[gpuIdx]
        } else {
            mtlDevice = MTLCreateSystemDefaultDevice()!
        }

        let device = MPSGraphDevice(mtlDevice: mtlDevice)

        NSLog("Metal backend thread \(threadIdx): \(mtlDevice.name) Model version \(descriptor.version)")

        NSLog("Metal backend thread \(threadIdx): \(mtlDevice.name) Model name \(descriptor.name)")

        // Select useFP16 mode.
        switch context.useFP16Mode {
        case .True: useFP16 = true
        default: useFP16 = false
        }

        // Select useNHWC mode.
        switch context.useNHWCMode {
        case .True: useNHWC = true
        default: useNHWC = false
        }

        // Create a model.
        model = Model(device: device,
                      graph: MPSGraph(),
                      descriptor: descriptor,
                      nnXLen: context.nnXLen,
                      nnYLen: context.nnYLen,
                      batchSize: batchSize,
                      useFP16: useFP16,
                      useNHWC: useNHWC)

        NSLog("Metal backend thread \(threadIdx): \(mtlDevice.name) useFP16=\(useFP16) useNHWC=\(useNHWC) batchSize=\(batchSize)")
    }
}

/// A class that represents Metal backend.
@objc class MetalBackend : NSObject {

    /// Print all available devices.
    @objc class func printDevices() {
        let devices = MTLCopyAllDevices()

        for i in 0..<devices.count {
            print("Found Metal Device \(i): \(devices[i].name) (isLowPower:\(devices[i].isLowPower), isRemovable:\(devices[i].isRemovable))")
        }
    }

    /// Get width of the input tensor.
    /// - Returns: The width of the input tensor.
    @objc class func getContextXLen() -> Int {
        return ComputeContext.getInstance().nnXLen.intValue
    }

    /// Get height of the input tensor.
    /// - Returns: The height of the input tensor.
    @objc class func getContextYLen() -> Int {
        return ComputeContext.getInstance().nnYLen.intValue
    }

    /// Get output data from the model.
    /// - Parameters:
    ///   - userInputBuffer: The input data.
    ///   - userInputGlobalBuffer: The global input data.
    ///   - policyOutput: The policy output data.
    ///   - policyPassOutput: The policy pass output data.
    ///   - valueOutput: The value output data.
    ///   - ownershipOutput: The ownership output data.
    ///   - scoreValueOutput: The score value output data.
    ///   - gpuIdx: The index of the GPU to use.
    @objc class func getOutput(userInputBuffer: UnsafeMutablePointer<Float32>,
                               userInputGlobalBuffer: UnsafeMutablePointer<Float32>,
                               policyOutput: UnsafeMutablePointer<Float32>,
                               policyPassOutput: UnsafeMutablePointer<Float32>,
                               valueOutput: UnsafeMutablePointer<Float32>,
                               ownershipOutput: UnsafeMutablePointer<Float32>,
                               scoreValueOutput: UnsafeMutablePointer<Float32>,
                               gpuIdx: Int) {
        autoreleasepool {
            let handle = ComputeHandle.getInstance(at: gpuIdx)

            handle.model.apply(input: userInputBuffer,
                               inputGlobal: userInputGlobalBuffer,
                               policy: policyOutput,
                               policyPass: policyPassOutput,
                               value: valueOutput,
                               scoreValue: scoreValueOutput,
                               ownership: ownershipOutput)
        }
    }
}
