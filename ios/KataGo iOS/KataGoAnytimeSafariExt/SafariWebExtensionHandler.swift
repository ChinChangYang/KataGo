//
//  SafariWebExtensionHandler.swift
//  KataGoAnytimeSafariExt
//
//  Native side of the Safari web extension. T1 spike build: answers `echo`
//  for round-trip verification and `spike` to prove the three feasibility
//  claims the design hinges on (parent-bundle reads, katago-engine spawn
//  from the appex sandbox, GTP analysis round-trip). The spike writes its
//  report incrementally to the App Group container so a hang at any stage
//  still leaves evidence on disk.
//

import Foundation
import SafariServices
import KataGoEngineIPC
import os.log

let spikeLog = Logger(subsystem: "chinchangyang.KataGo-iOS.tw.safari", category: "spike")

/// NSExtensionContext is not Sendable; the handler completes requests from a
/// background queue after the (potentially minutes-long) spike finishes.
private struct ContextBox: @unchecked Sendable {
    let context: NSExtensionContext
}

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?
            .userInfo?[SFExtensionMessageKey] as? [String: Any]
        let cmd = message?["cmd"] as? String ?? ""
        let box = ContextBox(context: context)

        switch cmd {
        case "echo":
            reply(box, [
                "cmd": "echo",
                "payload": message?["payload"] as? String ?? "",
                "pid": ProcessInfo.processInfo.processIdentifier,
                "bundleID": Bundle.main.bundleIdentifier ?? "?",
                "bundlePath": Bundle.main.bundleURL.path,
            ])
        case "spike":
            DispatchQueue.global(qos: .userInitiated).async {
                let report = EngineSpike().run()
                self.reply(box, report)
            }
        default:
            reply(box, ["error": "unknown cmd '\(cmd)'"])
        }
    }

    private func reply(_ box: ContextBox, _ payload: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: payload]
        box.context.completeRequest(returningItems: [item])
    }
}

// MARK: - Engine spike

/// Runs the T1 feasibility spike synchronously on a background queue.
private struct EngineSpike {
    let groupID = "group.chinchangyang.KataGo-iOS.tw"

