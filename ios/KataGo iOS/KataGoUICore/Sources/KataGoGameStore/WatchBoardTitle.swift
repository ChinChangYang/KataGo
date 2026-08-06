//
//  WatchBoardTitle.swift
//  KataGoGameStore
//
//  What the board page's navigation title says.
//
//  The watch board fills its whole page, so the title is the only chrome left
//  that can report status without covering stones. That is why the rule lives
//  here, in one testable place, rather than inline in a view: the watch target
//  has no test bundle, so a rule spelled out there cannot be tested at all.
//

import Foundation

public enum WatchBoardTitle {
    /// A game's title: the scrub counter while the Crown is moving, the game's
    /// name once it settles. Showing the counter permanently would mean a
    /// game's name was never on screen.
    public static func game(name: String, index: Int, count: Int,
                            showsCounter: Bool) -> String {
        showsCounter ? "\(index)/\(count)" : name
    }
}
