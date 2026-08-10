//
//  NarrationSpeechSettingTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

struct NarrationSpeechSettingTests {
    @Test("Spoken narration defaults ON and reads the settings key")
    func defaultsOnAndReadsKey() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: NarrationSpeechSetting.defaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: NarrationSpeechSetting.defaultsKey) }
            else { defaults.removeObject(forKey: NarrationSpeechSetting.defaultsKey) }
        }
        defaults.removeObject(forKey: NarrationSpeechSetting.defaultsKey)
        #expect(NarrationSpeechSetting.isEnabled)          // absent key = default ON
        defaults.set(false, forKey: NarrationSpeechSetting.defaultsKey)
        #expect(!NarrationSpeechSetting.isEnabled)
        defaults.set(true, forKey: NarrationSpeechSetting.defaultsKey)
        #expect(NarrationSpeechSetting.isEnabled)
    }

    @Test("The defaults key follows the TVSettings prefix convention")
    func keyName() {
        #expect(NarrationSpeechSetting.defaultsKey == "TVSettings.spokenNarration")
        #expect(NarrationSpeechSetting.defaultValue == true)
    }
}
