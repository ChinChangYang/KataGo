#import "metalbackend.h"
#import "metalswift.h"

/// Converts a ConvLayerDesc instance from C++ to Swift by creating a new SWConvLayerDesc instance with the same properties.
/// - Parameter desc: The ConvLayerDesc instance to convert.
/// - Returns: A SWConvLayerDesc instance with the same properties as the input ConvLayerDesc.
static SWConvLayerDesc * convLayerDescToSwift(const ConvLayerDesc * desc) {

    SWConvLayerDesc * swDesc =
    [[SWConvLayerDesc alloc] initWithConvYSize:[NSNumber numberWithInt:desc->convYSize]
                                     convXSize:[NSNumber numberWithInt:desc->convXSize]
                                    inChannels:[NSNumber numberWithInt:desc->inChannels]
                                   outChannels:[NSNumber numberWithInt:desc->outChannels]
                                     dilationY:desc->dilationY
                                     dilationX:desc->dilationX
                                       weights:(float*)desc->weights.data()];

    return swDesc;
}

/// Converts a BatchNormLayerDesc instance from C++ to Swift by creating a new SWBatchNormLayerDesc instance with the same properties.
/// - Parameter desc: The BatchNormLayerDesc instance to convert.
/// - Returns: A SWBatchNormLayerDesc instance with the same properties as the input BatchNormLayerDesc.
static SWBatchNormLayerDesc * batchNormLayerDescToSwift(const BatchNormLayerDesc * desc) {

    SWBatchNormLayerDesc * swDesc =
    [[SWBatchNormLayerDesc alloc] initWithNumChannels:[NSNumber numberWithInt:desc->numChannels]
                                              epsilon:desc->epsilon
                                             hasScale:[NSNumber numberWithBool:desc->hasScale]
                                              hasBias:[NSNumber numberWithBool:desc->hasBias]
                                                 mean:(float*)desc->mean.data()
                                             variance:(float*)desc->variance.data()
                                                scale:(float*)desc->scale.data()
                                                 bias:(float*)desc->bias.data()];

    return swDesc;
}

/// Convert a residual block description from C++ to Swift
/// - Parameter desc: A residual block description
/// - Returns: The residual block description converted to SWResidualBlockDesc
static SWResidualBlockDesc * residualBlockDescToSwift(const ResidualBlockDesc * desc) {

    SWBatchNormLayerDesc * preBN = batchNormLayerDescToSwift(&desc->preBN);
    SWConvLayerDesc * regularConv = convLayerDescToSwift(&desc->regularConv);
    SWBatchNormLayerDesc * midBN = batchNormLayerDescToSwift(&desc->midBN);
    SWConvLayerDesc * finalConv = convLayerDescToSwift(&desc->finalConv);

    SWResidualBlockDesc * swDesc = [[SWResidualBlockDesc alloc] initWithPreBN:preBN
                                                                preActivation:ActivationKindRelu
                                                                  regularConv:regularConv
                                                                        midBN:midBN
                                                                midActivation:ActivationKindRelu
                                                                    finalConv:finalConv];

    return swDesc;
}

/// Convert a matrix multiplication layer description from C++ to Swift
/// - Parameter desc: A matrix multiplication layer description
/// - Returns: The matrix multiplication layer description converted to SWMatMulLayerDesc
static SWMatMulLayerDesc * matMulLayerDescToSwift(const MatMulLayerDesc * desc) {

    SWMatMulLayerDesc * swDesc =
    [[SWMatMulLayerDesc alloc] initInChannels:[NSNumber numberWithInt:desc->inChannels]
                                  outChannels:[NSNumber numberWithInt:desc->outChannels]
                                      weights:(float*)desc->weights.data()];

    return swDesc;
}

