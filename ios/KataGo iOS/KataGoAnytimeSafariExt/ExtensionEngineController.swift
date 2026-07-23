//
//  ExtensionEngineController.swift
//  KataGoAnytimeSafariExt
//
//  Owns the katago-engine child for the Safari extension. CONFINED TO THE
//  RUNNER'S WORKER THREAD — every method (except init) must be called from
//  that single thread, so the controller itself needs no locking; all
//  cross-thread concerns live in AnalysisJobRunner. Safari may SIGKILL the
//  appex at any time, so the child's pid is recorded in the App Group and
//  stale children are reaped on the next boot (matched by executable path —
//  never kill a recycled pid blindly).
//

import Foundation
import Darwin
import KataGoEngineIPC

/// Outcome of one strict request/response GTP turn.
enum GtpAck {
    case ok(String)
    case refused(String)
    case timedOut
}

final class ExtensionEngineController {
    struct BundlePaths {
        let helper: URL
        let model: URL
        let humanModel: URL
        let config: URL

        /// Appex lives at <App>.app/Contents/PlugIns/<x>.appex → up 2 = Contents/.
        static func resolve() -> BundlePaths? {
            let contents = Bundle.main.bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let paths = BundlePaths(
                helper: contents.appending(path: "MacOS/katago-engine"),
                model: contents.appending(path: "Resources/default_model.bin.gz"),
                humanModel: contents.appending(path: "Resources/b18c384nbt-humanv0.bin.gz"),
                config: contents.appending(path: "Resources/default_gtp.cfg"))
            let readable = [paths.helper, paths.model, paths.humanModel, paths.config]
                .allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) }
            return readable ? paths : nil
        }
    }

    enum State: String {
        case cold
        case warming
        case ready
        case down
    }

    private(set) var state: State = .cold
    private var process: KataGoEngineProcess?
    private var reader: EngineLineReader?
    private let supportDirectory: URL?

    /// First-turn deadline: a cold container pays the CoreML convert+compile.
    private let bootDeadline: TimeInterval = 600
    private let turnDeadline: TimeInterval = 60

    init(supportDirectory: URL?) {
        self.supportDirectory = supportDirectory
        reapStaleChild()
    }

    /// Spawn + version handshake if not already running. Returns false when
    /// the engine cannot come up (spawn denied, resources missing, boot hang).
    @discardableResult
    func ensureReady() -> Bool {
        if state == .ready, let process, process.isRunning { return true }
        shutdown()
        guard let paths = BundlePaths.resolve() else {
            state = .down
            return false
        }

        let arguments = KataGoEngineArguments.gtp(
            modelPath: paths.model.path,
            humanModelPath: paths.humanModel.path,
            configPath: paths.config.path,
            deviceAssignments: [100, 100],   // ANE-only: never fight Safari for GPU
            numSearchThreads: 8,
            nnMaxBatchSize: 8,
            maxBoardSizeForNNBuffer: 19,
            requireExactNNLen: false,
            homeDataDir: "",                 // appex container $HOME/.katago
            tunerFull: false,
            reTune: false)

        let engine = KataGoEngineProcess(executableURL: paths.helper, arguments: arguments)
        if let supportDirectory {
            let log = supportDirectory.appending(path: "engine-stderr.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            engine.setStandardError(try? FileHandle(forWritingTo: log))
        }
        do {
            try engine.start()
        } catch {
            state = .down
            return false
        }
        process = engine
        reader = EngineLineReader(engine: engine)
        state = .warming
        switch turn("version", deadline: bootDeadline) {
        case .ok:
            state = .ready
            return true
        case .refused, .timedOut:
            shutdown()
            state = .down
            return false
        }
    }

    /// One strict GTP request/response turn: stray stream lines ("info", "=",
    /// blanks left over from an interrupted analyze) are skipped; the first
    /// "="/"?" line after the send is the answer. Only used for single-line
    /// response commands (version/loadsgf/stop).
    func turn(_ command: String, deadline: TimeInterval? = nil) -> GtpAck {
        guard let process, let reader, process.isRunning else { return .timedOut }
        process.sendCommand(command)
        let limit = Date().addingTimeInterval(deadline ?? turnDeadline)
        while let line = reader.nextLine(until: limit) {
            if line.hasPrefix("=") {
                return .ok(String(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            }
            if line.hasPrefix("?") {
                return .refused(String(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            }
            // "info"/blank/stream residue → keep reading.
        }
        if !process.isRunning { state = .down }
        return .timedOut
    }

    /// Stream `kata-analyze` until the visit target or wall cap, then stop.
    /// Returns the last (most complete) info line, or nil if none arrived.
    func analyze(command: String, targetVisits: Int, wallCap: TimeInterval) -> String? {
        guard let process, let reader, process.isRunning else { return nil }
        process.sendCommand(command)
        let limit = Date().addingTimeInterval(wallCap)
        var lastInfo: String?
        while let line = reader.nextLine(until: limit) {
            guard line.hasPrefix("info") else { continue }
            lastInfo = line
            if let match = line.firstMatch(of: /rootInfo visits (\d+)/),
               let visits = Int(match.1), visits >= targetVisits {
                break
            }
        }
        // Interrupt the stream and swallow the stop ack (plus stream residue).
        _ = turn("stop", deadline: 5)
        if !process.isRunning { state = .down }
        return lastInfo
    }

    func shutdown() {
        process?.terminate()
        process = nil
        reader = nil
        if state != .down { state = .cold }
    }

    // MARK: - Orphan reaping

    /// A previous appex instance that Safari SIGKILLed may have orphaned its
    /// engine child (deinit never ran). An orphan is identified by BOTH tests:
    /// it runs our bundled helper binary AND it has been reparented to launchd
    /// (ppid 1). The parent check is what protects the main Mac app's own
    /// engine child (same binary, but its ppid is the app) and our own future
    /// child (ppid = this appex).
    private func reapStaleChild() {
        guard let helperPath = BundlePaths.resolve()?.helper.path else { return }
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                   Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return }
        var pathBuffer = [CChar](repeating: 0, count: 4 * 1024)
        for pid in pids where pid > 0 {
            pathBuffer[0] = 0
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0,
                  String(cString: pathBuffer) == helperPath else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_ppid == 1 else { continue }
            kill(pid, SIGTERM)
        }
    }
}

/// Pulls engine stdout on a dedicated thread so callers can wait for a line
/// with a deadline even though `KataGoEngineProcess.getMessageLine()` blocks
/// indefinitely. Internally synchronized with one NSCondition; safe to share
/// between its pump thread and the worker thread.
final class EngineLineReader: @unchecked Sendable {
    private let condition = NSCondition()
    private var lines: [String] = []
    private var eof = false

    init(engine: KataGoEngineProcess) {
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "kga.engine.stdout"
            while true {
                let line = engine.getMessageLine()
                if line.isEmpty && engine.hasReachedEOF {
                    self?.markEOF()
                    return
                }
                guard let self else { return }
                self.condition.lock()
                self.lines.append(line)
                self.condition.signal()
                self.condition.unlock()
            }
        }
    }

    private func markEOF() {
        condition.lock()
        eof = true
        condition.signal()
        condition.unlock()
    }

    /// Next line, or nil at the deadline / at EOF with the buffer drained.
    func nextLine(until deadline: Date) -> String? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if !lines.isEmpty { return lines.removeFirst() }
            if eof { return nil }
            if !condition.wait(until: deadline) { return nil }
        }
    }
}
