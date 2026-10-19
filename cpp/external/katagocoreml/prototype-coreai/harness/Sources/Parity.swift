// PROTOTYPE (wayfinder #37), throwaway: Core AI against Core ML, element by element, on this device's Neural Engine.
//
// #36's positions, at 19x19 and 37x37. Core ML runs the batch-1 model through the app's path (CoreMLApp.swift) with
// `.cpuAndNeuralEngine`; Core AI runs the batch-1 static function with `.neuralEngine` preferred, through encode.
// Both are compared with each other and with the FP32 reference (Core ML FP32 on the Mac's CPU, from prepare.sh).
//
// What is judged here (gate ticket, "What passes"): at 37x37, every head's error against FP32 at p50, p99, p99.9 and
// max, and its RMS, must be at most 1.10x CoreML/NE's; an FP16 overflow fails only if Core AI alone shows it. 19x19 is
// reported the same way, but the gate judges 19x19 on stage 2's testgpuerror.
import CoreML
import Foundation
import Metal

/// postProcessParams.leadMultiplier of kata1-b18c384nbt-s9996604416-d4316597426 (as in parity.py).
let leadMultiplier = 20.0

func parityMode(_ o: Options, assets: URL, outDir: URL) async throws -> JSON {
    let device = MTLCreateSystemDefaultDevice()!
    var boards: [JSON] = []
    var failures: [String] = []
    for board in o.ints("boards", [19, 37]) {
        let pos = try Positions(dir: assets.appendingPathComponent("parity_\(board)"))
        log("\n## Parity \(board)x\(board): \(pos.count) positions")
        let cache = cacheRoot.appendingPathComponent("coreml-cache")
        let (mlURL, _) = try await compiledCoreMLModel(assets.appendingPathComponent("coreml/b18_\(board)_n1.mlpackage"), cacheDir: cache)
        let ml = try AppCoreMLHandle(compiledURL: mlURL, board: board)
        let rows = RowBuffers(rows: 1, board: board, numSpatial: pos.numSpatial, numGlobal: pos.numGlobal, outSizes: ml.outSizes)

        func collect(_ eval: () throws -> Void) rethrows -> [String: [Float]] {
            var out: [String: [Float]] = Dictionary(uniqueKeysWithValues: Heads.all.map { ($0, []) })
            for i in 0..<pos.count {
                rows.load(row: 0, from: pos, index: i)
                try eval()  // warm-up: the comparison should not depend on a first call
                try eval()
                for h in Heads.all { out[h]! += rows.output(h, row: 0) }
            }
            return out
        }
        let mlOut = collect { ml.apply(rows, batchSize: 1) }

        // The app's own model (dynamic batch) evaluated at batch 1 should give Core ML's batch-1 bits.
        var appNote: JSON = [:]
        let appName = Platform.name == "iOS" ? "b18_19_n3" : "b18_19_n8"
        if board == 19, FileManager.default.fileExists(atPath: assets.appendingPathComponent("coreml/\(appName).mlpackage").path) {
            let (u, _) = try await compiledCoreMLModel(assets.appendingPathComponent("coreml/\(appName).mlpackage"), cacheDir: cache)
            let app = try AppCoreMLHandle(compiledURL: u, board: board)
            let appOut = collect { app.apply(rows, batchSize: 1) }
            let d = Heads.all.map { h in zip(appOut[h]!, mlOut[h]!).map { abs(Double($0) - Double($1)) }.max() ?? 0 }.max() ?? 0
            appNote = ["model": appName, "maxAbsDiffVsBatch1": d]
            log("app model \(appName) at batch 1 vs the batch-1 model: max |diff| \(fmt(d))")
        }

        let ai = try await CoreAIFunction(url: assets.appendingPathComponent("coreai/b18_\(board)_b1.aimodel"), unit: "ane")
        let slot = try EncodeSlot(ai, device: device)
        let aiOut = try collect { try slot.evaluate(rows, first: 0, count: 1) }

        // encode and run must agree bit for bit (the research note verified this on a tower; recheck on the network).
        let runSlot = RunSlot(ai)
        var encodeRunMaxDiff = 0.0
        for i in 0..<min(4, pos.count) {
            rows.load(row: 0, from: pos, index: i)
            try slot.evaluate(rows, first: 0, count: 1)
            let e = Heads.all.flatMap { rows.output($0, row: 0) }
            try await runSlot.evaluate(rows, first: 0, count: 1)
            let r = Heads.all.flatMap { rows.output($0, row: 0) }
            encodeRunMaxDiff = max(encodeRunMaxDiff, zip(e, r).map { abs(Double($0) - Double($1)) }.max() ?? 0)
        }
        log("Core AI encode vs run on the first positions: max |diff| \(fmt(encodeRunMaxDiff))")

        let r = compareHeads(ml: mlOut, ai: aiOut, ref: pos.refs, positions: pos, judged: board == 37)
        failures += (r["failures"] as! [String]).map { "\(board)x\(board): \($0)" }
        var j = r
        j["board"] = board; j["positions"] = pos.count; j["appModel"] = appNote; j["encodeVsRunMaxDiff"] = encodeRunMaxDiff
        boards.append(j)
    }
    let verdict = failures.isEmpty ? "PASS" : "FAIL: " + failures.joined(separator: "; ")
    log("\nParity (37x37 element criterion, overflow rule): \(verdict)")
    return ["mode": "parity", "boards": boards, "verdict": verdict]
}