/// Convert a global pooling residual block description from C++ to Swift
/// - Parameter desc: A global pooling residual block description
/// - Returns: The global pooling residual block description converted to SWGlobalPoolingResidualBlockDesc
static SWGlobalPoolingResidualBlockDesc* globalPoolingResidualBlockDescToSwift(const GlobalPoolingResidualBlockDesc* desc) {

    SWBatchNormLayerDesc * preBN = batchNormLayerDescToSwift(&desc->preBN);
    SWConvLayerDesc * regularConv = convLayerDescToSwift(&desc->regularConv);
    SWConvLayerDesc * gpoolConv = convLayerDescToSwift(&desc->gpoolConv);
    SWBatchNormLayerDesc * gpoolBN = batchNormLayerDescToSwift(&desc->gpoolBN);
    SWMatMulLayerDesc * gpoolToBiasMul = matMulLayerDescToSwift(&desc->gpoolToBiasMul);
    SWBatchNormLayerDesc * midBN = batchNormLayerDescToSwift(&desc->midBN);
    SWConvLayerDesc * finalConv = convLayerDescToSwift(&desc->finalConv);

    SWGlobalPoolingResidualBlockDesc * swDesc =
    [[SWGlobalPoolingResidualBlockDesc alloc] initWithPreBN:preBN
                                              preActivation:nil
                                                regularConv:regularConv
                                                  gpoolConv:gpoolConv
                                                    gpoolBN:gpoolBN
                                            gpoolActivation:nil
                                             gpoolToBiasMul:gpoolToBiasMul
                                                      midBN:midBN
                                              midActivation:nil
                                                  finalConv:finalConv];

    return swDesc;
}

/// Convert a trunk description from C++ to Swift
/// - Parameter trunk: A trunk description
/// - Returns: The trunk description converted to SWTrunkDesc
static SWTrunkDesc * trunkDescToSwift(const TrunkDesc * trunk) {

    SWConvLayerDesc * initialConv = convLayerDescToSwift(&trunk->initialConv);
    SWMatMulLayerDesc * initialMatMul = matMulLayerDescToSwift(&trunk->initialMatMul);

    const std::vector<std::pair<int, unique_ptr_void>>& blocks = trunk->blocks;
    NSMutableArray<BlockDescriptor *> * swBlocks = [[NSMutableArray alloc] init];

    for (int i = 0; i < blocks.size(); i++) {

        BlockDescriptor * blockDesc;

        if (blocks[i].first == ORDINARY_BLOCK_KIND) {
            ResidualBlockDesc * residualBlockDesc = (ResidualBlockDesc*)blocks[i].second.get();
            SWResidualBlockDesc * swResidualBlockDesc = residualBlockDescToSwift(residualBlockDesc);

            blockDesc = [[BlockDescriptor alloc] initWithKind:BlockKindOrdinary
                                                     ordinary:swResidualBlockDesc
                                                globalPooling:nil];
        } else {
            GlobalPoolingResidualBlockDesc * residualBlockDesc = (GlobalPoolingResidualBlockDesc*)blocks[i].second.get();
            SWGlobalPoolingResidualBlockDesc * swResidualBlockDesc = globalPoolingResidualBlockDescToSwift(residualBlockDesc);

            blockDesc = [[BlockDescriptor alloc] initWithKind:BlockKindGlobalPooling
                                                     ordinary:nil
                                                globalPooling:swResidualBlockDesc];
        }

        [swBlocks addObject:blockDesc];
    }

    SWBatchNormLayerDesc * trunkTipBN = batchNormLayerDescToSwift(&trunk->trunkTipBN);

    SWTrunkDesc * swTrunkDesc =
    [[SWTrunkDesc alloc] initWithVersion:trunk->version
                        trunkNumChannels:[NSNumber numberWithInt:trunk->trunkNumChannels]
                          midNumChannels:[NSNumber numberWithInt:trunk->midNumChannels]
                      regularNumChannels:[NSNumber numberWithInt:trunk->regularNumChannels]
                        gpoolNumChannels:[NSNumber numberWithInt:trunk->gpoolNumChannels]
                             initialConv:initialConv
                           initialMatMul:initialMatMul
                                  blocks:swBlocks
                              trunkTipBN:trunkTipBN];

    return swTrunkDesc;
}

