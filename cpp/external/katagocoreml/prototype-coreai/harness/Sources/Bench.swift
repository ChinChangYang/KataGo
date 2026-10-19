// PROTOTYPE (wayfinder #37), throwaway: stage 1's speed measurement.
//
// A "round" is what one NN server thread call does with K rows. Arms:
//   coreml-app-b1xK      the app's CoreML/NE path: K concurrent batch-1 predictions (CoreMLApp.swift)
//   coreai-encode-b1xK   K concurrent batch-1 Core AI calls, same TaskGroup structure, synchronous encode + marker wait
//   coreai-run-b1xK      the same with the async run API
//   coreai-encode-bK     one call to a static batch-K function, encode on the calling thread
//   coreai-run-bK        the same with run
// Every arm reads the same rows (the parity positions, rotated each round) and writes the same output layout.
//
// Method, enforced here rather than left to whoever runs it:
//   - before every repetition the machine must be idle and at a nominal thermal state (Idle.swift), or the run stops;
//   - each repetition warms every arm up, then alternates the arms in blocks within this process, rotating their
//     order each cycle and discarding the first rounds of each block, until every arm has `samples` timed rounds;
//   - a repetition's figure is K / median round time; the reported figure is the median over >= 3 repetitions, and
//     the spread is (max - min) / median of the repetition figures. A spread of 2% or more voids that arm.
import CoreML
import Foundation
import Metal

protocol Arm: AnyObject {
    var name: String { get }
    var framework: String { get }
    var rows: Int { get }
    func round() throws
}

final class CoreMLAppArm: Arm {
    let name: String, framework = "coreml", rows: Int
    let handle: AppCoreMLHandle, buffers: RowBuffers
    init(_ h: AppCoreMLHandle, _ b: RowBuffers, k: Int) { handle = h; buffers = b; rows = k; name = "coreml-app-b1x\(k)" }
    func round() throws { handle.apply(buffers, batchSize: rows) }
}

/// K concurrent batch-1 calls, in the app's structure: detached task, TaskGroup, the caller waits on a semaphore.
final class CoreAIConcurrentArm: Arm {
    let name: String, framework = "coreai", rows: Int
    let encodeSlots: [EncodeSlot], runSlots: [RunSlot], buffers: RowBuffers
    init(encode: [EncodeSlot], run: [RunSlot], _ b: RowBuffers) {
        encodeSlots = encode; runSlots = run; buffers = b
        rows = max(encode.count, run.count)
        name = encode.isEmpty ? "coreai-run-b1x\(rows)" : "coreai-encode-b1x\(rows)"
    }
    func round() throws {
        let sem = DispatchSemaphore(value: 0)
        let es = encodeSlots, rs = runSlots, b = buffers, k = rows
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<k {
                    group.addTask {
                        do {
                            if es.isEmpty { try await rs[i].evaluate(b, first: i, count: 1) }
                            else { try es[i].evaluate(b, first: i, count: 1) }
                        } catch { fatalError("Core AI inference error: \(error)") }
                    }
                }
            }
            sem.signal()
        }
        sem.wait()
    }
}

/// One call to a static batch-K function.
final class CoreAIStaticArm: Arm {
    let name: String, framework = "coreai", rows: Int
    let encodeSlot: EncodeSlot?, runSlot: RunSlot?, buffers: RowBuffers
    init(encode: EncodeSlot?, run: RunSlot?, _ b: RowBuffers, k: Int) {
        encodeSlot = encode; runSlot = run; buffers = b; rows = k
        name = encode != nil ? "coreai-encode-b\(k)" : "coreai-run-b\(k)"
    }
    func round() throws {
        if let s = encodeSlot { try s.evaluate(buffers, first: 0, count: rows); return }
        let sem = DispatchSemaphore(value: 0)
        let s = runSlot!, b = buffers, k = rows
        Task.detached {
            do { try await s.evaluate(b, first: 0, count: k) } catch { fatalError("Core AI inference error: \(error)") }
            sem.signal()
        }
        sem.wait()
    }
}

/// The functions K concurrent batch-1 slots call. `per-model` (the default) gives each slot its own AIModel, loaded
/// from the cached specialization: on the M3 Max's Neural Engine, concurrent calls into one AIModel, through one
/// InferenceFunction or one per slot (`shared`, `per-slot`), returned wrong rows (`--mode agree`).
func concurrentFunctions(_ mode: String, k: Int, b1: CoreAIFunction, url: URL) async throws -> [CoreAIFunction] {
    var fns: [CoreAIFunction] = []
    for i in 0..<k {
        switch mode {
        case "shared": fns.append(b1)
        case "per-slot": fns.append(try b1.sibling())
        case "per-model": fns.append(i == 0 ? b1 : try await CoreAIFunction(url: url, unit: "ane"))
        default: throw HarnessError("--functions must be per-model, per-slot or shared")
        }
    }
    return fns
}

