// PROTOTYPE (wayfinder #37), throwaway: the FP16 Mish sweep (research note section 3.6) on every compute unit.
//
// Inputs: every finite FP16 value in [-30, 30] (40,705 of them), then +-65504, +-inf and NaN, padded to 40,960 and
// tiled 25 times (Core ML keeps a smaller elementwise graph on the CPU whatever it is asked); every tile must match. Models (build_mish.py):
// MILBuilder's branch-free Mish, as Core ML runs it and as #36's translator hands it to Core AI, plus PyTorch's
// decomposition as a positive control. Reference: float64 x * tanh(max(x, 0) + log1p(exp(-|x|))).
//
// Branch-free Mish passes a unit when, over [-30, 30]: no catastrophic error (> 10% of max(1, |ref|)), max abs error
// <= 3e-3, and y == x exactly for every x >= 12. The gate judges Core AI on the Neural Engine; the rest is reported.
// The control must show catastrophic errors on the Neural Engine, or the sweep proves nothing.
import CoreML
import Foundation
import Metal

struct MishInputs {
    static let shape = [1, 256, 64, 64]  // build_mish.py's SHAPE
    let x: [Float]        // the block below, tiled to fill `shape`
    let block: Int        // sweep + specials + zero padding
    let sweepCount: Int   // the first sweepCount values of each block are the [-30, 30] sweep
    let specials: [Float]

    init() {
        var vals: [Float] = []
        for bits in UInt16.min...UInt16.max {
            let h = Float16(bitPattern: bits)
            if h.isFinite && h >= -30 && h <= 30 && !(h == 0 && h.sign == .minus) { vals.append(Float(h)) }
        }
        vals.sort()
        sweepCount = vals.count
        specials = [65504, -65504, .infinity, -.infinity, .nan]
        var one = vals + specials
        one += [Float](repeating: 0, count: 40960 - one.count)
        let n = one.count
        block = n
        x = (0..<MishInputs.shape.reduce(1, *)).map { one[$0 % n] }
    }
}

func mishReference(_ x: Double) -> Double { x * tanh(max(x, 0) + log1p(exp(-abs(x)))) }

struct SweepResult {
    var maxAbs = 0.0, maxRel = 0.0, wrms = 0.0
    var catastrophic = 0, identityViolations = 0
    var pinned: [String: Float] = [:]
    var specials: [String: Float] = [:]
    var worstX = 0.0
    var tileMismatches = 0  // elements whose output differs from the same input's output in the first tile

    func passes() -> Bool { catastrophic == 0 && maxAbs <= 3e-3 && identityViolations == 0 }
    var json: JSON {
        ["maxAbs": maxAbs, "maxRel": maxRel, "wrms": wrms, "catastrophic": catastrophic,
         "identityViolations": identityViolations, "worstX": worstX, "tileMismatches": tileMismatches,
         "pinned": pinned.mapValues { Double($0) }, "specials": specials.mapValues { "\($0)" }, "passes": passes()]
    }
}

func analyzeSweep(_ inp: MishInputs, _ y: [Float]) -> SweepResult {
    var r = SweepResult()
    var wsum = 0.0, wsq = 0.0
    for i in 0..<inp.sweepCount {
        let x = Double(inp.x[i]), yi = Double(y[i]), ref = mishReference(x)
        let e = yi.isFinite ? abs(yi - ref) : .infinity
        if e > r.maxAbs { r.maxAbs = e; r.worstX = x }
        if x >= 0.25 { r.maxRel = max(r.maxRel, e / abs(ref)) }
        let w = exp(-x * x / 18)
        wsum += w; wsq += w * (e.isFinite ? e * e : 1e10)
        if !(e <= 0.1 * max(1, abs(ref))) { r.catastrophic += 1 }
        if x >= 12 && y[i] != inp.x[i] { r.identityViolations += 1 }
    }
    r.wrms = (wsq / wsum).squareRoot()
    let labels = ["10.3906", "10.3984", "11.0859", "11.0938"]
    for (k, p) in [Float(10.390625), 10.3984375, 11.0859375, 11.09375].enumerated() {
        if let i = inp.x.prefix(inp.sweepCount).firstIndex(of: p) { r.pinned[labels[k]] = y[i] }
    }
    for (k, s) in ["+65504", "-65504", "+inf", "-inf", "NaN"].enumerated() { r.specials[s] = y[inp.sweepCount + k] }
    for i in inp.block..<y.count where y[i].bitPattern != y[i % inp.block].bitPattern { r.tileMismatches += 1 }
    return r
}

