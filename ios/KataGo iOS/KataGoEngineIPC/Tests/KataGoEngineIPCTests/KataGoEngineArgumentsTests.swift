import Testing
@testable import KataGoEngineIPC

/// The helper argv mirrors `KataGoCpp.cpp::KataGoRunGtp`'s subArgs (the proven
/// in-process invocation) for every scalar override, including the single-token
/// "-override-config KEY=VALUE" form and the conditional homeDataDir override.
///
/// The macOS subprocess additionally drives a per-NN-server-thread device MUX
/// (which the in-process iOS bridge does not): `deviceAssignments` becomes a
/// `numNNServerThreadsPerModel=<count>` override plus one
/// `mlxDeviceToUseThread<i>=<device>` override per element (0 = MLX/GPU,
/// 100 = CoreML/ANE). setup.cpp reads those keys per server thread.
@Suite struct KataGoEngineArgumentsTests {

    /// The macOS "best throughput" mux: 1 MLX/GPU + 2 CoreML/ANE server threads
    /// (matches MainWindowController.engineDeviceAssignments).
    @Test func emitsOneGPUTwoANEMux() {
        let args = KataGoEngineArguments.gtp(
            modelPath: "/m.bin.gz",
            humanModelPath: "/h.bin.gz",
            configPath: "/gtp.cfg",
            deviceAssignments: [0, 100, 100],
            numSearchThreads: 16,
            nnMaxBatchSize: 8,
            maxBoardSizeForNNBuffer: 37,
            requireExactNNLen: false,
            homeDataDir: "",
            tunerFull: false,
            reTune: false)

        #expect(args == [
            "gtp",
            "-model", "/m.bin.gz",
            "-human-model", "/h.bin.gz",
            "-config", "/gtp.cfg",
            "-override-config numNNServerThreadsPerModel=3",
            "-override-config mlxDeviceToUseThread0=0",
            "-override-config mlxDeviceToUseThread1=100",
            "-override-config mlxDeviceToUseThread2=100",
            "-override-config mlxUseFP16=true",
            "-override-config numSearchThreads=16",
            "-override-config nnMaxBatchSize=8",
            "-override-config maxBoardSizeForNNBuffer=37",
            "-override-config requireMaxBoardSize=false",
            "-override-config mlxTunerFull=false",
            "-override-config mlxReTune=false",
        ])
    }

    /// Thread count tracks the assignment count, devices are emitted in order,
    /// and the homeDataDir override still sits between requireMaxBoardSize and
    /// mlxTunerFull (matching KataGoCpp.cpp's push order).
    @Test func tracksThreadCountAndInsertsHomeDataDirOnlyWhenNonEmpty() {
        let args = KataGoEngineArguments.gtp(
            modelPath: "/m", humanModelPath: "/h", configPath: "/c",
            deviceAssignments: [0, 100], numSearchThreads: 2, nnMaxBatchSize: 1,
            maxBoardSizeForNNBuffer: 19, requireExactNNLen: true,
            homeDataDir: "/cache/KataGo", tunerFull: true, reTune: true)

        #expect(args == [
            "gtp",
            "-model", "/m",
            "-human-model", "/h",
            "-config", "/c",
            "-override-config numNNServerThreadsPerModel=2",
            "-override-config mlxDeviceToUseThread0=0",
            "-override-config mlxDeviceToUseThread1=100",
            "-override-config mlxUseFP16=true",
            "-override-config numSearchThreads=2",
            "-override-config nnMaxBatchSize=1",
            "-override-config maxBoardSizeForNNBuffer=19",
            "-override-config requireMaxBoardSize=true",
            "-override-config homeDataDir=/cache/KataGo",
            "-override-config mlxTunerFull=true",
            "-override-config mlxReTune=true",
        ])
    }

    /// A single-device assignment still emits an explicit thread count of 1 plus
    /// the one Thread0 override (the degenerate, non-mux case).
    @Test func singleDeviceEmitsThreadCountOne() {
        let args = KataGoEngineArguments.gtp(
            modelPath: "/m", humanModelPath: "/h", configPath: "/c",
            deviceAssignments: [100], numSearchThreads: 2, nnMaxBatchSize: 1,
            maxBoardSizeForNNBuffer: 19, requireExactNNLen: false,
            homeDataDir: "", tunerFull: false, reTune: false)

        #expect(args.contains("-override-config numNNServerThreadsPerModel=1"))
        #expect(args.contains("-override-config mlxDeviceToUseThread0=100"))
        #expect(!args.contains(where: { $0.hasPrefix("-override-config mlxDeviceToUseThread1=") }))
    }
}
