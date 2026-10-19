// PROTOTYPE (wayfinder #37), throwaway: one load measurement per process (recorded, never gating).
//
//   coreai-cold    delete the specialization cache entry, then specialize the .aimodel for the Neural Engine
//   coreai-warm    the same .aimodel with its specialization cached
//   coreai-aot     the ahead-of-time .aimodelc for this device's architecture (`stage1.sh` compiles it), its cache
//                  entry deleted first; whether the load comes after an idle gap or back to back is the driver's doing
//   coreml-first   compile the .mlpackage and load it, as the app does on a cache miss (the OS's own ANE compiler
//                  cache may still hold this model from an earlier run; nothing public clears it)
//   coreml-cached  load the compiled model kept by coreml-first, as the app does on a cache hit
// Each measures load, function load (Core AI), and the first evaluation, in a fresh process started by the driver.
import CoreAIDelegates
import CoreAIRuntime
import CoreML
import Foundation
import Metal

func loadMode(_ o: Options, assets: URL, outDir: URL) async throws -> JSON {
    let what = o.string("what", "")
    let board = 19
    let positions = try Positions(dir: assets.appendingPathComponent("parity_19"))
    var phases: [String: Double] = [:]
    var detail: JSON = [:]
    let tStart = nowNs()
    func secs(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1e9 }
    switch what {
    case "coreai-cold", "coreai-warm", "coreai-aot":
        let url: URL
        if what == "coreai-aot" {
            let arch = AIModel.deviceArchitectureName
            url = URL(fileURLWithPath: o.string("aimodelc", assets.appendingPathComponent("aot/b18_19_b1.\(arch).aimodelc").path))
            detail["architecture"] = arch
        } else {
            url = assets.appendingPathComponent("coreai/b18_19_b1.aimodel")
        }
        // Cold and AOT loads start with no cache entry: an AOT .aimodelc, once loaded, is otherwise served from the
        // specialization cache in milliseconds, which is not what a first launch sees.
        if what != "coreai-warm" { try? AIModelCache.default.deleteEntries(for: url) }
        detail["model"] = url.lastPathComponent
        let t0 = nowNs()
        let model = try await AIModel(contentsOf: url, options: coreAIOptions("ane"))
        let t1 = nowNs()
        guard let fn = try step("loadFunction", { try model.loadFunction(named: "main") }) else { throw HarnessError("no main function") }
        let t2 = nowNs()
        _ = fn
        let f = try await CoreAIFunction(url: url, unit: "ane")  // cached in-process now; gives the I/O layout
        let rows = RowBuffers(rows: 1, board: board, numSpatial: positions.numSpatial, numGlobal: positions.numGlobal,
                              outSizes: Dictionary(uniqueKeysWithValues: f.outputs.map { ($0.name, $0.rowElements) }))
        rows.load(row: 0, from: positions, index: 0)
        let slot = try EncodeSlot(f, device: MTLCreateSystemDefaultDevice()!)
        let t3 = nowNs()
        try slot.evaluate(rows, first: 0, count: 1)
        let t4 = nowNs()
        phases = ["load": secs(t0, t1), "loadFunction": secs(t1, t2), "firstEval": secs(t3, t4), "total": secs(t0, t2) + secs(t3, t4)]
    case "coreml-first", "coreml-cached":
        let name = o.string("coreml", Platform.name == "iOS" ? "b18_19_n3" : "b18_19_n8")
        detail["model"] = name
        let cache = cacheRoot.appendingPathComponent("coreml-load-cache")
        let t0 = nowNs()
        let (compiled, compileSecs) = try await compiledCoreMLModel(assets.appendingPathComponent("coreml/\(name).mlpackage"),
                                                                    cacheDir: cache, recompile: what == "coreml-first")
        let t1 = nowNs()
        let h = try AppCoreMLHandle(compiledURL: compiled, board: board)
        let t2 = nowNs()
        let rows = RowBuffers(rows: 1, board: board, numSpatial: positions.numSpatial, numGlobal: positions.numGlobal, outSizes: h.outSizes)
        rows.load(row: 0, from: positions, index: 0)
        let t3 = nowNs()
        h.apply(rows, batchSize: 1)
        let t4 = nowNs()
        phases = ["compile": compileSecs ?? 0, "load": secs(t1, t2), "firstEval": secs(t3, t4), "total": secs(t0, t2) + secs(t3, t4)]
        if compileSecs == nil && what == "coreml-first" { throw HarnessError("coreml-first did not compile") }
    default:
        throw HarnessError("--what must be coreai-cold, coreai-warm, coreai-aot, coreml-first or coreml-cached")
    }
    let line = phases.keys.sorted().map { "\($0) \(fmt(phases[$0]!, 4)) s" }.joined(separator: ", ")
    log("LOAD \(what): \(line)")
    return ["mode": "load", "what": what, "phases": phases, "detail": detail, "time": isoNow(),
            "processSeconds": secs(tStart, nowNs())]
}
