// PROTOTYPE (wayfinder #37), throwaway: mode dispatch, shared by the Mac CLI and the iPad app.
//
//   --mode info|idle|speed|parity|mish|residency|power|load|all  [--assets <dir>] [--out <dir>] [mode options]
//
// Each mode prints Markdown to stdout and writes <out>/<mode>-<timestamp>.json. `all` runs parity, mish, residency
// and speed in that order (loads need fresh processes; stage1.sh drives them).
import CoreAIDelegates
import CoreAIRuntime
import Foundation

enum Harness {
    static let usage = """
    usage: --mode <mode> [--assets DIR] [--out DIR] [--cache DIR] [options]
      info                      device, OS, Core AI architecture and compute units
      idle                      one idle reading, and whether it passes
      speed                     --k 2 --sweep 1,2,4,8 --samples 500 --reps 3 --block 100 --block-warmup 5 --warmup 50
                                --apis encode,run --patterns concurrent,static --coreml <name> --no-power
                                --functions per-model|per-slot|shared --agree-repeats 25
      agree                     --sweep 2 --repeats 50 --functions per-model|per-slot|shared (wrong-row rates)
      parity                    --boards 19,37
      mish                      --units cpu,gpu,ane
      residency                 --models b18_19_b1,...
      power                     --k 2 --seconds 20 (each arm alone, continuously; ANE energy needs root on macOS 27)
      load                      --what coreai-cold|coreai-warm|coreai-aot|coreml-first|coreml-cached [--aimodelc PATH]
      all                       parity, mish, residency, speed
    idle gate (speed): --idle-gpu 10 --idle-cores 0.5 --idle-top 0.25 --idle-wait 300 --idle-poll 10 --allow-busy
    """

    static func run(_ args: [String], defaultAssets: URL, defaultOut: URL) async -> Int32 {
        let o = Options(args)
        guard let mode = o.values["mode"] else { log(usage); return 2 }
        let assets = URL(fileURLWithPath: o.string("assets", defaultAssets.path))
        let out = URL(fileURLWithPath: o.string("out", defaultOut.path))
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if let c = o.values["cache"] { cacheRoot = URL(fileURLWithPath: c) }
        log("# Core AI gate, stage 1: \(mode) on \(machineModel()), \(Platform.name) \(ProcessInfo.processInfo.operatingSystemVersionString), \(isoNow())")
        let idle = IdleGate(o)
        let modes = mode == "all" ? ["parity", "mish", "residency", "speed"] : [mode]
        var code: Int32 = 0
        for m in modes {
            do {
                var r: JSON
                switch m {
                case "info": r = info(); logInfo(r)
                case "idle":
                    let reading = IdleReading.take()
                    let problems = reading.problems(idle.thresholds)
                    log("idle: \(problems.isEmpty ? "yes" : "NO: " + problems.joined(separator: "; ")). \(reading.summary)")
                    r = ["mode": "idle", "reading": reading.json(problems), "idle": problems.isEmpty]
                case "speed": r = try await speedMode(o, assets: assets, outDir: out, idle: idle)
                case "parity": r = try await parityMode(o, assets: assets, outDir: out)
                case "mish": r = try await mishMode(o, assets: assets, outDir: out)
                case "residency": r = try await residencyMode(o, assets: assets, outDir: out)
                case "load": r = try await loadMode(o, assets: assets, outDir: out)
                case "power": r = try await powerMode(o, assets: assets, outDir: out, idle: idle)
                case "agree": r = try await agreeMode(o, assets: assets, outDir: out)
                case "loads":  // diagnostic: load the named models in order, keeping each alive
                    var keep: [AnyObject] = []
                    for n in o.string("models", "").split(separator: ",").map(String.init) {
                        let t0 = nowNs()
                        if n.hasPrefix("ml:") {
                            let (u, _) = try await compiledCoreMLModel(assets.appendingPathComponent("coreml/\(n.dropFirst(3)).mlpackage"), cacheDir: cacheRoot.appendingPathComponent("coreml-cache"))
                            keep.append(try AppCoreMLHandle(compiledURL: u, board: n.contains("_37_") ? 37 : 19))
                        } else {
                            keep.append(try await CoreAIFunction(url: assets.appendingPathComponent("coreai/\(n).aimodel"), unit: "ane"))
                        }
                        log("loaded \(n) in \(fmt(Double(nowNs() - t0) / 1e6, 4)) ms")
                    }
                    r = ["mode": "loads", "count": keep.count]
                default: log(usage); return 2
                }
                r["device"] = info()
                r["cacheRecoveries"] = cacheRecoveries
                r["arguments"] = args
                let file = out.appendingPathComponent("\(m)\(m == "load" ? "-" + o.string("what", "") : "")-\(timestamp())-\(UInt32.random(in: 0..<100000)).json")
                try writeJSON(r, to: file)
                log("wrote \(file.path)")
                if let v = r["verdict"] as? String, !v.hasPrefix("PASS") { code = max(code, 1) }
                if let runs = r["runs"] as? [JSON], runs.contains(where: { !(($0["verdict"] as? String) ?? "").hasPrefix("PASS") }) {
                    code = max(code, 1)
                }
            } catch {
                log("ERROR in \(m): \(error) (\(type(of: error)), \(String(reflecting: error)))")
                code = 3
            }
        }
        log("GATE-DONE exit \(code)")
        return code
    }

    static func logInfo(_ j: JSON) {
        log("device \(j["model"]!), OS build \(j["build"]!), Core AI architecture \(j["coreAIArchitecture"]!), "
            + "compute units \(j["computeUnits"]!), thermal \(thermalName(ProcessInfo.processInfo.thermalState)), "
            + "low power \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
    }

    static func info() -> JSON {
        let arch = AIModel.deviceArchitectureName
        let kinds = ComputeUnitKind.availableKinds.map { "\($0)" }.sorted()
        let pi = ProcessInfo.processInfo
        return ["model": machineModel(), "os": pi.operatingSystemVersionString, "build": osBuild(),
                "coreAIArchitecture": arch, "computeUnits": kinds, "platform": Platform.name]
    }
}
