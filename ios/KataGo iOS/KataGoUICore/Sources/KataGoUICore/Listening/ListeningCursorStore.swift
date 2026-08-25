//
//  ListeningCursorStore.swift
//  KataGo Anytime
//
//  The Listening Cursor's home: device-local UserDefaults, keyed by the
//  record's UUID. Deliberately NOT a GameRecord field — the SwiftData schema
//  is CloudKit-frozen, and a synced cursor would let a car ride re-park the
//  position every other surface displays (ADR 0013). Lost on reinstall,
//  invisible to other devices: accepted.
//

import Foundation

@MainActor
public protocol ListeningCursorStoring: AnyObject {
    /// The next move number to narrate, or nil when the game has none stored.
    func cursor(for gameID: UUID) -> Int?
    func storeCursor(_ moveNumber: Int, for gameID: UUID)
    func clearCursor(for gameID: UUID)
    /// The game of the most recent session — what "Resume listening" resolves.
    var lastSessionGameID: UUID? { get set }
}

@MainActor
public final class UserDefaultsListeningCursorStore: ListeningCursorStoring {
    static let cursorKeyPrefix = "Listening.cursor."
    static let lastSessionKey = "Listening.lastSessionGameID"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func cursor(for gameID: UUID) -> Int? {
        let value = defaults.integer(forKey: Self.cursorKeyPrefix + gameID.uuidString)
        return value > 0 ? value : nil
    }

    public func storeCursor(_ moveNumber: Int, for gameID: UUID) {
        defaults.set(moveNumber, forKey: Self.cursorKeyPrefix + gameID.uuidString)
    }

    public func clearCursor(for gameID: UUID) {
        defaults.removeObject(forKey: Self.cursorKeyPrefix + gameID.uuidString)
    }

    public var lastSessionGameID: UUID? {
        get { defaults.string(forKey: Self.lastSessionKey).flatMap(UUID.init) }
        set {
            if let newValue {
                defaults.set(newValue.uuidString, forKey: Self.lastSessionKey)
            } else {
                defaults.removeObject(forKey: Self.lastSessionKey)
            }
        }
    }
}
