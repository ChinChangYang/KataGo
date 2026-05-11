//
//  KataGoHelper.swift
//  KataGoHelper
//
//  Created by Chin-Chang Yang on 2024/7/6.
//

import Foundation

public class KataGoHelper {

#if os(macOS)
    static let metalNumSearchThreads = 16
    static let metalNnMaxBatchSize = 8
#else
    static let metalNumSearchThreads = 2
    static let metalNnMaxBatchSize = 1
#endif

#if os(macOS)
    // macOS default: 0 = GPU (MPSGraph)
    public class func runGtp(modelPath: String? = nil,
                             metalDeviceToUse: Int = 0,
                             maxBoardSizeForNNBuffer: Int = 37,
                             requireExactNNLen: Bool = false) {
        runGtpImpl(modelPath: modelPath,
                   metalDeviceToUse: metalDeviceToUse,
                   maxBoardSizeForNNBuffer: maxBoardSizeForNNBuffer,
                   requireExactNNLen: requireExactNNLen)
    }
#else
    // iOS/visionOS default: 100 = ANE (Neural Engine) via CoreML
    public class func runGtp(modelPath: String? = nil,
                             metalDeviceToUse: Int = 100,
                             maxBoardSizeForNNBuffer: Int = 37,
                             requireExactNNLen: Bool = false) {
        runGtpImpl(modelPath: modelPath,
                   metalDeviceToUse: metalDeviceToUse,
                   maxBoardSizeForNNBuffer: maxBoardSizeForNNBuffer,
                   requireExactNNLen: requireExactNNLen)
    }
#endif

    private class func runGtpImpl(modelPath: String?,
                                  metalDeviceToUse: Int,
                                  maxBoardSizeForNNBuffer: Int,
                                  requireExactNNLen: Bool) {
        let mainBundle = Bundle.main
        let modelName = "default_model"
        let modelExt = "bin.gz"

        let mainModelPath = modelPath ?? mainBundle.path(forResource: modelName,
                                                         ofType: modelExt)

        let humanModelName = "b18c384nbt-humanv0"
        let humanModelExt = "bin.gz"

        let humanModelPath = mainBundle.path(forResource: humanModelName,
                                             ofType: humanModelExt)

        let configName = "default_gtp"
        let configExt = "cfg"

        let configPath = mainBundle.path(forResource: configName,
                                         ofType: configExt)

        // Register the cache-aware CoreML bridge (Task 19) before the engine
        // starts. This wires loadCoreMLHandleWithBridgeTimeout into the
        // KataGoSwift seam so convertAndCreateCoreMLOnlyHandle can call it.
        registerCoreMLBridge()

        KataGoRunGtp(std.string(mainModelPath ?? "Contents/Resources/default_model.bin.gz"),
                     std.string(humanModelPath ?? "Contents/Resources/b18c384nbt-humanv0.bin.gz"),
                     std.string(configPath ?? "Contents/Resources/default_gtp.cfg"),
                     Int32(metalDeviceToUse),
                     Int32(metalNumSearchThreads),
                     Int32(metalNnMaxBatchSize),
                     Int32(maxBoardSizeForNNBuffer),
                     requireExactNNLen)
    }

    public class func getMessageLine() -> String {
        let cppLine = KataGoGetMessageLine()

        return String(cppLine)
    }

    public class func sendCommand(_ command: String) {
        KataGoSendCommand(std.string(command))
    }

    public class func sendMessage(_ message: String) {
        KataGoSendMessage(std.string(message))
    }
}
