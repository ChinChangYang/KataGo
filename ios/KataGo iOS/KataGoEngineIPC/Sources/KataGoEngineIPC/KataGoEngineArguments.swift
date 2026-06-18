import Foundation

/// Builds the GTP sub-command argument vector for the spawned `katago-engine`
/// helper. This MUST mirror, byte-for-byte, the argument list the in-process
/// bridge (`KataGoCpp.cpp::KataGoRunGtp`) builds — it is the proven-working
/// invocation. argv[0] (the executable path) is supplied by the process; this
/// returns everything from the `"gtp"` sub-command token onward.
public enum KataGoEngineArguments {
    /// - Parameter deviceAssignments: one device code per NN server thread,
    ///   indexed by server-thread number. `0` = MLX/GPU, `100` = CoreML/ANE.
    ///   The macOS "best throughput" mux passes `[0, 100, 100]` (1 GPU + 2 ANE);
    ///   this becomes `numNNServerThreadsPerModel=<count>` plus one
    ///   `mlxDeviceToUseThread<i>=<device>` override each, which setup.cpp reads
    ///   per server thread (cpp/program/setup.cpp:191-226).
    public static func gtp(
        modelPath: String,
        humanModelPath: String,
        configPath: String,
        deviceAssignments: [Int],
        numSearchThreads: Int,
        nnMaxBatchSize: Int,
        maxBoardSizeForNNBuffer: Int,
        requireExactNNLen: Bool,
        homeDataDir: String,
        tunerFull: Bool,
        reTune: Bool
    ) -> [String] {
        func override(_ keyValue: String) -> String { "-override-config " + keyValue }

        var args: [String] = [
            "gtp",
            "-model", modelPath,
            "-human-model", humanModelPath,
            "-config", configPath,
            override("numNNServerThreadsPerModel=\(deviceAssignments.count)"),
        ]
        // One device override per server thread, in thread-index order. Override
        // ordering is irrelevant to the engine (all keys merge into the cfg map
        // before setup.cpp reads them), but emitting Thread0..N-1 in order keeps
        // the argv readable.
        for (threadIdx, device) in deviceAssignments.enumerated() {
            args.append(override("mlxDeviceToUseThread\(threadIdx)=\(device)"))
        }
        args.append(contentsOf: [
            override("mlxUseFP16=true"),
            override("numSearchThreads=\(numSearchThreads)"),
            override("nnMaxBatchSize=\(nnMaxBatchSize)"),
            override("maxBoardSizeForNNBuffer=\(maxBoardSizeForNNBuffer)"),
            override("requireMaxBoardSize=\(requireExactNNLen)"),
        ])
        // iOS injects a writable homeDataDir; macOS leaves it empty (the default
        // ~/.katago works), in which case KataGoCpp.cpp adds no override.
        if !homeDataDir.isEmpty {
            args.append(override("homeDataDir=\(homeDataDir)"))
        }
        args.append(override("mlxTunerFull=\(tunerFull)"))
        args.append(override("mlxReTune=\(reTune)"))
        return args
    }
}
