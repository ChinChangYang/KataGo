//
//  NeuralNetworkModelGateTests.swift
//  KataGo AnytimeTests
//
//  Pins the per-net board-size caps in the registry. The Lionffen-class
//  nets are capped at nnLen 19: on the visionOS simulator's CoreML path
//  their searches abort above a measured board AREA (b6c64 crashes past
//  19x19 = 361 intersections — 20x20 and 37x19 die, 20x9 survives;
//  b24c64 past 31x31 = 961 — only 37x37 died), and both are 19x19-trained
//  nets regardless. nnLen: 19 keeps every reachable configuration inside
//  the proven-safe envelope through the existing machinery
//  (effectiveMaxBoardLength clamp -> boardFits gate -> New Game sizing).
//

import Testing
@testable import KataGoUICore

struct NeuralNetworkModelGateTests {
    private func model(_ fileName: String) -> NeuralNetworkModel? {
        NeuralNetworkModel.allCases.first { $0.fileName == fileName }
    }

    @Test func lionffenClassNetsAreCappedAt19() {
        #expect(model("lionffen.txt.gz")?.nnLen == 19)
        #expect(model("lionffen_b24c64_3x3_v3_12300.bin.gz")?.nnLen == 19)
    }

    @Test func cappedNetsClampTheEffectiveBuffer() {
        // min(userChoice, nnLen): even a persisted 37x37 Max Board Size
        // compiles the capped nets at 19.
        for fileName in ["lionffen.txt.gz",
                         "lionffen_b24c64_3x3_v3_12300.bin.gz"] {
            let nnLen = model(fileName)?.nnLen ?? 0
            #expect(min(BoardSizeChoice.thirtySevenMax.rawValue, nnLen) == 19)
        }
    }

    @Test func uncappedNetsKeepTheFullBuffer() {
        #expect(NeuralNetworkModel.builtInModel?.nnLen == 37)
        #expect(model("official.bin.gz")?.nnLen == 37)
    }

    @Test func cappedNetsSaySoInTheirDescriptions() {
        for fileName in ["lionffen.txt.gz",
                         "lionffen_b24c64_3x3_v3_12300.bin.gz"] {
            #expect(model(fileName)?.description
                .contains("boards up to 19x19") == true)
        }
    }
}