/// Convert a policy head description from C++ to Swift
/// - Parameter policyHead: A policy head description
/// - Returns: The policy head description converted to SWPolicyHeadDesc
static SWPolicyHeadDesc * policyHeadDescToSwift(const PolicyHeadDesc * policyHead) {

    SWConvLayerDesc * p1Conv = convLayerDescToSwift(&policyHead->p1Conv);
    SWConvLayerDesc * g1Conv = convLayerDescToSwift(&policyHead->g1Conv);
    SWBatchNormLayerDesc * g1BN = batchNormLayerDescToSwift(&policyHead->g1BN);
    SWMatMulLayerDesc * gpoolToBiasMul = matMulLayerDescToSwift(&policyHead->gpoolToBiasMul);
    SWBatchNormLayerDesc * p1BN = batchNormLayerDescToSwift(&policyHead->p1BN);
    SWConvLayerDesc * p2Conv = convLayerDescToSwift(&policyHead->p2Conv);
    SWMatMulLayerDesc * gpoolToPassMul = matMulLayerDescToSwift(&policyHead->gpoolToPassMul);

    SWPolicyHeadDesc * swPolicyHead =
    [[SWPolicyHeadDesc alloc] initWithVersion:policyHead->version
                                       p1Conv:p1Conv
                                       g1Conv:g1Conv
                                         g1BN:g1BN
                               gpoolToBiasMul:gpoolToBiasMul
                                         p1BN:p1BN
                                       p2Conv:p2Conv
                               gpoolToPassMul:gpoolToPassMul];

    return swPolicyHead;
}

/// Convert a matrix bias layer description from C++ to Swift
/// - Parameter desc: A matrix bias layer description
/// - Returns: The matrix bias layer description converted to SWMatBiasLayerDesc
static SWMatBiasLayerDesc * matBiasLayerDescToSwift(const MatBiasLayerDesc * desc) {
    SWMatBiasLayerDesc * swDesc =
    [[SWMatBiasLayerDesc alloc] initWithNumChannels:[NSNumber numberWithInt:desc->numChannels]
                                            weights:(float*)desc->weights.data()];

    return swDesc;
}

/// Convert a value head description from C++ to Swift
/// - Parameter valueHead: A value head description
/// - Returns: The value head description converted to SWValueHeadDesc
static SWValueHeadDesc * valueHeadDescToSwift(const ValueHeadDesc * valueHead) {

    SWConvLayerDesc * v1Conv = convLayerDescToSwift(&valueHead->v1Conv);
    SWBatchNormLayerDesc * v1BN = batchNormLayerDescToSwift(&valueHead->v1BN);
    SWMatMulLayerDesc * v2Mul = matMulLayerDescToSwift(&valueHead->v2Mul);
    SWMatBiasLayerDesc * v2Bias = matBiasLayerDescToSwift(&valueHead->v2Bias);
    SWMatMulLayerDesc * v3Mul = matMulLayerDescToSwift(&valueHead->v3Mul);
    SWMatBiasLayerDesc * v3Bias = matBiasLayerDescToSwift(&valueHead->v3Bias);
    SWMatMulLayerDesc * sv3Mul = matMulLayerDescToSwift(&valueHead->sv3Mul);
    SWMatBiasLayerDesc * sv3Bias = matBiasLayerDescToSwift(&valueHead->sv3Bias);
    SWConvLayerDesc * vOwnershipConv = convLayerDescToSwift(&valueHead->vOwnershipConv);

    SWValueHeadDesc * swDesc =
    [[SWValueHeadDesc alloc] initWithVersion:valueHead->version
                                      v1Conv:v1Conv
                                        v1BN:v1BN
                                       v2Mul:v2Mul
                                      v2Bias:v2Bias
                                       v3Mul:v3Mul
                                      v3Bias:v3Bias
                                      sv3Mul:sv3Mul
                                     sv3Bias:sv3Bias
                              vOwnershipConv:vOwnershipConv];

    return swDesc;
}

/// Print the list of available Metal devices
void printMetalDevices(void) {
    [MetalBackend printDevices];
}

