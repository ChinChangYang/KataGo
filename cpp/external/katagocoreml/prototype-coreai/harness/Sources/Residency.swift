// PROTOTYPE (wayfinder #37), throwaway: assert that Core AI runs the network on the Neural Engine.
//
// Each model loads once more with debug info on (the SPI in spi/make_spi.sh) and `.neuralEngine` preferred. Each
// record names a delegate (MPSGraph_optimized, bnns, odix); each op carries one residency per lowering level, and the
// MPSGraph-level one says where the kernel runs (parity.py's reading, #36).
// Passes when: no bnns (CPU) records, every MPSGraph-level residency is ANE, and at most one MPSGraph op per function
// has no MPSGraph-level residency (the top-level function op, which #36 also saw). The Core ML models' compute plans
// are reported beside them.
import CoreAICompiler
import CoreAIDelegates
import CoreAIRuntime
import CoreML
import Foundation

func residencyMode(_ o: Options, assets: URL, outDir: URL) async throws -> JSON {
    let defaults = Platform.name == "iOS" ? "b18_19_b1,b18_19_b2,b18_37_b1" : "b18_19_b1,b18_19_b2,b18_19_b4,b18_19_b8,b18_37_b1"
    let names = o.string("models", defaults).split(separator: ",").map(String.init)
    var results: [JSON] = []
    var failures: [String] = []
    log("\n## Core AI residency, `.neuralEngine` preferred")
    log("| model | MPSGraph ops on ANE | MPSGraph ops elsewhere | MPSGraph ops with no kernel residency | bnns ops | odix ops | passes |")
    log("|---|---|---|---|---|---|---|")
    for n in names {
        let url = assets.appendingPathComponent("coreai/\(n).aimodel")
        guard FileManager.default.fileExists(atPath: url.path) else { log("| \(n) | missing | | | | | |"); continue }
        let model = try await loadAIModel(url, options: coreAIOptions("ane", debug: true))
        let data = try JSONEncoder().encode(model.debugInfos)
        try data.write(to: outDir.appendingPathComponent("residency-\(n).json"))
        let records = (try JSONSerialization.jsonObject(with: data) as? [JSON]) ?? []
        var counts: [String: Int] = [:]
        for rec in records {
            let delegate = (rec["identifier"] as? String ?? "?").components(separatedBy: "_op_id").first!
            for op in rec["operations"] as? [JSON] ?? [] {
                var level: String?, res: String?
                for m in op["metadatas"] as? [JSON] ?? [] {
                    let key = m["key"] as? String
                    let value = m["value"] as? JSON
                    if key == "op_id", let d = value?["dictionary"] as? JSON, let z = d["_0"] as? JSON,
                       let t = z["type"] as? JSON, let s = t["string"] as? JSON {
                        level = s["_0"] as? String
                    } else if key == "residency", level == "MPSGraph", let s = value?["string"] as? JSON {
                        res = s["_0"] as? String
                    }
                }
                counts["\(delegate):\(res ?? "none")", default: 0] += 1
            }
        }
        let ane = counts["MPSGraph_optimized:ANE"] ?? 0
        let none = counts["MPSGraph_optimized:none"] ?? 0
        let elsewhere = counts.filter { $0.key.hasPrefix("MPSGraph_optimized:") && $0.key != "MPSGraph_optimized:ANE" && $0.key != "MPSGraph_optimized:none" }.values.reduce(0, +)
        let bnns = counts.filter { $0.key.hasPrefix("bnns") }.values.reduce(0, +)
        let odix = counts.filter { $0.key.hasPrefix("odix") }.values.reduce(0, +)
        let fnCount = model.functionNames.count
        let ok = ane > 0 && elsewhere == 0 && bnns == 0 && none <= fnCount
        if !ok { failures.append(n) }
        log("| \(n) | \(ane) | \(elsewhere) | \(none) | \(bnns) | \(odix) | \(ok ? "yes" : "NO") |")
        results.append(["model": n, "counts": counts, "passes": ok, "functions": fnCount])
    }

    // Core ML, for comparison: where MLComputePlan puts each op under the app's compute units.
    var plans: [JSON] = []
    let mlNames = Platform.name == "iOS" ? ["b18_19_n3", "b18_37_n1"] : ["b18_19_n8", "b18_37_n1"]
    for n in mlNames {
        let pkg = assets.appendingPathComponent("coreml/\(n).mlpackage")
        guard FileManager.default.fileExists(atPath: pkg.path) else { continue }
        let (u, _) = try await compiledCoreMLModel(pkg, cacheDir: cacheRoot.appendingPathComponent("coreml-cache"))
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        let plan = try await MLComputePlan.load(contentsOf: u, configuration: cfg)
        var byDevice: [String: Int] = [:]
        if case .program(let program) = plan.modelStructure, let main = program.functions["main"] {
            for op in main.block.operations where op.operatorName != "const" {
                let dev = plan.deviceUsage(for: op)?.preferred
                let name: String
                switch dev {
                case .neuralEngine?: name = "ANE"
                case .gpu?: name = "GPU"
                case .cpu?: name = "CPU"
                default: name = "none"
                }
                byDevice[name, default: 0] += 1
            }
        }
        log("Core ML \(n) compute plan (non-const ops): \(byDevice.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        plans.append(["model": n, "ops": byDevice])
    }
    let verdict = failures.isEmpty ? "PASS" : "FAIL: not fully ANE-resident: " + failures.joined(separator: ", ")
    log("\nResidency: \(verdict)")
    return ["mode": "residency", "coreai": results, "coremlPlans": plans, "verdict": verdict]
}
