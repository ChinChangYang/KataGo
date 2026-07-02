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
#elseif os(tvOS)
    // Apple TV 4K, CoreML/ANE-only, under a tight per-process memory limit:
    // 2 search threads keep the single ANE server thread fed (1 left analysis
    // visibly starved on device) while the small NN batch keeps steady-state RSS
    // predictable for continuous kata-analyze. mlxNnMaxBatchSize is part of the
    // CoreML compiled-model cache key, so changing it forces a cold reconvert —
    // batch 2 already accommodates both in-flight evals.
    public static let mlxNumSearchThreads = 2
    public static let mlxNnMaxBatchSize = 2
#else
    // iOS/visionOS default to a single CoreML/ANE backend (best power/throughput
    // on an iPad A17 Pro run); 2 search threads keep the ANE fed without
    // oversubscribing. Both are starting points — the user can raise threads or
    // switch to MLX/GPU or the GPU+ANE mux per model. Tune on device.
    public static let mlxNumSearchThreads = 2
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

        #if os(tvOS)
        // Apple TV: skip the human-SL net entirely — the single biggest memory
        // lever (~half the NN footprint). Pass "" (non-nil) so the engine's
        // `humanModelFile != ""` gate is false. A nil here would fall through to
        // the `?? "Contents/Resources/…"` fallback below and make C++ try to load
        // a net that isn't bundled on tvOS. Human-style profiles are a play-time
        // feature, out of scope for review/spectate (which uses the best net).
        let humanModelArg = ""
        #else
        let humanModelName = "b18c384nbt-humanv0"
        let humanModelExt = "bin.gz"

        let humanModelPath = mainBundle.path(forResource: humanModelName,
                                             ofType: humanModelExt)

        let humanModelArg = humanModelPath ?? "Contents/Resources/b18c384nbt-humanv0.bin.gz"
        #endif

        let configName = "default_gtp"
        let configExt = "cfg"

        let configPath = mainBundle.path(forResource: configName,
                                         ofType: configExt)

        #if os(tvOS)
        // Apple TV skips the human-SL net (above), so the config's `humanSL*`
        // params must go too: the engine throws ("Provided parameter humanSL…
        // but no human model was specified") in Setup::loadParams when they're
        // present without a human model, aborting the whole process. Derive a
        // stripped config from the canonical bundled one so the two never drift.
        let configArg = strippedHumanSLConfig(from: configPath)
            ?? (configPath ?? "Contents/Resources/default_gtp.cfg")
        #else
        let configArg = configPath ?? "Contents/Resources/default_gtp.cfg"
        #endif

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
                         std.string(humanModelArg),
                         std.string(configArg),
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

    #if os(tvOS)
    /// Write a copy of the bundled GTP config with every `humanSL*` parameter line
    /// removed, returning its path. Apple TV runs without the human-SL net, and
    /// the engine aborts (`Setup::loadParams` → `throwHumanParsingError`) if those
    /// params are present with no human model. Derived from the canonical config
    /// each launch, so the two never drift (TMPDIR is purgeable but regenerated).
    private class func strippedHumanSLConfig(from path: String?) -> String? {
        guard let path,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let filtered = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !String($0).trimmingCharacters(in: .whitespaces).hasPrefix("humanSL") }
            .joined(separator: "\n")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("default_gtp_tvos.cfg")
        do {
            try filtered.write(to: out, atomically: true, encoding: .utf8)
            return out.path(percentEncoded: false)
        } catch {
            return nil
        }
    }
    #endif

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

    /// Discard stale, not-yet-read output the process-global bridge buffer
    /// retained from a prior engine run (see `KataGoClearMessages`). Called
    /// before a fresh `version` handshake on relaunch so the blocking read waits
    /// for the new engine instead of returning a leftover line.
    public class func clearOutputBuffer() {
        KataGoClearMessages()
    }
}