struct BenchConfig {
    var samples = 500, reps = 3, block = 100, blockWarmup = 5, warmup = 50
    var allowBusy = false
    var recordable: Bool { samples >= 500 && reps >= 3 && !allowBusy }
}

final class ArmStats {
    var repLatencyMs: [[Double]] = []   // per rep, timed round latencies
    var repWallNs: [UInt64] = []        // per rep, total timed ns
    var energy: [String: Double] = [:]  // joules per channel, timed blocks only
    var energyNs: UInt64 = 0
}

func runBench(arms: [Arm], positions: Positions, buffers: RowBuffers, cfg: BenchConfig, idle: IdleGate,
              power: PowerSampler?, label: String) throws -> JSON {
    let stats = arms.map { _ in ArmStats() }
    var roundCounter = 0
    func refreshInputs(_ k: Int) {
        for r in 0..<k { buffers.load(row: r, from: positions, index: (roundCounter * k + r) % positions.count) }
        roundCounter += 1
    }
    var repInfo: [JSON] = []
    for rep in 0..<cfg.reps {
        let gate = try idle.waitUntilIdle(context: "\(label) repetition \(rep + 1)/\(cfg.reps)")
        let thermalStart = ProcessInfo.processInfo.thermalState
        for a in arms {
            for _ in 0..<cfg.warmup { refreshInputs(a.rows); try a.round() }
        }
        for s in stats { s.repLatencyMs.append([]); s.repWallNs.append(0) }
        let cycles = (cfg.samples + cfg.block - 1) / cfg.block
        for c in 0..<cycles {
            for j in 0..<arms.count {
                let ai = (j + c) % arms.count
                let a = arms[ai], st = stats[ai]
                for _ in 0..<cfg.blockWarmup { refreshInputs(a.rows); try a.round() }
                let e0 = power?.sample()
                let n = min(cfg.block, cfg.samples - c * cfg.block)
                var blockNs: UInt64 = 0
                for _ in 0..<n {
                    refreshInputs(a.rows)
                    let t0 = nowNs()
                    try a.round()
                    let dt = nowNs() - t0
                    blockNs += dt
                    st.repLatencyMs[rep].append(Double(dt) / 1e6)
                }
                st.repWallNs[rep] += blockNs
                if let p = power, let e0 {
                    for (k, v) in p.delta(since: e0) { st.energy[k, default: 0] += v }
                    st.energyNs += blockNs
                }
            }
        }
        let thermalEnd = ProcessInfo.processInfo.thermalState
        let line = arms.enumerated().map { i, a in
            "\(a.name) \(fmt(Double(a.rows) / median(stats[i].repLatencyMs[rep]) * 1000, 4))/s"
        }.joined(separator: ", ")
        log("  rep \(rep + 1): \(line); thermal \(thermalName(thermalStart)) -> \(thermalName(thermalEnd))")
        repInfo.append(["idle": gate, "thermalStart": thermalName(thermalStart), "thermalEnd": thermalName(thermalEnd)])
    }

    // Summaries
    var armJSON: [JSON] = []
    var headline: [String: Double] = [:], spreads: [String: Double] = [:]
    for (i, a) in arms.enumerated() {
        let st = stats[i]
        let repThroughput = st.repLatencyMs.map { Double(a.rows) / median($0) * 1000 }
        let repSustained = zip(st.repLatencyMs, st.repWallNs).map { lat, ns in Double(a.rows * lat.count) / (Double(ns) / 1e9) }
        let all = st.repLatencyMs.flatMap { $0 }.sorted()
        let med = median(repThroughput)
        let spread = (repThroughput.max()! - repThroughput.min()!) / med
        headline[a.name] = med; spreads[a.name] = spread
        var j: JSON = ["arm": a.name, "framework": a.framework, "rowsPerRound": a.rows,
                       "samplesPerRep": st.repLatencyMs.map(\.count),
                       "repThroughput": repThroughput, "repSustainedThroughput": repSustained,
                       "medianThroughput": med, "spread": spread, "void": spread >= 0.02,
                       "latencyMs": ["p10": percentileSorted(all, 10), "p50": percentileSorted(all, 50),
                                     "p90": percentileSorted(all, 90), "p99": percentileSorted(all, 99)]]
        if st.energyNs > 0 {
            let secs = Double(st.energyNs) / 1e9
            let evals = Double(a.rows * all.count)
            j["powerW"] = st.energy.mapValues { $0 / secs }
            j["millijoulePerEval"] = st.energy.mapValues { $0 / evals * 1000 }
        }
        armJSON.append(j)
    }
    let ml = arms.first { $0.framework == "coreml" }!.name
    let best = arms.filter { $0.framework == "coreai" }.max { headline[$0.name]! < headline[$1.name]! }!.name
    let ratio = headline[best]! / headline[ml]!
    let void = spreads[ml]! >= 0.02 || spreads[best]! >= 0.02

    log("\n| arm | evals/s (median of reps) | spread | vs CoreML/NE | p50 latency ms | void |")
    log("|---|---|---|---|---|---|")
    for j in armJSON {
        let n = j["arm"] as! String
        let lat = j["latencyMs"] as! [String: Double]
        log("| \(n) | \(fmt(headline[n]!, 4)) | \(pct(spreads[n]!)) | \(pct(headline[n]! / headline[ml]!)) | \(fmt(lat["p50"]!, 3)) | \(spreads[n]! >= 0.02 ? "VOID" : "") |")
    }
    if power != nil {
        log("\nPower over timed blocks (W) and energy per evaluation (mJ):")
        for j in armJSON {
            if let p = j["powerW"] as? [String: Double], let e = j["millijoulePerEval"] as? [String: Double] {
                log("  \(j["arm"]!): " + p.keys.sorted().map { "\($0) \(fmt(p[$0]!, 3)) W / \(fmt(e[$0]!, 3)) mJ" }.joined(separator: ", "))
            }
        }
    }
    let verdict: String
    if !cfg.recordable { verdict = "SMOKE RUN, NOT FOR THE RECORD (needs >= 500 samples, >= 3 reps, an idle machine)" }
    else if void { verdict = "VOID: a spread is 2% or more; repeat the run" }
    else { verdict = ratio >= 0.98 ? "PASS" : "FAIL" }
    log("\n\(label): fastest Core AI arm \(best) = \(pct(ratio)) of \(ml) (passes at >= 98%): \(verdict)")
    return ["label": label, "arms": armJSON, "reps": repInfo, "coreml": ml, "bestCoreAI": best, "ratio": ratio,
            "void": void, "recordable": cfg.recordable, "verdict": verdict,
            "config": ["samples": cfg.samples, "reps": cfg.reps, "block": cfg.block, "blockWarmup": cfg.blockWarmup,
                       "warmup": cfg.warmup]]
}

