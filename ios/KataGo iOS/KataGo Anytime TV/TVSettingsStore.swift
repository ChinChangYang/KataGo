//
//  TVSettingsStore.swift
//  KataGo Anytime TV
//
//  TV-local persisted settings (UserDefaults). Apple TV runs a single fixed
//  CoreML/Neural Engine backend with no benchmark, so the only persisted
//  preference is the sound-effects toggle.
//

import Foundation

enum TVSettingsStore {
    private static let soundEffectsKey = "TVSettings.soundEffects"

    /// Stone/capture sounds. Defaults ON (the user asked for sound).
    static var soundEffects: Bool {
        get {
            if UserDefaults.standard.object(forKey: soundEffectsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: soundEffectsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: soundEffectsKey) }
    }
    static var soundEffectsKeyName: String { soundEffectsKey }
}