    func run() -> [String: Any] {
        var report: [String: Any] = [
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "home": NSHomeDirectory(),
        ]
        defer { persist(report) }

        // Stage 1: resolve + read the parent app bundle (claim C5).
        // Appex lives at <App>.app/Contents/PlugIns/<x>.appex → up 2 = Contents/.
        let appContents = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helperURL = appContents.appending(path: "MacOS/katago-engine")
        let resources = appContents.appending(path: "Resources")
        let modelURL = resources.appending(path: "default_model.bin.gz")
        let humanURL = resources.appending(path: "b18c384nbt-humanv0.bin.gz")
        let configURL = resources.appending(path: "default_gtp.cfg")

        var stage1: [String: Any] = ["appContents": appContents.path]
        for (name, url) in [("helper", helperURL), ("model", modelURL),
                            ("humanModel", humanURL), ("config", configURL)] {
            stage1[name + "Exists"] = FileManager.default.isReadableFile(atPath: url.path)
        }
        if let fh = try? FileHandle(forReadingFrom: modelURL),
           let magic = try? fh.read(upToCount: 2) {
            // gzip magic 1f 8b proves an actual byte-level read, not just stat.
            stage1["modelMagicOK"] = magic == Data([0x1F, 0x8B])
            try? fh.close()
        } else {
            stage1["modelMagicOK"] = false
        }
        report["stage1_bundleRead"] = stage1
        persist(report)

        guard stage1.values.compactMap({ $0 as? Bool }).allSatisfy({ $0 }) else {
            report["verdict"] = "FAIL: parent bundle not fully readable"
            return report
        }

        // Stage 2: spawn katago-engine (claim C1).
        let spikeDir = spikeDirectory()
        let stderrLog = spikeDir.appending(path: "engine-stderr.log")
        FileManager.default.createFile(atPath: stderrLog.path, contents: nil)

        let arguments = KataGoEngineArguments.gtp(
            modelPath: modelURL.path,
            humanModelPath: humanURL.path,
            configPath: configURL.path,
            deviceAssignments: [100, 100],   // ANE-only: never fight Safari for GPU
            numSearchThreads: 8,
            nnMaxBatchSize: 8,
            maxBoardSizeForNNBuffer: 19,
            requireExactNNLen: false,
            homeDataDir: "",                 // appex container $HOME/.katago
            tunerFull: false,
            reTune: false)

        let engine = KataGoEngineProcess(executableURL: helperURL, arguments: arguments)
        engine.setStandardError(try? FileHandle(forWritingTo: stderrLog))

        let spawnStart = Date()
        do {
            try engine.start()
        } catch {
            report["stage2_spawn"] = ["ok": false, "error": String(describing: error)]
            report["verdict"] = "FAIL: spawn denied — \(error)"
            return report
        }
        report["stage2_spawn"] = ["ok": true, "spawnMs": ms(since: spawnStart)]
        persist(report)

        // Stage 3: GTP round-trip incl. one kata-analyze burst (boot may take
        // minutes on the very first run while the CoreML model is compiled in
        // this fresh container — generous deadline, incremental persistence).
        let reader = LineReader(engine: engine)
        var stage3: [String: Any] = [:]
        defer {
            engine.sendCommand("quit")
            engine.terminate()
            stage3["exitStatus"] = engine.terminationStatus
            report["stage3_gtp"] = stage3
        }

        let bootStart = Date()
        engine.sendCommand("version")
        guard let version = reader.nextLine(prefix: "=", within: 600) else {
            stage3["bootTimedOut"] = true
            report["stage3_gtp"] = stage3
            report["verdict"] = "FAIL: no version response within 600s (see engine-stderr.log)"
            return report
        }
        stage3["version"] = version
        stage3["bootMs"] = ms(since: bootStart)
        report["stage3_gtp"] = stage3
        persist(report)

        engine.sendCommand("boardsize 9")
        _ = reader.nextLine(prefix: "=", within: 60)
        let analyzeStart = Date()
        engine.sendCommand("kata-analyze interval 50 ownership true rootInfo true")
        var infoLines: [String] = []
        while infoLines.count < 3, let line = reader.nextLine(prefix: "info", within: 120) {
            infoLines.append(String(line.prefix(160)))
        }
        engine.sendCommand("stop")
        stage3["firstAnalysisMs"] = ms(since: analyzeStart)
        stage3["analysisLines"] = infoLines
        report["stage3_gtp"] = stage3

        report["verdict"] = infoLines.isEmpty
            ? "FAIL: engine booted but produced no analysis"
            : "PASS: spawn + boot + kata-analyze all work from the appex"
        return report
    }

    private func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    private func spikeDirectory() -> URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appending(path: "Library/Caches/SafariSpike")
            ?? FileManager.default.temporaryDirectory.appending(path: "SafariSpike")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func persist(_ report: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: report,
                                                    options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: spikeDirectory().appending(path: "report.json"))
        spikeLog.info("spike report updated: \(report["verdict"] as? String ?? "in progress", privacy: .public)")
    }
}

/// Pulls engine stdout on a dedicated thread so the spike can wait for a line
/// with a deadline even though `getMessageLine()` blocks indefinitely.
private final class LineReader: @unchecked Sendable {
    private let lock = NSCondition()
    private var lines: [String] = []

    init(engine: KataGoEngineProcess) {
        Thread.detachNewThread { [weak self] in
            while true {
                let line = engine.getMessageLine()
                if line.isEmpty && engine.hasReachedEOF { return }
                guard let self else { return }
                self.lock.lock()
                self.lines.append(line)
                self.lock.signal()
                self.lock.unlock()
            }
        }
    }

    /// Next line starting with `prefix` (other lines are discarded), or nil on deadline.
    func nextLine(prefix: String, within seconds: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        lock.lock()
        defer { lock.unlock() }
        while true {
            while let line = lines.first {
                lines.removeFirst()
                if line.hasPrefix(prefix) { return line }
            }
            if !lock.wait(until: deadline) { return nil }
        }
    }
}