/// Builds the arms for each K and runs them.
func speedMode(_ o: Options, assets: URL, outDir: URL, idle: IdleGate) async throws -> JSON {
    let cfg = BenchConfig(samples: o.int("samples", 500), reps: o.int("reps", 3), block: o.int("block", 100),
                          blockWarmup: o.int("block-warmup", 5), warmup: o.int("warmup", 50),
                          allowBusy: o.has("allow-busy"))
    let judgedK = o.int("k", 2)
    let ks = o.ints("sweep", [judgedK])
    let coremlName = o.string("coreml", Platform.name == "iOS" ? "b18_19_n3" : "b18_19_n8")
    let apis = o.string("apis", "encode,run").split(separator: ",").map(String.init)
    let patterns = o.string("patterns", "concurrent,static").split(separator: ",").map(String.init)
    let functionsMode = o.string("functions", "per-model")
    let agreeRepeats = o.int("agree-repeats", 25)
    let positions = try Positions(dir: assets.appendingPathComponent("parity_19"))
    let power = o.has("no-power") ? nil : PowerSampler.make()
    log("power: \(power?.describe ?? "not exposed on this device")")

    let (compiled, _) = try await compiledCoreMLModel(assets.appendingPathComponent("coreml/\(coremlName).mlpackage"),
                                                      cacheDir: cacheRoot.appendingPathComponent("coreml-cache"))
    let handle = try AppCoreMLHandle(compiledURL: compiled, board: 19)
    let device = MTLCreateSystemDefaultDevice()!
    let b1 = try await CoreAIFunction(url: assets.appendingPathComponent("coreai/b18_19_b1.aimodel"), unit: "ane")
    var results: [JSON] = []
    for k in ks {
        let buffers = RowBuffers(rows: k, board: 19, numSpatial: positions.numSpatial, numGlobal: positions.numGlobal,
                                 outSizes: handle.outSizes)
        for t in b1.outputs where t.rowElements != handle.outSizes[t.name] {
            throw HarnessError("output \(t.name): Core AI row \(t.rowElements) vs Core ML \(handle.outSizes[t.name] ?? -1)")
        }
        var arms: [Arm] = [CoreMLAppArm(handle, buffers, k: k)]
        if patterns.contains("concurrent") {
            let fns = try await concurrentFunctions(functionsMode, k: k, b1: b1, url: assets.appendingPathComponent("coreai/b18_19_b1.aimodel"))
            if apis.contains("encode") { arms.append(CoreAIConcurrentArm(encode: try fns.map { try EncodeSlot($0, device: device) }, run: [], buffers)) }
            if apis.contains("run") { arms.append(CoreAIConcurrentArm(encode: [], run: fns.map { RunSlot($0) }, buffers)) }
        }
        if patterns.contains("static") {
            let url = assets.appendingPathComponent("coreai/b18_19_b\(k).aimodel")
            if FileManager.default.fileExists(atPath: url.path) {
                let fk = k == 1 ? b1 : try await CoreAIFunction(url: url, unit: "ane")
                guard fk.batch == k else { throw HarnessError("\(url.lastPathComponent) has batch \(fk.batch)") }
                if apis.contains("encode") { arms.append(CoreAIStaticArm(encode: try EncodeSlot(fk, device: device), run: nil, buffers, k: k)) }
                if apis.contains("run") { arms.append(CoreAIStaticArm(encode: nil, run: RunSlot(fk), buffers, k: k)) }
            } else {
                log("no static batch-\(k) function (\(url.lastPathComponent)); skipping that pattern")
            }
        }
        let label = "speed K=\(k)" + (k == judgedK ? " (judged on the iPad)" : " (diagnostic)")
        log("\n## \(label): \(arms.map(\.name).joined(separator: ", ")); Core ML model \(coremlName); concurrent slots: \(functionsMode) functions")
        // Before timing, every Core AI arm must return Core ML's rows (within FP16 noise) on fresh positions; an arm
        // that returns a wrong row is disqualified and never timed.
        let candidates = arms
        let agreement = try await onDedicatedThread { agreement(candidates, buffers: buffers, positions: positions, repeats: agreeRepeats) }
        var disqualified: [JSON] = []
        for a in agreement {
            log("agreement \(a.arm): \(a.badRows) of \(a.rows) rows wrong; max |diff| \(fmt(a.maxDiff)) \(a.head)" + (a.badRows > 0 ? "  DISQUALIFIED" : ""))
            if a.badRows > 0 { disqualified.append(["arm": a.arm, "badRows": a.badRows, "rows": a.rows, "maxDiff": a.maxDiff]) }
        }
        let bad = Set(disqualified.map { $0["arm"] as! String })
        let timed = arms.filter { !bad.contains($0.name) }
        guard timed.contains(where: { $0.framework == "coreai" }) else { throw HarnessError("every Core AI arm returned wrong rows") }
        var r = try await onDedicatedThread {
            try runBench(arms: timed, positions: positions, buffers: buffers, cfg: cfg, idle: idle, power: power, label: label)
        }
        r["disqualified"] = disqualified
        r["functions"] = functionsMode
        r["k"] = k
        r["judged"] = k == judgedK && Platform.name == "iOS"
        results.append(r)
    }
    return ["mode": "speed", "coremlModel": coremlName, "runs": results]
}

