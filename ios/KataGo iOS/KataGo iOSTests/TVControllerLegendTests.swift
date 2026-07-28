//
//  TVControllerLegendTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

struct TVControllerLegendTests {
    /// A/B/Menu belong to the tvOS focus engine — binding them in GameController
    /// would double-fire against TVSelectPressCatcher and .onExitCommand. The
    /// event enum is the single list of what the app is allowed to bind.
    @Test func onlyFocusSafeButtonsAreModelled() {
        #expect(TVControllerEvent.allCases == [.buttonX, .buttonY, .leftShoulder,
                                               .rightShoulder, .leftTrigger, .rightTrigger])
    }

    @Test func everyBoundButtonHasALegendRow() {
        let covered = Set(TVControllerLegend.rows.map(\.event))
        #expect(covered == Set(TVControllerEvent.allCases))
    }

    @Test func legendRowsDescribeBothScreens() {
        for row in TVControllerLegend.rows {
            #expect(!row.symbol.isEmpty)
            #expect(!row.name.isEmpty)
            #expect(!row.review.isEmpty)
            #expect(!row.live.isEmpty)
        }
    }

    @Test func theTransportButtonIsX() {
        let row = TVControllerLegend.rows.first { $0.event == .buttonX }
        #expect(row?.review == "Auto-Play")
        #expect(row?.live == "Pause / Resume")
    }
}
