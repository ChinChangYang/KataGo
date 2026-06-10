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
                             requireExactNNLen: Bool = false,
                             tunerFull: Bool = false,
                             reTune: Bool = false) {
        runGtpImpl(modelPath: modelPath,
                   metalDeviceToUse: metalDeviceToUse,
                   maxBoardSizeForNNBuffer: maxBoardSizeForNNBuffer,
                   requireExactNNLen: requireExactNNLen,
                   tunerFull: tunerFull,
                   reTune: reTune)
    }
#else
    // iOS/visionOS default: 100 = ANE (Neural Engine) via CoreML
    public class func runGtp(modelPath: String? = nil,
                             metalDeviceToUse: Int = 100,
                             maxBoardSizeForNNBuffer: Int = 37,
                             requireExactNNLen: Bool = false,
                             tunerFull: Bool = false,
                             reTune: Bool = false) {
        runGtpImpl(modelPath: modelPath,
                   metalDeviceToUse: metalDeviceToUse,
                   maxBoardSizeForNNBuffer: maxBoardSizeForNNBuffer,
                   requireExactNNLen: requireExactNNLen,
                   tunerFull: tunerFull,
                   reTune: reTune)
    }
#endif

    private class func runGtpImpl(modelPath: String?,
                                  metalDeviceToUse: Int,
                                  maxBoardSizeForNNBuffer: Int,
                                  requireExactNNLen: Bool,
                                  tunerFull: Bool,
                                  reTune: Bool) {
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
                     requireExactNNLen,
                     std.string(homeDataDir()),
                     tunerFull,
                     reTune)
    }

    /// Writable home-data directory for KataGo's on-device caches (notably the
    /// MLX/GPU Winograd autotuner). On iOS/visionOS the sandbox container root
    /// is not writable, so KataGo's default `$HOME/.katago` cannot be created
    /// and the autotuner aborts (`MakeDir::make` throws). Hand the engine an
    /// app-created `Application Support/KataGo` instead. Returns "" on macOS
    /// (whose container root is writable, so the default path already works)
    /// or if the directory cannot be created, in which case KataGoRunGtp adds
    /// no override and the engine keeps its default behavior.
    private class func homeDataDir() -> String {
        #if os(macOS)
        return ""
        #else
        let fileManager = FileManager.default
        guard let base = try? fileManager.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil,
                                              create: true) else {
            return ""
        }
        let dir = base.appendingPathComponent("KataGo", isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return ""
        }
        return dir.path(percentEncoded: false)
        #endif
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