/// Sanity check before timing: every arm computes the same thing on the same rows (within FP16 noise of each other).
/// Each arm runs `repeats` rounds on fresh positions against Core ML's answer for them; a wrong row fails the run.
func checkArmsAgree(_ arms: [Arm], buffers: RowBuffers, positions: Positions, repeats: Int = 3) throws {
    let report = agreement(arms, buffers: buffers, positions: positions, repeats: repeats)
    if let bad = report.first(where: { $0.badRows > 0 }) {
        throw HarnessError("\(bad.arm) disagrees with \(arms[0].name): \(bad.badRows) of \(bad.rows) rows wrong, max |diff| \(fmt(bad.maxDiff)) on \(bad.head)")
    }
}

struct Agreement { let arm: String; var rows = 0, badRows = 0, crossTalk = 0; var maxDiff = 0.0; var head = "" }

func agreement(_ arms: [Arm], buffers: RowBuffers, positions: Positions, repeats: Int) -> [Agreement] {
    var out = arms.dropFirst().map { Agreement(arm: $0.name) }
    for rep in 0..<repeats {
        for r in 0..<buffers.rows { buffers.load(row: r, from: positions, index: (rep * buffers.rows + r) % positions.count) }
        try? arms[0].round()
        var ref: [[String: [Float]]] = []
        for r in 0..<buffers.rows { ref.append(Dictionary(uniqueKeysWithValues: Heads.all.map { ($0, buffers.output($0, row: r)) })) }
        for (i, a) in arms.dropFirst().enumerated() {
            for h in Heads.all { for r in 0..<buffers.rows { memset(buffers.outs[h]! + r * buffers.outSizes[h]!, 0xff, buffers.outSizes[h]! * 4) } }
            do { try a.round() } catch { out[i].badRows += a.rows; continue }
            for r in 0..<a.rows {
                out[i].rows += 1
                var worst = 0.0, worstHead = ""
                func dist(_ refRow: Int) -> (Double, String) {
                    var w = 0.0, wh = ""
                    for h in Heads.all {
                        let d = zip(buffers.output(h, row: r), ref[refRow][h]!).map { abs(Double($0) - Double($1)) }.max() ?? 0
                        if !(d <= w) { w = d; wh = h }
                    }
                    return (w, wh)
                }
                (worst, worstHead) = dist(r)
                if !(worst < 0.5) {
                    out[i].badRows += 1
                    // Cross-talk: is the wrong row another row's answer from the same round?
                    if (0..<a.rows).contains(where: { $0 != r && dist($0).0 < 0.5 }) { out[i].crossTalk += 1 }
                }
                if !(worst <= out[i].maxDiff) { out[i].maxDiff = worst; out[i].head = worstHead }
            }
        }
    }
    return out
}

