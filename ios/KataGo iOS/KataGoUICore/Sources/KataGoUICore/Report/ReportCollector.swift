//
//  ReportCollector.swift
//  KataGoUICore
//
//  Attributes raw engine reply lines to Deep Report probe stages, exactly.
//
//  GTP wire facts this relies on (cpp/command/gtp.cpp): every command produces
//  exactly one "="-prefixed line, in FIFO order — a normal ack ("= ...") or a
//  bare "=" analyze response header printed BEFORE the info stream (gtp.cpp
//  printGTPResponseHeader); a cancelled analyze emits one EMPTY line, not an
//  ack. So a FIFO of our sent commands, popped per "=" line, tells us which
//  analyze stage (if any) the subsequent `info` lines belong to. Stale lines
//  from the user's live analysis arrive before our first ack, when no stage is
//  current, and are dropped.
//
//  NSLock-protected because lines arrive via GameSession.lineObserver while
//  the generator reads results from the main actor.
//

import Foundation

public enum ReportStage: Hashable, Sendable {
    case snapshot
    case passProbe
    case tenuki(Int)
}

public final class ReportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingStages: [ReportStage?] = []
    private var currentStage: ReportStage?
    private var latestByStage: [ReportStage: String] = [:]
    private var _sawError = false

    public init() {}

    public var sawError: Bool {
        lock.withLock { _sawError }
    }

    /// Call once per command about to be sent, IN SEND ORDER: the stage for
    /// analyze commands, nil for everything else (set-param/play/undo/stop/...).
    public func willSend(stage: ReportStage?) {
        lock.withLock { pendingStages.append(stage) }
    }

    /// Feed every raw engine reply line (from GameSession.lineObserver).
    public func ingest(line: String) {
        lock.withLock {
            if line.hasPrefix("? ") {
                _sawError = true
            } else if line.hasPrefix("=") {
                // One "=" line per command, FIFO: ack or analyze header.
                currentStage = pendingStages.isEmpty ? nil : pendingStages.removeFirst()
            } else if line.hasPrefix("info"), let stage = currentStage {
                latestByStage[stage] = line
            }
            // Empty lines (analyze terminators, ack trailers) are ignored.
        }
    }

    public func latestLine(for stage: ReportStage) -> String? {
        lock.withLock { latestByStage[stage] }
    }

    public func reset() {
        lock.withLock {
            pendingStages = []
            currentStage = nil
            latestByStage = [:]
            _sawError = false
        }
    }
}
