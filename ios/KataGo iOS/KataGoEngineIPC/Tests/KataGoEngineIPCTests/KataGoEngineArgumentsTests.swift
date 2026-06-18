import Testing
@testable import KataGoEngineIPC

/// The helper argv MUST match `KataGoCpp.cpp::KataGoRunGtp`'s subArgs exactly
/// (the proven in-process invocation), including the single-token
/// "-override-config KEY=VALUE" form and the conditional homeDataDir override.
@Suite struct KataGoEngineArgumentsTests {

    @Test func matchesTheInProcessInvocationOnMacOS() {
        let args = KataGoEngineArguments.gtp(
            modelPath: "/m.bin.gz",
            humanModelPath: "/h.bin.gz",
            configPath: "/gtp.cfg",
            mlxDeviceToUse: 0,
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
            "-override-config mlxDeviceToUseThread0=0",
            "-override-config mlxUseFP16=true",
            "-override-config numSearchThreads=16",
            "-override-config nnMaxBatchSize=8",
            "-override-config maxBoardSizeForNNBuffer=37",
            "-override-config requireMaxBoardSize=false",
            "-override-config mlxTunerFull=false",
            "-override-config mlxReTune=false",
        ])
    }

    @Test func insertsHomeDataDirOverrideOnlyWhenNonEmpty() {
        let args = KataGoEngineArguments.gtp(
            modelPath: "/m", humanModelPath: "/h", configPath: "/c",
            mlxDeviceToUse: 100, numSearchThreads: 2, nnMaxBatchSize: 1,
            maxBoardSizeForNNBuffer: 19, requireExactNNLen: true,
            homeDataDir: "/cache/KataGo", tunerFull: true, reTune: true)

        // homeDataDir override sits between requireMaxBoardSize and mlxTunerFull,
        // matching KataGoCpp.cpp's push order.
        #expect(args == [
            "gtp",
            "-model", "/m",
            "-human-model", "/h",
            "-config", "/c",
            "-override-config mlxDeviceToUseThread0=100",
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
}
