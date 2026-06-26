//
//  KataGoHelper.swift
//  KataGoHelper
//
//  Created by Chin-Chang Yang on 2024/7/6.
//

import Foundation
import CKataGoBridge

public class KataGoHelper {

#if os(macOS)
    public static let mlxNumSearchThreads = 16
    public static let mlxNnMaxBatchSize = 8
#else
    // iOS/visionOS feed a fixed GPU+ANE mux: more search threads + a batch >1
    // so the parallel NN server threads (and the GPU's batched eval) stay busy.
    // Starting points — tune on device (power vs throughput).
    public static let mlxNumSearchThreads = 6
    public static let mlxNnMaxBatchSize = 3
#endif

    /// Launch the in-process engine on the given inference backend. Each element
    /// of `deviceAssignments` is one NN-server-thread device code
    /// (0 = MLX/GPU, 100 = CoreML/ANE); the default is the platform mux.
    /// `numSearchThreads` is the MCTS search-thread count (defaults to the
    /// platform starting point).
    public class func runGtp(modelPath: String? = nil,
                             deviceAssignments: [Int] = EngineDeviceAssignments.platformMux,
                             numSearchThreads: Int = mlxNumSearchThreads,
                             maxBoardSizeForNNBuffer: Int = 37,
                             requireExactNNLen: Bool = false,
                             tunerFull: Bool = false,
                             reTune: Bool = false) {
        runGtpImpl(modelPath: modelPath,
                   deviceAssignments: deviceAssignments,
                   numSearchThreads: numSearchThreads,
                   maxBoardSizeForNNBuffer: maxBoardSizeForNNBuffer,
                   requireExactNNLen: requireExactNNLen,
                   tunerFull: tunerFull,
                   reTune: reTune)
    }

    private class func runGtpImpl(modelPath: String?,
                                  deviceAssignments: [Int],
                                  numSearchThreads: Int,
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

        // The cache-aware CoreML bridge (Task 19) is registered at app launch
        // via `registerCoreMLBridge()` in KataGo_iOSApp.init(). It lives in the
        // app target (not this package) because its loader imports KataGoSwift,
        // an Xcode framework a SwiftPM target cannot order against; the app
        // target is ordered after KataGoSwift via the framework graph. The
        // registration runs before any view (and thus any runGtp call), so the
        // KataGoSwift seam is wired before the engine starts.

        // Marshal the device-assignment array across the C++ boundary as a
        // (pointer, count) pair. `KataGoRunGtp` consumes it synchronously while
        // building its argv (before it blocks in MainCmds::gtp), so the borrowed
        // buffer stays valid for the duration of the call.
        let devices = deviceAssignments.map { Int32($0) }
        devices.withUnsafeBufferPointer { buf in
            KataGoRunGtp(std.string(mainModelPath ?? "Contents/Resources/default_model.bin.gz"),
                         std.string(humanModelPath ?? "Contents/Resources/b18c384nbt-humanv0.bin.gz"),
                         std.string(configPath ?? "Contents/Resources/default_gtp.cfg"),
                         buf.baseAddress,
                         Int32(buf.count),
                         Int32(numSearchThreads),
                         Int32(mlxNnMaxBatchSize),
                         Int32(maxBoardSizeForNNBuffer),
                         requireExactNNLen,
                         std.string(homeDataDir()),
                         tunerFull,
                         reTune)
        }
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
