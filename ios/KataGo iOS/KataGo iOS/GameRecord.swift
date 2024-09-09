//
//  GameRecord.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/7.
//

import Foundation
import SwiftData

@Model
final class GameRecord {
    static let defaultSgf = "(;FF[4]GM[1]SZ[19]PB[]PW[]HA[0]KM[7]RU[koSIMPLEscoreAREAtaxNONEsui0whbN])"
    static let defaultName = "New Game"
    var sgf: String
    var currentIndex: Int
    var config: Config
    var name: String
    var lastModificationDate: Date?
    var comments: [Int: String]?

    init(sgf: String = defaultSgf,
         currentIndex: Int = 0,
         config: Config = Config(),
         name: String = defaultName,
         lastModificationDate: Date? = Date.now,
         comments: [Int: String]? = [:]) {
        self.sgf = sgf
        self.currentIndex = currentIndex
        self.config = config
        self.name = name
        self.lastModificationDate = lastModificationDate
        self.comments = comments
    }

    convenience init(gameRecord: GameRecord) {
        self.init(sgf: gameRecord.sgf,
                  currentIndex: gameRecord.currentIndex,
                  config: Config(config: gameRecord.config),
                  name: gameRecord.name + " (copy)",
                  lastModificationDate: Date.now,
                  comments: gameRecord.comments)
    }

    func undo() {
        if (currentIndex > 0) {
            currentIndex = currentIndex - 1
        }
    }

    func clearComments(after index: Int) {
        guard let comments = comments else { return }
        self.comments = comments.filter { $0.key <= index }
    }
}
