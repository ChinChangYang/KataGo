//
//  GlobalSettingsKeysTests.swift
//  KataGo iOSTests
//

import Testing
@testable import KataGoUICore

struct GlobalSettingsKeysTests {
    @Test func keysMatchTheHistoricalStringLiterals() {
        #expect(GlobalSettingsKeys.soundEffect == "GlobalSettings.soundEffect")
        #expect(GlobalSettingsKeys.hapticFeedback == "GlobalSettings.hapticFeedback")
        #expect(GlobalSettingsKeys.showVisitsPerSecond == "GlobalSettings.showVisitsPerSecond")
        #expect(GlobalSettingsKeys.showCoordinate == "GlobalSettings.showCoordinate")
        #expect(GlobalSettingsKeys.showPass == "GlobalSettings.showPass")
        #expect(GlobalSettingsKeys.verticalFlip == "GlobalSettings.verticalFlip")
        #expect(GlobalSettingsKeys.showOwnership == "GlobalSettings.showOwnership")
        #expect(GlobalSettingsKeys.showWinrateBar == "GlobalSettings.showWinrateBar")
        #expect(GlobalSettingsKeys.showCharts == "GlobalSettings.showCharts")
        #expect(GlobalSettingsKeys.showComments == "GlobalSettings.showComments")
        #expect(GlobalSettingsKeys.stoneStyle == "GlobalSettings.stoneStyle")
        #expect(GlobalSettingsKeys.moveNumberStyle == "GlobalSettings.moveNumberStyle")
        #expect(GlobalSettingsKeys.analysisStyle == "GlobalSettings.analysisStyle")
        #expect(GlobalSettingsKeys.analysisInformation == "GlobalSettings.analysisInformation")
    }
}
