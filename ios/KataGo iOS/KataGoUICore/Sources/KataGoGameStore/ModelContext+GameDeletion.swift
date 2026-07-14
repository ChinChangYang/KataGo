//
//  ModelContext+GameDeletion.swift
//  KataGoGameStore
//
//  Shared game-deletion helper (promoted from the iOS app target so the
//  visionOS Games list can delete through the same path). Plain
//  `modelContext.delete` — CloudKit propagation is implicit via the shared
//  container, and no target does anything CloudKit-specific per record.
//

import Foundation
import SwiftData

public extension ModelContext {
    /// Delete every `GameRecord` whose persistent ID is in `gameIDs`, returning
    /// the IDs actually deleted. Fetch-and-filter (rather than `model(for:)`) so
    /// stale/unknown IDs are simply skipped. Synchronous: it runs inside a
    /// delete-confirmation action (already on the main actor) — unlike the iOS
    /// swipe path, there's no in-flight list-removal animation to race with, so
    /// the deferred `safelyDelete` hop isn't needed.
    func bulkDelete(gameIDs: Set<PersistentIdentifier>) -> [PersistentIdentifier] {
        guard !gameIDs.isEmpty else { return [] }
        let all = (try? fetch(FetchDescriptor<GameRecord>())) ?? []
        var deleted: [PersistentIdentifier] = []
        for record in all where gameIDs.contains(record.persistentModelID) {
            delete(record)
            deleted.append(record.persistentModelID)
        }
        return deleted
    }
}
