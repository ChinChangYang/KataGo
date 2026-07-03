//
//  TVEngineBenchmarkSupportTests.swift
//  KataGo iOSTests
//
//  Pins the tvOS benchmark support types: the kata-benchmark output parser
//  (the exact BenchmarkResults::toString grammar from playutils.cpp — format
//  drift upstream surfaces here as a red test, and at runtime as a leg
//  timeout, never a wrong persisted backend), the crash-safe launch-backend
//  recovery matrix, the winner rule, and the simulator device clamp.
//

import Testing
import Foundation
@testable import KataGoUICore

struct TVEngineBenchmarkSupportTests {

    // The bridge delivers kata-benchmark's whole run as ONE line: "\r"-led
    // progress chunks (toStringNotDone: no nnEvals/s) concatenated, ending
    // with the final toString() result.
    private static let progressChunk =
        "numSearchThreads =  2:  3 / 10 positions, visits/s = 41.52 (12.3 secs)      "
    private static let finalChunk =
        "numSearchThreads =  2: 10 / 10 positions, visits/s = 43.87 nnEvals/s = 21.11 nnBatches/s = 10.88 avgBatchSize = 1.94 (91.2 secs)"
    private static let megaLine =
        "\r" + progressChunk + "\r" + progressChunk + "\r" + finalChunk

    @Test("Parses the final visits/s from the concatenated mega-line")
    func parsesFinalChunk() {
        #expect(TVBenchmarkParser.parseFinalVisitsPerSecond(line: Self.megaLine) == 43.87)
    }

    @Test("A bare final line (no progress prefixes) parses too")
    func parsesBareFinalLine() {
        #expect(TVBenchmarkParser.parseFinalVisitsPerSecond(line: Self.finalChunk) == 43.87)
    }

    @Test("Progress-only output (no nnEvals/s anchor) yields nil")
    func progressOnlyIsNil() {
        #expect(TVBenchmarkParser.parseFinalVisitsPerSecond(line: "\r" + Self.progressChunk) == nil)
    }

    @Test("Garbage, empty, and error lines yield nil / error")
    func rejectsNonResults() {
        #expect(TVBenchmarkParser.parseFinalVisitsPerSecond(line: "") == nil)
        #expect(TVBenchmarkParser.parseFinalVisitsPerSecond(line: "= ") == nil)
        #expect(TVBenchmarkParser.parseFinalVisitsPerSecond(line: "info move Q16 visits 5") == nil)
        #expect(TVBenchmarkParser.isErrorReply("? unknown command"))
        #expect(!TVBenchmarkParser.isErrorReply("= ok"))
    }

    @Test("Winner: MLX must strictly beat CoreML; missing numbers → CoreML")
    func winnerRule() {
        func result(_ coreML: Double?, _ mlx: Double?) -> TVBenchmarkResult {
            TVBenchmarkResult(coreMLVisitsPerSecond: coreML, mlxVisitsPerSecond: mlx,
                              date: Date(timeIntervalSince1970: 0))
        }
        #expect(result(40, 200).winner == .mlx)
        #expect(result(200, 40).winner == .coreML)
        #expect(result(50, 50).winner == .coreML)   // tie → safe default
        #expect(result(nil, 200).winner == .coreML)
        #expect(result(40, nil).winner == .coreML)
    }

    @Test("Benchmark result survives a JSON round-trip")
    func resultCodable() throws {
        let original = TVBenchmarkResult(coreMLVisitsPerSecond: 43.87,
                                         mlxVisitsPerSecond: 197.5,
                                         date: Date(timeIntervalSince1970: 1_780_000_000),
                                         aborted: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TVBenchmarkResult.self, from: data)
        #expect(decoded == original)
    }

    @Test("Recovery: any armed sentinel forces CoreML and clears")
    func recoveryMatrix() {
        // Clean launch honors the persisted choice.
        var d = TVBackendRecovery.launchBackend(persistedRaw: "mlx",
                                                pendingEngineBackendRaw: nil,
                                                benchmarkWasInProgress: false)
        #expect(d.backend == .mlx && d.mustClearSentinels == false)

        // Died mid-spawn: safe CoreML regardless of the persisted backend.
        d = TVBackendRecovery.launchBackend(persistedRaw: "mlx",
                                            pendingEngineBackendRaw: "mlx",
                                            benchmarkWasInProgress: false)
        #expect(d.backend == .coreML && d.mustClearSentinels == true)

        // Died mid-benchmark (even during the CoreML leg with MLX persisted).
        d = TVBackendRecovery.launchBackend(persistedRaw: "mlx",
                                            pendingEngineBackendRaw: nil,
                                            benchmarkWasInProgress: true)
        #expect(d.backend == .coreML && d.mustClearSentinels == true)

        // No persisted value: CoreML default.
        d = TVBackendRecovery.launchBackend(persistedRaw: nil,
                                            pendingEngineBackendRaw: nil,
                                            benchmarkWasInProgress: false)
        #expect(d.backend == .coreML && d.mustClearSentinels == false)

        // Unknown raw value degrades to CoreML.
        d = TVBackendRecovery.launchBackend(persistedRaw: "quantum",
                                            pendingEngineBackendRaw: nil,
                                            benchmarkWasInProgress: false)
        #expect(d.backend == .coreML)
    }

    @Test("Simulator clamps both backends to CoreML device codes")
    func simulatorClamp() {
        // These tests run on the iOS Simulator, so the clamp is active.
        #expect(TVEngineBackend.coreML.deviceAssignments == [100])
        #expect(TVEngineBackend.mlx.deviceAssignments == [100])
        #expect(TVEngineBackend.mlxIsAvailable == false)
    }
}