/// Diagnostic: how often each Core AI arm returns rows that differ from Core ML's, per K, over many rounds.
func agreeMode(_ o: Options, assets: URL, outDir: URL) async throws -> JSON {
    let ks = o.ints("sweep", [2]), repeats = o.int("repeats", 50)
    let coremlName = o.string("coreml", Platform.name == "iOS" ? "b18_19_n3" : "b18_19_n8")
    let positions = try Positions(dir: assets.appendingPathComponent("parity_19"))
    let (compiled, _) = try await compiledCoreMLModel(assets.appendingPathComponent("coreml/\(coremlName).mlpackage"),
                                                      cacheDir: cacheRoot.appendingPathComponent("coreml-cache"))
    let handle = try AppCoreMLHandle(compiledURL: compiled, board: 19)
    let device = MTLCreateSystemDefaultDevice()!
    let b1 = try await CoreAIFunction(url: assets.appendingPathComponent("coreai/b18_19_b1.aimodel"), unit: "ane")
    var res: [JSON] = []
    for k in ks {
        let buffers = RowBuffers(rows: k, board: 19, numSpatial: positions.numSpatial, numGlobal: positions.numGlobal, outSizes: handle.outSizes)
        // --functions shared: every slot calls one InferenceFunction; per-slot: each slot loads its own from the same
        // AIModel; per-model: each slot specializes (loads from cache) its own AIModel.
        let mode = o.string("functions", "per-model")
        let fns = try await concurrentFunctions(mode, k: k, b1: b1, url: assets.appendingPathComponent("coreai/b18_19_b1.aimodel"))
        log("K=\(k): concurrent Core AI slots use \(mode) functions")
        var arms: [Arm] = [CoreMLAppArm(handle, buffers, k: k),
                           CoreAIConcurrentArm(encode: try fns.map { try EncodeSlot($0, device: device) }, run: [], buffers),
                           CoreAIConcurrentArm(encode: [], run: fns.map { RunSlot($0) }, buffers)]
        let bk = assets.appendingPathComponent("coreai/b18_19_b\(k).aimodel")
        if FileManager.default.fileExists(atPath: bk.path) {
            let fk = k == 1 ? b1 : try await CoreAIFunction(url: bk, unit: "ane")
            arms.append(CoreAIStaticArm(encode: try EncodeSlot(fk, device: device), run: nil, buffers, k: k))
            arms.append(CoreAIStaticArm(encode: nil, run: RunSlot(fk), buffers, k: k))
        }
        let armsCopy = arms
        let rep = try await onDedicatedThread { agreement(armsCopy, buffers: buffers, positions: positions, repeats: repeats) }
        for a in rep {
            log("K=\(k) \(a.arm): \(a.badRows) of \(a.rows) rows wrong (\(a.crossTalk) of them another row's answer); max |diff| \(fmt(a.maxDiff)) \(a.head)")
            res.append(["k": k, "arm": a.arm, "rows": a.rows, "badRows": a.badRows, "crossTalk": a.crossTalk, "maxDiff": a.maxDiff,
                        "head": a.head, "functions": mode])
        }
    }
    return ["mode": "agree", "results": res, "verdict": res.contains { ($0["badRows"] as! Int) > 0 } ? "FAIL: wrong rows" : "PASS"]
}