func mishMode(_ o: Options, assets: URL, outDir: URL) async throws -> JSON {
    let inp = MishInputs()
    let device = MTLCreateSystemDefaultDevice()!
    let shape = MishInputs.shape
    let units = o.string("units", "cpu,gpu,ane").split(separator: ",").map(String.init)
    log("\n## FP16 Mish sweep: \(inp.sweepCount) values in [-30, 30] plus \(inp.specials.count) specials")
    var rows: [JSON] = []
    var verdictProblems: [String] = []
    log("| model | framework | unit (Core ML: as placed) | max abs err | max rel err (x >= 0.25) | wRMS | catastrophic | y != x for x >= 12 | 10.3906 / 10.3984 / 11.0859 / 11.0938 | +inf / -inf / NaN | tile mismatches | passes |")
    log("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for model in ["mish", "mishtorch"] {
        for fw in ["coreml", "coreai"] {
            for unit in units {
                var y: [Float]
                var placed = unit  // Core AI: the preferred unit; Core ML: where MLComputePlan puts the ops
                if fw == "coreai" {
                    let f = try await CoreAIFunction(url: assets.appendingPathComponent("mish/\(model)_ai.aimodel"), unit: unit)
                    let enc = try ProbeEncoder(f, device: device)
                    _ = try enc.run(inp.x)
                    y = try enc.run(inp.x)
                } else {
                    let (u, _) = try await compiledCoreMLModel(assets.appendingPathComponent("mish/\(model)_ml.mlpackage"),
                                                               cacheDir: cacheRoot.appendingPathComponent("coreml-cache"))
                    let cfg = MLModelConfiguration()
                    cfg.computeUnits = unit == "cpu" ? .cpuOnly : (unit == "gpu" ? .cpuAndGPU : .cpuAndNeuralEngine)
                    let m = try MLModel(contentsOf: u, configuration: cfg)
                    placed = try await coreMLPlacement(u, cfg)
                    let arr = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
                    inp.x.withUnsafeBufferPointer { arr.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: inp.x.count) }
                    let fp = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: arr)])
                    _ = try await m.prediction(from: fp)
                    let out = try await m.prediction(from: fp).featureValue(for: "y")!.multiArrayValue!
                    y = [Float](repeating: 0, count: inp.x.count)
                    let sh = out.shape.map(\.intValue), st = out.strides.map(\.intValue)
                    y.withUnsafeMutableBufferPointer { copyStrided(from: out.dataPointer.assumingMemoryBound(to: Float.self), shape: sh, strides: st, to: $0.baseAddress!) }
                }
                let r = analyzeSweep(inp, y)
                let pins = ["10.3906", "10.3984", "11.0859", "11.0938"].map { r.pinned[$0].map { fmt(Double($0), 5) } ?? "?" }
                let sp = ["+inf", "-inf", "NaN"].map { r.specials[$0].map { "\($0)" } ?? "?" }
                log("| \(model) | \(fw) | \(placed) | \(fmt(r.maxAbs)) | \(fmt(r.maxRel)) | \(fmt(r.wrms)) | \(r.catastrophic) | \(r.identityViolations) | \(pins.joined(separator: " / ")) | \(sp.joined(separator: " / ")) | \(r.tileMismatches) | \(model == "mish" ? (r.passes() ? "yes" : "NO") : "control") |")
                var j = r.json
                j["model"] = model; j["framework"] = fw; j["unit"] = unit; j["placed"] = placed
                rows.append(j)
                if model == "mish" && fw == "coreai" && unit == "ane" && !r.passes() { verdictProblems.append("Core AI ANE fails the Mish sweep") }
                if fw == "coreml" && unit == "ane" && placed != "ane" { verdictProblems.append("Core ML ran the \(model) sweep on \(placed), not the ANE") }
                if model == "mishtorch" && unit == "ane" && r.catastrophic == 0 { verdictProblems.append("the \(fw) ANE control showed no catastrophic error, so the sweep cannot be trusted") }
            }
        }
    }
    let verdict = verdictProblems.isEmpty ? "PASS" : "FAIL: " + verdictProblems.joined(separator: "; ")
    log("\nMish sweep (judged: Core AI on the Neural Engine; control must fail there): \(verdict)")
    return ["mode": "mish", "rows": rows, "verdict": verdict, "sweepCount": inp.sweepCount]
}

/// Where MLComputePlan puts a compiled model's non-const ops: "ane", "gpu", "cpu", or a mix.
func coreMLPlacement(_ compiled: URL, _ cfg: MLModelConfiguration) async throws -> String {
    let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: cfg)
    var seen = Set<String>()
    if case .program(let program) = plan.modelStructure, let main = program.functions["main"] {
        for op in main.block.operations where op.operatorName != "const" {
            switch plan.deviceUsage(for: op)?.preferred {
            case .neuralEngine?: seen.insert("ane")
            case .gpu?: seen.insert("gpu")
            case .cpu?: seen.insert("cpu")
            default: seen.insert("?")
            }
        }
    }
    return seen.sorted().joined(separator: "+")
}
