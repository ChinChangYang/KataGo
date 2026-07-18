//
//  AppHandoff.swift
//  KataGoAnytimeMessages
//
//  "Analyze in KataGo Anytime": the extension may not write the shared
//  SwiftData store (extensions are read-only by design), so it spools the
//  game's SGF as a FILE in the App Group container and deep-links the app,
//  which imports it through the normal GameRecord.importGameRecord path
//  and deletes the spool.
//

import Foundation
import GoRulesKit
import KataGoGameStore

enum AppHandoff {
    /// Writes the SGF spool and returns the deep link to open the app with.
    static func spoolAndDeepLink(_ message: MessageGame) -> URL? {
        guard let directory = GameDeepLink.messagesHandoffDirectory() else { return nil }
        let sgf = MessageGameCodec.sgf(for: message)
        let fileName = UUID().uuidString + ".sgf"
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try sgf.write(to: directory.appendingPathComponent(fileName),
                          atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return GameDeepLink.importSgfURL(fileName: fileName)
    }
}