private let pcts: [Double] = [50, 99, 99.9, 100]

private func errStats(_ d: [Double]) -> (p: [Double], rms: Double) {
    let s = d.sorted()
    let rms = (d.reduce(0) { $0 + $1 * $1 } / Double(max(d.count, 1))).squareRoot()
    return (pcts.map { percentileSorted(s, $0) }, rms)
}

private func ratio(_ a: Double, _ b: Double) -> Double { a == b ? 1 : (b == 0 ? .infinity : a / b) }

func compareHeads(ml: [String: [Float]], ai: [String: [Float]], ref: [String: [Float]], positions: Positions,
                  judged: Bool) -> JSON {
    var heads: [JSON] = []
    var failures: [String] = []
    var worst = 0.0
    log("\n| head | AI vs ML: p50 / p99 / p99.9 / max; rms | identical | ML vs FP32 | AI vs FP32 | AI/ML ratio p50 / p99 / p99.9 / max; rms |")
    log("|---|---|---|---|---|---|")
    for h in Heads.all {
        let m = ml[h]!.map(Double.init), a = ai[h]!.map(Double.init), r = ref[h]!.map(Double.init)
        let nonFiniteML = m.filter { !$0.isFinite }.count, nonFiniteAI = a.filter { !$0.isFinite }.count
        let dAM = zip(a, m).map { abs($0 - $1) }
        let eML = zip(m, r).map { abs($0 - $1) }, eAI = zip(a, r).map { abs($0 - $1) }
        let sAM = errStats(dAM), sML = errStats(eML), sAI = errStats(eAI)
        let ratios = zip(sAI.p, sML.p).map { ratio($0, $1) } + [ratio(sAI.rms, sML.rms)]
        let identical = Double(zip(a, m).filter { $0 == $1 }.count) / Double(a.count)
        worst = max(worst, ratios.max()!)
        if judged, let bad = ratios.first(where: { !($0 <= 1.10) }) { failures.append("\(h) error ratio \(fmt(bad)) > 1.10") }
        if nonFiniteAI > 0 && nonFiniteML == 0 { failures.append("\(h): Core AI alone overflows (\(nonFiniteAI) non-finite)") }
        let f4 = { (s: (p: [Double], rms: Double)) in s.p.map { fmt($0, 2) }.joined(separator: " / ") + "; " + fmt(s.rms, 2) }
        log("| \(h) | \(f4(sAM)) | \(pct(identical)) | \(f4(sML)) | \(f4(sAI)) | \(ratios.dropLast().map { fmt($0, 3) }.joined(separator: " / ")); \(fmt(ratios.last!, 3)) |")
        heads.append(["head": h, "aiVsMl": ["pcts": sAM.p, "rms": sAM.rms], "identicalFraction": identical,
                      "mlVsFP32": ["pcts": sML.p, "rms": sML.rms], "aiVsFP32": ["pcts": sAI.p, "rms": sAI.rms],
                      "ratioAIoverML": ratios, "nonFiniteML": nonFiniteML, "nonFiniteAI": nonFiniteAI])
    }
    log("worst AI/ML element error ratio: \(fmt(worst, 4))" + (judged ? " (judged: <= 1.10)" : " (reported; 19x19 is judged in stage 2)"))

    // testgpuerror-style statistics per position, reported only (as in #36).
    let sML = derivedErrors(ml, ref, positions), sAI = derivedErrors(ai, ref, positions)
    var derived: [JSON] = []
    log("\n| stat vs FP32 | Core ML p50 / p90 / max | Core AI p50 / p90 / max | max ratio | mean ratio |")
    log("|---|---|---|---|---|")
    for k in ["winrate %", "lead pts", "top policy %", "policy KL"] {
        let x = sML[k]!, y = sAI[k]!
        let sx = x.sorted(), sy = y.sorted()
        let f3 = { (s: [Double]) in [50.0, 90, 100].map { fmt(percentileSorted(s, $0), 3) }.joined(separator: " / ") }
        let maxR = ratio(sy.last!, sx.last!), meanR = ratio(mean(y), mean(x))
        log("| \(k) | \(f3(sx)) | \(f3(sy)) | \(fmt(maxR, 3)) | \(fmt(meanR, 3)) |")
        derived.append(["stat": k, "ml": [percentileSorted(sx, 50), percentileSorted(sx, 90), sx.last!],
                        "ai": [percentileSorted(sy, 50), percentileSorted(sy, 90), sy.last!],
                        "maxRatio": maxR, "meanRatio": meanR])
    }
    return ["heads": heads, "derived": derived, "worstElementRatio": worst, "judged": judged, "failures": failures]
}

