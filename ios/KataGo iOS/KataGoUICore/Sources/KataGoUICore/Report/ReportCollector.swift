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
    /// A single-vertex `allow`-constrained analyze supplying candidate info
    /// for a move outside the snapshot's ranked list (game move or user pick).
    case forcedCandidate
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
                // A "?" IS the command's one GTP reply, so it consumes the
                // FIFO slot exactly as "=" does. Before ADR 0003 the probe
                // session ended at the first error and this never mattered;
                // now later stages keep running, and skipping the pop would
                // route every subsequent reply one stage off — filing the
                // pass probe's info line under the parity probe, which looks
                // exactly like the silent section loss ADR 0003 exists to end.
                currentStage = pendingStages.isEmpty ? nil : pendingStages.removeFirst()
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

    /// Clears ONLY the error flag, so a probe's `sawError` judges its own
    /// command window instead of inheriting an earlier probe's `? ` line
    /// (ADR 0003: a failed probe drops its own section, not the whole report).
    /// Called at the start of every probe helper.
    ///
    /// Deliberately does NOT touch pendingStages/currentStage/latestByStage:
    /// those carry the FIFO stage routing for the WHOLE probe session — one
    /// "=" line pops one sent command — so clearing them mid-session would
    /// misattribute every reply that follows. Use `reset()` only between
    /// sessions.
    public func clearError() {
        lock.withLock { _sawError = false }
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
