//
//  KataGoEngineIO.swift
//  KataGoUICore
//
//  Abstraction over the GTP transport so a `GameSession` can talk to the engine
//  either IN-PROCESS (iOS/visionOS: the C++ bridge thread, which cannot be a
//  subprocess on those sandboxed platforms) or OUT-OF-PROCESS (macOS: a spawned
//  `katago-engine` child). The default is the in-process bridge, so existing
//  iOS/visionOS behavior is unchanged unless a host injects another transport.
//

import Foundation

/// A bidirectional GTP transport: send commands, read response lines.
public protocol KataGoEngineIO: AnyObject, Sendable {
    /// Send a single GTP command (the transport appends the newline).
    func sendCommand(_ command: String)
    /// Block until the next output line is available; returns it without the
    /// trailing newline. Returns "" at end-of-output (see `hasReachedEOF`).
    func getMessageLine() -> String
    /// Inject a raw message into the read side (used by the in-process bridge to
    /// nudge a blocked reader during teardown). A no-op for transports whose
    /// reader unblocks naturally on EOF.
    func sendMessage(_ message: String)
    /// True once the transport has observed end-of-output and drained — i.e. a
    /// subsequent empty `getMessageLine()` means the engine exited, not a blank
    /// GTP line. Always false for the in-process bridge (it never sees EOF).
    var hasReachedEOF: Bool { get }
}

/// In-process transport backed by the global `KataGoHelper` C++ bridge. Inherently
/// process-global (one engine per process); used on iOS/visionOS and as the
/// default everywhere. `@unchecked Sendable`: it is stateless, delegating to the
/// thread-safe C++ bridge.
public final class InProcessKataGoEngine: KataGoEngineIO, @unchecked Sendable {
    public init() {}
    public func sendCommand(_ command: String) { KataGoHelper.sendCommand(command) }
    public func getMessageLine() -> String { KataGoHelper.getMessageLine() }
    public func sendMessage(_ message: String) { KataGoHelper.sendMessage(message) }
    public var hasReachedEOF: Bool { false }
}