/// Power, recorded only: each K=judged arm runs alone and continuously for `--seconds` after the idle gate, and the
/// readable energy counters give watts and millijoules per evaluation. Continuous windows keep one arm's energy from
/// bleeding into the next, which the interleaved speed blocks cannot promise.
func powerMode(_ o: Options, assets: URL, outDir: URL, idle: IdleGate) async throws -> JSON {
    guard let power = PowerSampler.make() else {
        log("power: not exposed on this device")
        return ["mode": "power", "exposed": false, "verdict": "PASS (not gating; not exposed)"]
    }
    log("power: \(power.describe); running as uid \(getuid())")
    let k = o.int("k", 2), seconds = o.double("seconds", 20)
    let coremlName = o.string("coreml", Platform.name == "iOS" ? "b18_19_n3" : "b18_19_n8")
    let positions = try Positions(dir: assets.appendingPathComponent("parity_19"))
    let (compiled, _) = try await compiledCoreMLModel(assets.appendingPathComponent("coreml/\(coremlName).mlpackage"),
                                                      cacheDir: cacheRoot.appendingPathComponent("coreml-cache"))
    let handle = try AppCoreMLHandle(compiledURL: compiled, board: 19)
    let device = MTLCreateSystemDefaultDevice()!
    let b1 = try await CoreAIFunction(url: assets.appendingPathComponent("coreai/b18_19_b1.aimodel"), unit: "ane")
    let buffers = RowBuffers(rows: k, board: 19, numSpatial: positions.numSpatial, numGlobal: positions.numGlobal, outSizes: handle.outSizes)
    let fns = try await concurrentFunctions(o.string("functions", "per-model"), k: k, b1: b1, url: assets.appendingPathComponent("coreai/b18_19_b1.aimodel"))
    var arms: [Arm] = [CoreMLAppArm(handle, buffers, k: k),
                       CoreAIConcurrentArm(encode: try fns.map { try EncodeSlot($0, device: device) }, run: [], buffers)]
    let bk = assets.appendingPathComponent("coreai/b18_19_b\(k).aimodel")
    if FileManager.default.fileExists(atPath: bk.path) {
        let fk = k == 1 ? b1 : try await CoreAIFunction(url: bk, unit: "ane")
        arms.append(CoreAIStaticArm(encode: try EncodeSlot(fk, device: device), run: nil, buffers, k: k))
        arms.append(CoreAIStaticArm(encode: nil, run: RunSlot(fk), buffers, k: k))
    }
    let armsCopy = arms
    let rows: [JSON] = try await onDedicatedThread {
        try checkArmsAgree(armsCopy, buffers: buffers, positions: positions, repeats: 25)
        var out: [JSON] = []
        for r in 0..<k { buffers.load(row: r, from: positions, index: r) }
        for a in armsCopy {
            try idle.waitUntilIdle(context: "power \(a.name)")
            for _ in 0..<50 { try a.round() }
            let e0 = power.sample()!
            let t0 = nowNs()
            var rounds = 0
            while Double(nowNs() - t0) / 1e9 < seconds { try a.round(); rounds += 1 }
            let secs = Double(nowNs() - t0) / 1e9
            let e = power.delta(since: e0)
            let evals = Double(rounds * a.rows)
            let w = e.mapValues { $0 / secs }, mj = e.mapValues { $0 / evals * 1000 }
            log("  \(a.name): \(fmt(evals / secs, 4)) evals/s; " + w.keys.sorted().map { "\($0) \(fmt(w[$0]!, 3)) W, \(fmt(mj[$0]!, 3)) mJ/eval" }.joined(separator: "; "))
            out.append(["arm": a.name, "seconds": secs, "evalsPerSecond": evals / secs, "watts": w, "millijoulePerEval": mj])
        }
        return out
    }
    return ["mode": "power", "exposed": true, "channels": power.channels, "unread": power.unread, "uid": Int(getuid()),
            "k": k, "arms": rows, "verdict": "PASS (not gating)"]
}
