//
//  CoreMLCacheReadiness.swift
//  KataGo Anytime
//
//  Per-filename "is the Core ML cache populated for this model?"
//  signal consumed by the model picker's green checkmark.
//

import CoreMLCacheKit
import Foundation
import Observation
import OSLog

private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "KataGo Anytime",
    category: "engine.coreml.readiness")

@MainActor
@Observable
public final class CoreMLCacheReadiness {
    /// Filenames whose projected digest is currently on disk.
    /// `ModelPickerView` reads this to show the green checkmark.
    public private(set) var readyFileNames: Set<String> = []

    /// Seam: filename → expected cache digest (or nil if the file is
    /// not downloaded). Production uses `makeProjectionDigestFor()`.
    private let digestFor: @Sendable (String) async throws -> String?

    /// Seam: digest → "is this entry currently on disk?". Production
    /// wraps `CoreMLModelCache.shared.hasEntry(digest:)`.
    private let hasEntry: @Sendable (String) async -> Bool

    /// Last filename set passed to `update(forFileNames:)`. The
    /// indexEvents subscription re-runs the projection against this
    /// list on every yield.
    private var lastKnown: [String] = []

    /// Guards the long-lived subscription task so repeated `start()`
    /// calls (e.g., scene `.task` re-firing) are no-ops.
    private var didStart = false

    /// Production initializer. Wires the shared cache and the
    /// production projection closure.
    public convenience init() {
        self.init(
            digestFor: makeProjectionDigestFor(),
            hasEntry: { digest in
                await CoreMLModelCache.shared.hasEntry(digest: digest)
            })
    }

    /// Designated initializer with seams for testing.
    public init(
        digestFor: @Sendable @escaping (String) async throws -> String?,
        hasEntry: @Sendable @escaping (String) async -> Bool
    ) {
        self.digestFor = digestFor
        self.hasEntry = hasEntry
    }

    /// Tell the readiness object which filenames the picker currently
    /// displays. Recomputes `readyFileNames` immediately.
    public func update(forFileNames fileNames: [String]) async {
        lastKnown = fileNames
        await recompute()
    }

    /// Subscribe to `CoreMLModelCache.shared.indexEvents` and re-run
    /// the projection on every yield. Idempotent. Call once from the
    /// app's scene `.task`.
    public func start() async {
        guard !didStart else { return }
        didStart = true

        // Ensure the on-disk index is loaded before our first read.
        await CoreMLModelCache.shared.start()

        let stream = await CoreMLModelCache.shared.indexEvents
        Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.recompute()
            }
        }
    }

    private func recompute() async {
        var fresh: Set<String> = []
        for fileName in lastKnown {
            do {
                guard let digest = try await digestFor(fileName) else { continue }
                if await hasEntry(digest) { fresh.insert(fileName) }
            } catch {
                // Best-effort UI state. A projection failure here
                // means the row simply lacks a checkmark for this
                // tick; the engine path is unaffected.
                log.info("readiness.digestFailed fileName=\(fileName, privacy: .public) error=\(String(describing: error), privacy: .public)")
                continue
            }
        }
        readyFileNames = fresh
    }
}