/// Create a Metal context
/// - Parameters:
///   - nnXLen: The width of the neural network input
///   - nnYLen: The height of the neural network input
///   - inputUseFP16Mode: Whether to use FP16 mode
///   - inputUseNHWCMode: Whether to use NHWC mode
void createMetalContext(int nnXLen,
                        int nnYLen,
                        enabled_t inputUseFP16Mode,
                        enabled_t inputUseNHWCMode) {
    SWEnable useFP16Mode;
    SWEnable useNHWCMode;

    if (inputUseFP16Mode == enabled_t::False) {
        useFP16Mode = SWEnableFalse;
    } else if (inputUseFP16Mode == enabled_t::True) {
        useFP16Mode = SWEnableTrue;
    } else {
        useFP16Mode = SWEnableAuto;
    }

    if (inputUseNHWCMode == enabled_t::False) {
        useNHWCMode = SWEnableFalse;
    } else if (inputUseNHWCMode == enabled_t::True) {
        useNHWCMode = SWEnableTrue;
    } else {
        useNHWCMode = SWEnableAuto;
    }

    [MetalComputeContext createInstanceWithNnXLen:[NSNumber numberWithInt:nnXLen]
                                           nnYLen:[NSNumber numberWithInt:nnYLen]
                                      useFP16Mode:useFP16Mode
                                      useNHWCMode:useNHWCMode];
}

/// Destroy the Metal context
void destroyMetalContext(void) {
    [MetalComputeContext destroyInstance];
}

/// Get x length of the Metal context
int getMetalContextXLen(void) {
    return (int)[MetalBackend getContextXLen];
}

/// Get y length of the Metal context
int getMetalContextYLen(void) {
    return (int)[MetalBackend getContextYLen];
}

/// Create a Metal handle
/// - Parameters:
///   - gpuIdxForThisThread: The GPU index for this thread
///   - desc: The model description
///   - batchSize: The batch size
///   - serverThreadIdx: The server thread index
void createMetalHandle(int gpuIdxForThisThread,
                       const ModelDesc* desc,
                       int batchSize,
                       int serverThreadIdx) {
    NSString * name = [NSString stringWithUTF8String:desc->name.c_str()];

    SWModelDesc * swModelDesc =
    [[SWModelDesc alloc] initWithVersion:desc->version
                                    name:name
                        numInputChannels:[NSNumber numberWithInt:desc->numInputChannels]
                  numInputGlobalChannels:[NSNumber numberWithInt:desc->numInputGlobalChannels]
                        numValueChannels:[NSNumber numberWithInt:desc->numValueChannels]
                   numScoreValueChannels:[NSNumber numberWithInt:desc->numScoreValueChannels]
                    numOwnershipChannels:[NSNumber numberWithInt:desc->numOwnershipChannels]
                                   trunk:trunkDescToSwift(&desc->trunk)
                              policyHead:policyHeadDescToSwift(&desc->policyHead)
                               valueHead:valueHeadDescToSwift(&desc->valueHead)];

    [MetalComputeHandle createInstanceAt:gpuIdxForThisThread
                              descriptor:swModelDesc
                               batchSize:[NSNumber numberWithInt:batchSize]
                         serverThreadIdx:serverThreadIdx];
}

/// Get output from a Metal handle
/// - Parameters:
///   - userInputBuffer: The user input buffer
///   - userInputGlobalBuffer: The user input global buffer
///   - policyOutput: The policy output
///   - policyPassOutput: The policy pass output
///   - valueOutput: The value output
///   - ownershipOutput: The ownership output
///   - scoreValueOutput: The score value output
///   - gpuIdx: The GPU index
void getMetalHandleOutput(float* userInputBuffer,
                          float* userInputGlobalBuffer,
                          float* policyOutput,
                          float* policyPassOutput,
                          float* valueOutput,
                          float* ownershipOutput,
                          float* scoreValueOutput,
                          int gpuIdx) {
    [MetalBackend getOutputWithUserInputBuffer:userInputBuffer
                         userInputGlobalBuffer:userInputGlobalBuffer
                                  policyOutput:policyOutput
                              policyPassOutput:policyPassOutput
                                   valueOutput:valueOutput
                               ownershipOutput:ownershipOutput
                              scoreValueOutput:scoreValueOutput
                                        gpuIdx:gpuIdx];
}

