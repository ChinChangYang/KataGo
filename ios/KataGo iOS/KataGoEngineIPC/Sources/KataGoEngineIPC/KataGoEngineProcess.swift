import Foundation
import Darwin

/// Manages a single KataGo engine running as a spawned subprocess, talking GTP
/// over stdin/stdout pipes. Mirrors the surface of the legacy in-process
/// `KataGoHelper` (`sendCommand` / `getMessageLine`) so the macOS engine
/// lifecycle can route through a child process instead of an in-process thread.
///
/// Each instance owns an independent child + its own pipes, so N instances run
/// concurrently and independently (the basis for multi-window support).
///
/// `@unchecked Sendable`: all mutable state (`lines`, `pending`, `reachedEOF`)
/// is guarded by `condition`; `started` is written once during `start()` before
/// any cross-thread read. The stdout `readabilityHandler` runs on a Foundation
/// background queue and only touches that guarded state.
public final class KataGoEngineProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()

    /// Guards `lines`, `pending`, and `reachedEOF`. Signalled when a complete
    /// line is appended or EOF is reached, to wake a blocked `getMessageLine`.
    private let condition = NSCondition()
    private var lines: [String] = []   // complete lines awaiting consumption
    private var pending = Data()        // bytes of an as-yet-unterminated line
    private var reachedEOF = false
    private var started = false

    /// Ignore SIGPIPE process-wide, once. Writing to a child's stdin after it has
    /// exited would otherwise raise SIGPIPE and KILL the parent app (a signal
    /// `try?` cannot catch); ignoring it turns the failed write into a swallowed
    /// EPIPE error instead. Belt-and-suspenders with the `isRunning` guard in
    /// `sendCommand`.
    private static let ignoreSIGPIPEOnce: Void = { signal(SIGPIPE, SIG_IGN) }()

    public init(executableURL: URL,
                arguments: [String],
                environment: [String: String]? = nil,
                currentDirectoryURL: URL? = nil) {
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectoryURL { process.currentDirectoryURL = currentDirectoryURL }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // standardError is left inherited (engine logs flow to the parent's
        // stderr, matching `katago gtp` behavior); callers may override before start.
    }

    /// Allow callers to capture/redirect the child's stderr before `start()`.
    public func setStandardError(_ handle: Any?) {
        process.standardError = handle
    }

    /// Spawn the child process and begin draining its stdout off the main thread.
    public func start() throws {
        _ = Self.ignoreSIGPIPEOnce
        let reader = stdoutPipe.fileHandleForReading
        reader.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            let data = fh.availableData
            if data.isEmpty {
                self.markEOF()
                fh.readabilityHandler = nil
                return
            }
            self.ingest(data)
        }
        try process.run()
        started = true
    }

    private func ingest(_ data: Data) {
        condition.lock()
        pending.append(data)
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: pending.startIndex..<nl)
            pending.removeSubrange(pending.startIndex...nl)
            lines.append(Self.decodeLine(lineData))
        }
        condition.signal()
        condition.unlock()
    }

    private func markEOF() {
        condition.lock()
        // Flush any trailing unterminated bytes as a final line.
        if !pending.isEmpty {
            lines.append(Self.decodeLine(pending))
            pending.removeAll()
        }
        reachedEOF = true
        condition.signal()
        condition.unlock()
    }

    private static func decodeLine(_ data: Data) -> String {
        var line = String(decoding: data, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }  // tolerate CRLF
        return line
    }

    /// Write a single GTP command (a trailing newline is added) to the child's stdin.
    /// No-op if the child has already exited — writing to a closed pipe is
    /// pointless (the engine can't read it) and risks EPIPE/SIGPIPE.
    public func sendCommand(_ command: String) {
        guard process.isRunning else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }

    /// Block until the next line of engine output is available; returns the line
    /// WITHOUT its trailing newline. Returns "" once the child's stdout reaches
    /// EOF and all buffered lines are drained.
    public func getMessageLine() -> String {
        condition.lock()
        defer { condition.unlock() }
        while lines.isEmpty && !reachedEOF {
            condition.wait()
        }
        return lines.isEmpty ? "" : lines.removeFirst()
    }

    /// Whether the child process is still running.
    public var isRunning: Bool { started && process.isRunning }

    /// True once the child's stdout has reached EOF AND all buffered lines have
    /// been drained — i.e. `getMessageLine()` returning "" means end-of-output,
    /// not a normal blank GTP line. Lets the consumer distinguish engine exit
    /// from a legitimate empty response line.
    public var hasReachedEOF: Bool {
        condition.lock(); defer { condition.unlock() }
        return reachedEOF && lines.isEmpty
    }

    /// Exit status once the child has terminated (0 while still running).
    public var terminationStatus: Int32 { process.isRunning ? 0 : process.terminationStatus }

    /// Gracefully stop the child, escalating until it is gone, with a BOUNDED
    /// total wait so this can never hang the caller:
    ///   1. close stdin → the engine sees EOF on cin and quits;
    ///   2. if still alive after a grace period, SIGTERM;
    ///   3. if still alive, SIGKILL (a process cannot ignore SIGKILL).
    /// Idempotent and safe to call multiple times (incl. from `deinit`). Never
    /// calls the unbounded `waitUntilExit()`.
    public func terminate() {
        guard started, process.isRunning else { return }
        try? stdinPipe.fileHandleForWriting.close()
        if waitForExit(within: 1.5) { return }
        process.terminate()                       // SIGTERM
        if waitForExit(within: 1.0) { return }
        kill(process.processIdentifier, SIGKILL)   // last resort
        _ = waitForExit(within: 1.0)
    }

    /// Poll `isRunning` up to `seconds`; returns true once the child has exited.
    private func waitForExit(within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    /// Safety net: a `KataGoEngineProcess` dropped without an explicit
    /// `terminate()` (e.g. an error path) must not orphan its child. This is
    /// NON-BLOCKING — it only signals termination (close stdin → the engine
    /// quits on EOF; SIGTERM as backup) and never sleeps/waits, so it is safe to
    /// run on ANY thread, including the main thread. Foundation reaps the child
    /// when it exits (no zombie); the deterministic, bounded escalation incl.
    /// SIGKILL lives in `terminate()` for callers that need the child gone now.
    deinit {
        guard started, process.isRunning else { return }
        try? stdinPipe.fileHandleForWriting.close()
        process.terminate()
    }
}