/// Per-position |error| against the reference: winrate (%), lead (points), top-policy probability (%), policy KL.
func derivedErrors(_ y: [String: [Float]], _ ref: [String: [Float]], _ pos: Positions) -> [String: [Double]] {
    let n = pos.count, area = pos.board * pos.board
    let polPer = y[Heads.policy]!.count / n, passPer = y[Heads.pass]!.count / n
    let valPer = y[Heads.value]!.count / n, scPer = y[Heads.score]!.count / n
    func quantities(_ t: [String: [Float]], _ i: Int) -> (Double, Double, [Double]) {
        let v0 = Double(t[Heads.value]![i * valPer]), v1 = Double(t[Heads.value]![i * valPer + 1])
        let mx = max(v0, v1)
        let win = exp(v0 - mx) / (exp(v0 - mx) + exp(v1 - mx))
        let lead = Double(t[Heads.score]![i * scPer + 2]) * leadMultiplier
        var logits: [Double] = []
        for c in 0..<area where pos.mask[i * area + c] > 0 { logits.append(Double(t[Heads.policy]![i * polPer + c])) }
        logits.append(Double(t[Heads.pass]![i * passPer]))
        let lm = logits.max()!
        let e = logits.map { exp($0 - lm) }, s = e.reduce(0, +)
        return (win, lead, e.map { $0 / s })
    }
    var out: [String: [Double]] = ["winrate %": [], "lead pts": [], "top policy %": [], "policy KL": []]
    for i in 0..<n {
        let (w1, l1, p1) = quantities(y, i), (w0, l0, p0) = quantities(ref, i)
        let top = p0.indices.max { p0[$0] < p0[$1] }!
        var kl = 0.0
        for j in p0.indices where p0[j] > 0 { kl += p0[j] * (log(max(p0[j], 1e-300)) - log(max(p1[j], 1e-300))) }
        out["winrate %"]!.append(abs(w1 - w0) * 100)
        out["lead pts"]!.append(abs(l1 - l0))
        out["top policy %"]!.append(abs(p1[top] - p0[top]) * 100)
        out["policy KL"]!.append(kl)
    }
    return out
}
