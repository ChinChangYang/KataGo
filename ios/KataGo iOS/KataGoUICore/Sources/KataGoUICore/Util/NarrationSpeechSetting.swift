//
//  NarrationSpeechSetting.swift
//  KataGoUICore
//
//  Whether the tvOS broadcast narration is spoken aloud. Extracted into
//  KataGoUICore (the TVAutoPlaySpeed precedent) so the default and key are
//  one source of truth for the Settings toggle's @AppStorage and the
//  broadcast's per-slide read, and unit-testable from the iOS test host.
//

import Foundation

public enum NarrationSpeechSetting {
    /// The one UserDefaults key, shared by the Settings toggle's @AppStorage
    /// and the broadcast's isSpeechEnabled closure.
    public static let defaultsKey = "TVSettings.spokenNarration"

    /// ON by default: the feedback that created this feature asked for
    /// spoken narration outright.
    public static let defaultValue = true

    public static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil { return defaultValue }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
