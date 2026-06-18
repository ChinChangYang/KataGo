import Foundation

/// Builds the GTP sub-command argument vector for the spawned `katago-engine`
/// helper. This MUST mirror, byte-for-byte, the argument list the in-process
/// bridge (`KataGoCpp.cpp::KataGoRunGtp`) builds — it is the proven-working
/// invocation. argv[0] (the executable path) is supplied by the process; this
/// returns everything from the `"gtp"` sub-command token onward.
public enum KataGoEngineArguments {
    public static func gtp(
        modelPath: String,
        humanModelPath: String,
        configPath: String,
        mlxDeviceToUse: Int,
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
            override("mlxDeviceToUseThread0=\(mlxDeviceToUse)"),
            override("mlxUseFP16=true"),
            override("numSearchThreads=\(numSearchThreads)"),
            override("nnMaxBatchSize=\(nnMaxBatchSize)"),
            override("maxBoardSizeForNNBuffer=\(maxBoardSizeForNNBuffer)"),
            override("requireMaxBoardSize=\(requireExactNNLen)"),
        ]
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