/// Evaluate a convolutional layer using Metal API for testing purposes
/// - Parameters:
///   - desc: The convolutional layer description
///   - nnXLen: The width of the neural network input
///   - nnYLen: The height of the neural network input
///   - batchSize: The batch size
///   - useFP16: Whether to use FP16 mode
///   - useNHWC: Whether to use NHWC mode
///   - input: The pointer to the input
///   - output: The pointer to the output
void testMetalEvaluateConv(const ConvLayerDesc* desc,
                           int nnXLen,
                           int nnYLen,
                           int batchSize,
                           bool useFP16,
                           bool useNHWC,
                           float* input,
                           float* output) {
    [ConvLayer testWithDescriptor:convLayerDescToSwift(desc)
                           nnXLen:[NSNumber numberWithInt:nnXLen]
                           nnYLen:[NSNumber numberWithInt:nnYLen]
                        batchSize:[NSNumber numberWithInt:batchSize]
                          useFP16:useFP16
                          useNHWC:useNHWC
                            input:input
                           output:output];
}

/// Evaluate a batch normalization layer using Metal API for testing purposes
/// - Parameters:
///   - desc: The batch normalization layer description
///   - nnXLen: The width of the neural network input
///   - nnYLen: The height of the neural network input
///   - batchSize: The batch size
///   - useFP16: Whether to use FP16 mode
///   - useNHWC: Whether to use NHWC mode
///   - input: The pointer to the input
///   - mask: The pointer to the mask
///   - output: The pointer to the output
void testMetalEvaluateBatchNorm(const BatchNormLayerDesc* desc,
                                int nnXLen,
                                int nnYLen,
                                int batchSize,
                                bool useFP16,
                                bool useNHWC,
                                float* input,
                                float* mask,
                                float* output) {
    [BatchNormLayer testWithDescriptor:batchNormLayerDescToSwift(desc)
                                nnXLen:[NSNumber numberWithInt:nnXLen]
                                nnYLen:[NSNumber numberWithInt:nnYLen]
                             batchSize:[NSNumber numberWithInt:batchSize]
                               useFP16:useFP16
                               useNHWC:useNHWC
                                 input:input
                                  mask:mask
                                output:output];
}

/// Evaluate a residual block using Metal API for testing purposes
/// - Parameters:
///   - desc: The residual block description
///   - batchSize: The batch size
///   - nnXLen: The width of the neural network input
///   - nnYLen: The height of the neural network input
///   - useFP16: Whether to use FP16 mode
///   - useNHWC: Whether to use NHWC mode
///   - input: The pointer to the input
///   - mask: The pointer to the mask
///   - output: The pointer to the output
void testMetalEvaluateResidualBlock(const ResidualBlockDesc* desc,
                                    int batchSize,
                                    int nnXLen,
                                    int nnYLen,
                                    bool useFP16,
                                    bool useNHWC,
                                    float* input,
                                    float* mask,
                                    float* output) {
    [ResidualBlock testWithDescriptor:residualBlockDescToSwift(desc)
                            batchSize:[NSNumber numberWithInt:batchSize]
                               nnXLen:[NSNumber numberWithInt:nnXLen]
                               nnYLen:[NSNumber numberWithInt:nnYLen]
                              useFP16:useFP16
                              useNHWC:useNHWC
                                input:input
                                 mask:mask
                               output:output];
}

/// Evaluate a global pooling residual block using Metal API for testing purposes
/// - Parameters:
///   - desc: The global pooling residual block description
///   - batchSize: The batch size
///   - nnXLen: The width of the neural network input
///   - nnYLen: The height of the neural network input
///   - useFP16: Whether to use FP16 mode
///   - useNHWC: Whether to use NHWC mode
///   - input: The pointer to the input
///   - mask: The pointer to the mask
///   - output: The pointer to the output
void testMetalEvaluateGlobalPoolingResidualBlock(const GlobalPoolingResidualBlockDesc* desc,
                                                 int batchSize,
                                                 int nnXLen,
                                                 int nnYLen,
                                                 bool useFP16,
                                                 bool useNHWC,
                                                 float* input,
                                                 float* mask,
                                                 float* output) {
    [GlobalPoolingResidualBlock testWithDescriptor:globalPoolingResidualBlockDescToSwift(desc)
                                         batchSize:[NSNumber numberWithInt:batchSize]
                                            nnXLen:[NSNumber numberWithInt:nnXLen]
                                            nnYLen:[NSNumber numberWithInt:nnYLen]
                                           useFP16:useFP16
                                           useNHWC:useNHWC
                                             input:input
                                              mask:mask
                                            output:output];
}
