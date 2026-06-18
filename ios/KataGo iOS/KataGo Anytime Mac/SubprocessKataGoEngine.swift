//
//  SubprocessKataGoEngine.swift
//  KataGo Anytime Mac
//
//  macOS engine transport: owns a `katago-engine` CHILD PROCESS and adapts it to
//  `KataGoEngineIO` so a `GameSession` drives it exactly like the in-process
//  bridge. One instance per window → fully independent engines (each child has
//  its own stdin/stdout), which is what makes multi-window possible and frees
//  the app's own standard streams. iOS/visionOS keep the in-process bridge.
//

import Foundation
import KataGoEngineIPC
import KataGoUICore

final class SubprocessKataGoEngine: KataGoEngineIO, @unchecked Sendable {
    private let process: KataGoEngineProcess

    init(helperURL: URL, arguments: [String]) {
        process = KataGoEngineProcess(executableURL: helperURL, arguments: arguments)
    }

    /// Spawn the child and begin draining its stdout.
    func start() throws { try process.start() }

    /// Stop the child: closes stdin (the engine treats EOF as `quit`), waits a
    /// short grace period, then SIGTERMs if needed. Synchronous; quick once the
    /// engine has acked a prior `quit`.
    func terminate() { process.terminate() }

    var isRunning: Bool { process.isRunning }

    // MARK: KataGoEngineIO
    func sendCommand(_ command: String) { process.sendCommand(command) }
    func getMessageLine() -> String { process.getMessageLine() }
    /// No-op: the child's reader unblocks naturally on stdout EOF when it exits,
    /// so the in-process "\n" nudge is unnecessary out-of-process.
    func sendMessage(_ message: String) {}
    var hasReachedEOF: Bool { process.hasReachedEOF }

    /// URL of the helper embedded in the app bundle at Contents/MacOS/katago-engine.
    static var bundledHelperURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "katago-engine")
    }
}
