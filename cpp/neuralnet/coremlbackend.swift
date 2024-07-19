//
//  coremlbackend.swift
//  KataGo
//
//  Created by Chin-Chang Yang on 2023/11/8.
//

import Foundation
import CoreML

public class CoreMLBackend {

    class func getModelName(xLen: Int, yLen: Int, useFP16: Bool, metaEncoderVersion: Int) -> String {
        let precision = useFP16 ? 16 : 32
        let encoder = (metaEncoderVersion > 0) ? "meta\(metaEncoderVersion)" : ""
        return "KataGoModel\(xLen)x\(yLen)fp\(precision)\(encoder)"
    }

    let model: KataGoModel
    let xLen: Int
    let yLen: Int
    public let version: Int32
    let numSpatialFeatures: Int
    let numGlobalFeatures: Int
    let numMetaFeatures: Int
    let metaEncoderVersion: Int

    init(model: MLModel, xLen: Int, yLen: Int, metaEncoderVersion: Int) {
        self.model = KataGoModel(model: model)
        self.xLen = xLen
        self.yLen = yLen
        self.metaEncoderVersion = metaEncoderVersion

        // The model version must be at least 8.
        if let versionString = model.modelDescription.metadata[MLModelMetadataKey.versionString] as? String {
            if let versionInt = Int32(versionString) {
                self.version = versionInt
            } else {
                self.version = -1
            }
        } else {
            self.version = -1
        }

        assert(self.version >= 8, "version must not be smaller than 8: \(self.version)")

        // The number of spatial features must be 22.
        self.numSpatialFeatures = 22

        // The number of global features must be 19.
        self.numGlobalFeatures = 19

        // The number of meta features must be 192.
        self.numMetaFeatures = 192
    }

    public func getBatchOutput(binInputs: UnsafeMutablePointer<Float32>,
                               globalInputs: UnsafeMutablePointer<Float32>,
                               metaInputs: UnsafeMutablePointer<Float32>,
                               policyOutputs: UnsafeMutablePointer<Float32>,
                               valueOutputs: UnsafeMutablePointer<Float32>,
                               ownershipOutputs: UnsafeMutablePointer<Float32>,
                               miscValuesOutputs: UnsafeMutablePointer<Float32>,
                               moreMiscValuesOutputs: UnsafeMutablePointer<Float32>,
                               batchSize: Int) {

        autoreleasepool {
            do {
                let spatialStrides = [numSpatialFeatures * yLen * xLen,
                                      yLen * xLen,
                                      xLen,
                                      1] as [NSNumber]

                let globalStrides = [numGlobalFeatures, 1] as [NSNumber]
                let spatialSize = numSpatialFeatures * yLen * xLen

                let inputArray = try (0..<batchSize).map { index -> KataGoModelInput in
                    let binInputsArray = try MLMultiArray(
                        dataPointer: binInputs.advanced(by: index * spatialSize),
                        shape: [1, numSpatialFeatures, yLen, xLen] as [NSNumber],
                        dataType: .float,
                        strides: spatialStrides)

                    let globalInputsArray = try MLMultiArray(
                        dataPointer: globalInputs.advanced(by: index * numGlobalFeatures),
                        shape: [1, numGlobalFeatures] as [NSNumber],
                        dataType: .float,
                        strides: globalStrides)

                    if metaEncoderVersion == 0 {
                        return KataGoModelInput(input_spatial: binInputsArray, input_global: globalInputsArray)
                    } else {
                        let metaStrides = [numMetaFeatures, 1] as [NSNumber]

                        let metaInputsArray = try MLMultiArray(
                            dataPointer: metaInputs.advanced(by: index * numMetaFeatures),
                            shape: [1, numMetaFeatures] as [NSNumber],
                            dataType: .float,
                            strides: metaStrides)

                        return KataGoModelInput(input_spatial: binInputsArray,
                                                input_global: globalInputsArray,
                                                input_meta: metaInputsArray)
                    }
                }

                let inputBatch = KataGoModelInputBatch(inputArray: inputArray)
                let options = MLPredictionOptions()
                let outputBatch = try model.prediction(from: inputBatch, options: options)

                outputBatch.outputArray.enumerated().forEach { index, output in
                    let policyOutputBase = policyOutputs.advanced(by: index * output.output_policy.count)
                    let valueOutputBase = valueOutputs.advanced(by: index * output.out_value.count)
                    let ownershipOutputBase = ownershipOutputs.advanced(by: index * output.out_ownership.count)
                    let miscValuesOutputBase = miscValuesOutputs.advanced(by: index * output.out_miscvalue.count)
                    let moreMiscValuesOutputBase = moreMiscValuesOutputs.advanced(by: index * output.out_moremiscvalue.count)

                    (0..<output.output_policy.count).forEach { i in
                        policyOutputBase[i] = output.output_policy[i].floatValue
                    }

                    (0..<output.out_value.count).forEach { i in
                        valueOutputBase[i] = output.out_value[i].floatValue
                    }

                    (0..<output.out_ownership.count).forEach { i in
                        ownershipOutputBase[i] = output.out_ownership[i].floatValue
                    }

                    (0..<output.out_miscvalue.count).forEach { i in
                        miscValuesOutputBase[i] = output.out_miscvalue[i].floatValue
                    }

                    (0..<output.out_moremiscvalue.count).forEach { i in
                        moreMiscValuesOutputBase[i] = output.out_moremiscvalue[i].floatValue
                    }
                }
            } catch {
                printError("An error occurred: \(error)")
            }
        }
    }
}

public func maybeCreateCoreMLBackend(condition: Bool,
                                     xLen: Int,
                                     yLen: Int,
                                     useFP16: Bool,
                                     metaEncoderVersion: Int,
                                     useCpuAndNeuralEngine: Bool) -> CoreMLBackend? {
    guard condition else { return nil }

    // Get the model name.
    let modelName = CoreMLBackend.getModelName(xLen: xLen, yLen: yLen, useFP16: useFP16, metaEncoderVersion: metaEncoderVersion)

    // Compile the model in Bundle.
    let mlmodel = KataGoModel.compileBundleMLModel(modelName: modelName, useCpuAndNeuralEngine: useCpuAndNeuralEngine)

    if let mlmodel {
        printError("CoreML backend: \(xLen)x\(yLen) useFP16 \(useFP16) metaEncoderVersion \(metaEncoderVersion)");

        // The CoreMLBackend object is created.
        return CoreMLBackend(model: mlmodel, xLen: xLen, yLen: yLen, metaEncoderVersion: metaEncoderVersion)
    } else {
        fatalError("Unable to compile bundle MLModel from model: \(modelName)")
    }
}
