//
//  NavigationContext.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/17.
//

import SwiftUI

@Observable
public class NavigationContext {
    public var selectedGameRecord: GameRecord?

    public init(selectedGameRecord: GameRecord? = nil) {
        self.selectedGameRecord = selectedGameRecord
    }
}
